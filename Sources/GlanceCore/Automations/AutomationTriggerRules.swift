import Foundation

/// Runs waiting for an automation's current run (spec "Runs": one at a time, at most 10 waiting, the oldest dropped).
public struct AutomationRunQueue<Item: Sendable>: Sendable {
  public let limit: Int
  public private(set) var items: [Item] = []

  public init(limit: Int = 10) {
    self.limit = limit
  }

  public var count: Int { items.count }
  public var isEmpty: Bool { items.isEmpty }

  /// Adds an item at the back. When that makes more than `limit`, the oldest is dropped and returned (the engine
  /// logs it).
  public mutating func push(_ item: Item) -> Item? {
    items.append(item)
    return items.count > limit ? items.removeFirst() : nil
  }

  public mutating func pop() -> Item? {
    items.isEmpty ? nil : items.removeFirst()
  }

  public mutating func removeAll() { items.removeAll() }
}

/// A watcher's restarts (spec "Trigger sources", *watcher*): each crash in a row waits twice as long, 5 s up to
/// 5 min; 5 crashes inside 10 minutes and it is broken until the user switches the automation on again. A healthy
/// poll (or a streaming watcher that stayed up 10 minutes) starts the doubling over.
public struct WatcherBackoff: Equatable, Sendable {
  public static let first: TimeInterval = 5
  public static let longest: TimeInterval = 300
  public static let crashLimit = 5
  public static let window: TimeInterval = 600

  public enum Outcome: Equatable, Sendable {
    case restart(after: TimeInterval)
    case broken
  }

  public private(set) var crashes: [Date] = []
  public private(set) var streak = 0

  public init() {}

  public mutating func crashed(at now: Date) -> Outcome {
    crashes = crashes.filter { now.timeIntervalSince($0) < Self.window } + [now]
    streak += 1
    if crashes.count >= Self.crashLimit { return .broken }
    return .restart(after: min(Self.first * pow(2, Double(streak - 1)), Self.longest))
  }

  public mutating func succeeded() { streak = 0 }
}

/// schedule-state.json (spec "Trigger sources", *schedule*): each schedule's last fire, so a launch after a missed
/// time fires it once. A schedule seen for the first time records its arming time instead: it never catches up on
/// times from before it existed (A0 plan decision).
public struct AutomationScheduleState: Equatable, Sendable {
  public private(set) var lastFires: [String: Date]

  public init(lastFires: [String: Date] = [:]) {
    self.lastFires = lastFires
  }

  /// "fix-red-ci triggers[2] 0 9 * * 1-5": a changed or moved schedule is a new one.
  public static func key(automation: String, index: Int, cron: String) -> String {
    "\(automation) triggers[\(index)] \(cron)"
  }

  /// Arms these schedules (key → schedule): new keys get `now`; keys not given are forgotten. Returns the keys whose
  /// last fire is before their most recent due time, sorted: fire each once, then `fired(key, at: now)`.
  public mutating func arm(_ schedules: [String: CronSchedule], now: Date, calendar: Calendar) -> [String] {
    lastFires = lastFires.filter { schedules[$0.key] != nil }
    var behind: [String] = []
    for (key, schedule) in schedules {
      guard let last = lastFires[key] else {
        lastFires[key] = now
        continue
      }
      if schedule.isBehind(lastFire: last, now: now, calendar: calendar) { behind.append(key) }
    }
    return behind.sorted()
  }

  public mutating func fired(_ key: String, at date: Date) {
    lastFires[key] = date
  }

  /// The next time any of them fires, and which ones fire then.
  public static func next(_ schedules: [String: CronSchedule], after date: Date,
                          calendar: Calendar) -> (date: Date, keys: [String])? {
    var soonest: Date?
    var keys: [String] = []
    for (key, schedule) in schedules {
      guard let fire = schedule.next(after: date, calendar: calendar) else { continue }
      if soonest == nil || fire < soonest! {
        soonest = fire
        keys = [key]
      } else if fire == soonest {
        keys.append(key)
      }
    }
    return soonest.map { ($0, keys.sorted()) }
  }

  static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// {"key": "2026-10-09T09:00:00.000Z"}
  public func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(lastFires.mapValues { Self.stamp.format($0) })) ?? Data("{}".utf8)
  }

  /// nil when it isn't a schedule-state file (the engine starts over: every schedule armed now).
  public static func decode(_ data: Data) -> AutomationScheduleState? {
    guard let stamps = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
    var fires: [String: Date] = [:]
    for (key, stamp) in stamps {
      guard let date = try? Self.stamp.parse(stamp) else { return nil }
      fires[key] = date
    }
    return AutomationScheduleState(lastFires: fires)
  }
}

/// What a trigger fires on, and what it hands the run (`{{trigger.…}}`).
public enum AutomationTriggerMatch {
  /// An event trigger's `filter`: every field equal to the payload's (412 and "412" count as equal).
  public static func matches(_ filter: [String: AutomationValue]?, _ payload: AutomationValue) -> Bool {
    for (field, wanted) in filter ?? [:] {
      guard let value = payload.value(at: [field]), value == wanted || value.text == wanted.text else { return false }
    }
    return true
  }

  /// `*` any characters but "/", `**` any characters, `?` one character, `[abc]` one of them. Case doesn't matter
  /// (macOS file names don't care either).
  public static func glob(_ pattern: String, matches text: String) -> Bool {
    match(Array(pattern.lowercased()), 0, Array(text.lowercased()), 0)
  }

  static func match(_ pattern: [Character], _ p: Int, _ text: [Character], _ t: Int) -> Bool {
    if p == pattern.count { return t == text.count }
    switch pattern[p] {
    case "*":
      let deep = p + 1 < pattern.count && pattern[p + 1] == "*"
      let rest = deep ? p + 2 : p + 1
      // "**/" also matches no directory at all (gitignore style): "**/*.pdf" matches "b.pdf".
      if deep, rest < pattern.count, pattern[rest] == "/", match(pattern, rest + 1, text, t) { return true }
      var index = t
      while true {
        if match(pattern, rest, text, index) { return true }
        guard index < text.count, deep || text[index] != "/" else { return false }
        index += 1
      }
    case "?":
      return t < text.count && text[t] != "/" && match(pattern, p + 1, text, t + 1)
    case "[":
      guard let close = pattern[(p + 1)...].firstIndex(of: "]"), t < text.count else {
        return t < text.count && text[t] == "[" && match(pattern, p + 1, text, t + 1)
      }
      return pattern[(p + 1)..<close].contains(text[t]) && match(pattern, close + 1, text, t + 1)
    default:
      return t < text.count && text[t] == pattern[p] && match(pattern, p + 1, text, t + 1)
    }
  }

  /// The changed paths a files trigger fires on (spec "Trigger sources", *files*): the watched file itself, or paths
  /// under the watched folder whose name matches `glob` (the path under the folder, when the glob has a "/"). Hidden
  /// files and anything inside a hidden folder (.DS_Store, swap files, .git) only when the glob asks for them (it
  /// starts with "." or has a "/." in it). Each once, sorted. `root` and `paths`
  /// must both be real paths (FSEvents reports /private/tmp for /tmp).
  public static func changedPaths(_ paths: [String], root: String, glob: String?) -> [String] {
    var root = root
    while root.count > 1, root.hasSuffix("/") { root.removeLast() }
    var found = Set<String>()
    for path in paths {
      if path == root {
        found.insert(path)
        continue
      }
      guard path.hasPrefix(root + "/") else { continue }
      let relative = String(path.dropFirst(root.count + 1))
      let name = (path as NSString).lastPathComponent
      let pattern = glob ?? "*"
      // Hidden at any depth (.git/objects/ab/cdef, .cache/x.tmp), not only the file's own name.
      let asksForHidden = pattern.hasPrefix(".") || pattern.contains("/.")
      if !asksForHidden, relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
      let subject = pattern.contains("/") ? relative : name
      if self.glob(pattern, matches: subject) { found.insert(path) }
    }
    return found.sorted()
  }

  /// "~/Downloads" → "/Users/me/Downloads".
  public static func expand(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + path.dropFirst() }
    return path
  }

  /// `{{trigger.paths}}`.
  public static func filesPayload(_ paths: [String]) -> AutomationValue {
    .object(["paths": .array(paths.map(AutomationValue.string))])
  }

  /// `{{trigger.cron}}` and `{{trigger.at}}` (the due time, ISO 8601 UTC).
  public static func schedulePayload(cron: String, at date: Date) -> AutomationValue {
    .object(["cron": .string(cron), "at": .string(AutomationScheduleState.stamp.format(date))])
  }
}
