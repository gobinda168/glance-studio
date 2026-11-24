import Foundation

/// When the Assets scan may run (the pure part of the model's scheduling, so the rules are tested).
///
/// - A scan needs the project's setup, whose `assets` patterns it matches; until the setup is read nothing starts, and
///   the scan that was waiting is asked for again when it is.
/// - Scans never overlap. A request that arrives while one runs is remembered, and one more follows it.
/// - Scans start at least `interval` apart. A request inside that window is not lost: one trailing scan is planned for
///   when the window ends, and any further requests until then join it.
/// - A change to the setup's patterns after a scan asks for another.
public struct AssetScanGate: Equatable, Sendable {
  public enum Decision: Equatable, Sendable {
    /// Start a scan now.
    case start
    /// Ask again at this time (a trailing scan; nothing more is planned until it fires).
    case wait(until: Date)
    /// Nothing to do: it will be asked for again.
    case none
  }

  public let interval: TimeInterval
  private var setupLoaded = false
  private var patterns: [String] = []
  private var usedPatterns: [String]?
  private var lastStart: Date?
  private var running = false
  private var again = false
  private var trailing = false

  public init(interval: TimeInterval = 20) { self.interval = interval }

  /// A scan is wanted (the panel opened, Claude went idle, the folder changed).
  public mutating func request(now: Date) -> Decision {
    guard setupLoaded else { return .none }
    if running { again = true; return .none }
    if let last = lastStart, now.timeIntervalSince(last) < interval {
      guard !trailing else { return .none }
      trailing = true
      return .wait(until: last.addingTimeInterval(interval))
    }
    return begin(now: now)
  }

  /// The time planned by `.wait` has come.
  public mutating func trailingFired(now: Date) -> Decision {
    trailing = false
    return request(now: now)
  }

  /// The scan ended (finished or cancelled). True when another is owed straight away.
  public mutating func finished(now: Date) -> Bool {
    running = false
    guard again else { return false }
    again = false
    lastStart = nil // asked for after the last one began: not made to wait out the window
    return true
  }

  /// The setup was read or changed. True when a scan should be requested: this is the first time it is known, or its
  /// patterns differ from the ones the last scan used.
  public mutating func setup(loaded: Bool, patterns: [String]) -> Bool {
    let first = loaded && !setupLoaded
    setupLoaded = loaded
    self.patterns = patterns
    if first { return true }
    guard loaded, let used = usedPatterns else { return false }
    return used != patterns
  }

  /// The tab moved to another session or folder: the old plan is void. The setup facts stay (they are re-sent when read).
  public mutating func reset() {
    lastStart = nil
    running = false
    again = false
    trailing = false
    usedPatterns = nil
  }

  /// The patterns the scan now starting must use.
  public var currentPatterns: [String] { patterns }

  private mutating func begin(now: Date) -> Decision {
    running = true
    again = false
    lastStart = now
    usedPatterns = patterns
    return .start
  }
}
