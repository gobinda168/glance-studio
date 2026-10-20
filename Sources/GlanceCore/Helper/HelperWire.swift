import Foundation

/// What Glance Studio and its helper process say to each other: one line of text each, over the helper's stdin
/// (commands) and stdout (events). The helper runs the background jobs, so a crash in one restarts the helper and
/// leaves the app up.
public enum HelperWire {
  public enum Command: Equatable, Sendable {
    /// Start scanning Claude Code's transcripts into the usage store (every 2 minutes, and now).
    case usageStart
    case usageStop
    /// Scan now (the Usage tab opened).
    case usageScan
    /// Collect Journal days: `id` ties the answer to the request, `json` is the request (one line).
    case journalCollect(id: Int, json: String)
  }

  public enum Event: Equatable, Sendable {
    /// The helper is up and reading commands: send it the jobs that should be running.
    case ready
    case usageProgress(done: Int, total: Int)
    /// A scan finished having read `read` new lines' worth of files.
    case usageScanned(read: Int)
    /// Journal's collection `id` finished and is in the store (`ok`), or couldn't run.
    case journalCollected(id: Int, ok: Bool)
  }

  public static func line(_ command: Command) -> String {
    switch command {
    case .usageStart: "usage.start"
    case .usageStop: "usage.stop"
    case .usageScan: "usage.scan"
    case .journalCollect(let id, let json): "journal.collect \(id) \(json)"
    }
  }

  public static func command(from line: String) -> Command? {
    if line.hasPrefix("journal.collect ") {
      let rest = line.dropFirst("journal.collect ".count)
      guard let space = rest.firstIndex(of: " "), let id = Int(rest[rest.startIndex..<space]) else { return nil }
      return .journalCollect(id: id, json: String(rest[rest.index(after: space)...]))
    }
    return switch line.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "usage.start": .usageStart
    case "usage.stop": .usageStop
    case "usage.scan": .usageScan
    default: nil
    }
  }

  public static func line(_ event: Event) -> String {
    switch event {
    case .ready: "ready"
    case .usageProgress(let done, let total): "usage.progress \(done) \(total)"
    case .usageScanned(let read): "usage.scanned \(read)"
    case .journalCollected(let id, let ok): "journal.collected \(id) \(ok ? 1 : 0)"
    }
  }

  public static func event(from line: String) -> Event? {
    let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
    switch (parts.first, parts.dropFirst().compactMap(Int.init)) {
    case ("ready", _): return .ready
    case ("usage.progress", let numbers) where numbers.count == 2 && parts.count == 3:
      return .usageProgress(done: numbers[0], total: numbers[1])
    case ("usage.scanned", let numbers) where numbers.count == 1 && parts.count == 2:
      return .usageScanned(read: numbers[0])
    case ("journal.collected", let numbers) where numbers.count == 2 && parts.count == 3:
      return .journalCollected(id: numbers[0], ok: numbers[1] == 1)
    default: return nil
    }
  }
}

/// Whole lines out of chunks of bytes: a line split across two reads comes out once, when its end arrives.
public struct HelperLines: Sendable {
  private var pending = Data()

  public init() {}

  public mutating func append(_ data: Data) -> [String] {
    pending.append(data)
    var lines: [String] = []
    while let newline = pending.firstIndex(of: 0x0A) {
      lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
      pending = Data(pending[pending.index(after: newline)...])
    }
    return lines
  }
}

/// How long to wait before starting the helper again after it exits: 1, 2, 4, 8, 16, then 30 seconds, and back to 1
/// once a run has lasted a minute (so a crash loop slows down and a rare crash restarts at once).
public struct HelperBackoff: Equatable, Sendable {
  public static let steady: TimeInterval = 60
  public static let longest: TimeInterval = 30
  private var failures = 0

  public init() {}

  /// The helper exited after running `seconds`: the wait before the next start.
  public mutating func delay(afterRunning seconds: TimeInterval) -> TimeInterval {
    if seconds >= Self.steady { failures = 0 }
    failures += 1
    return min(Self.longest, pow(2, Double(min(failures, 10) - 1)))
  }
}
