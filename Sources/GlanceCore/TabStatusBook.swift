import Foundation

/// What Claude is doing in each folder, for the tab sidebar: thinking from a prompt until the turn ends (or a timeout),
/// finished once a turn ends where nobody was looking, idle otherwise. Tabs are matched by working folder, so tabs in
/// one folder share a status.
public struct TabStatusBook {
  public enum Status: Equatable, Sendable { case idle, thinking, finished }

  private enum Entry { case thinking(since: Date), finished }

  private var entries: [String: Entry] = [:]
  private let home: String
  private let thinkingTimeout: TimeInterval

  public init(home: String = NSHomeDirectory(), thinkingTimeout: TimeInterval = 600) {
    self.home = home
    self.thinkingTimeout = thinkingTimeout
  }

  /// A Claude session in `cwd` sent a prompt or finished a turn. `focusedFolder` is the folder the user is looking at
  /// right now (nil when Glance Studio isn't in front): a turn that ends there is already seen.
  public mutating func turn(_ kind: TurnEvent.Kind, cwd: String?, focusedFolder: String?, at now: Date) {
    guard let cwd, !cwd.isEmpty else { return }
    let folder = SessionMatch.normalize(cwd, home: home)
    switch kind {
    case .prompt:
      entries[folder] = .thinking(since: now)
    case .done:
      let seen = SessionMatch.matches(sessionCwd: folder, surfacePwd: focusedFolder, home: home)
      entries[folder] = seen ? nil : .finished
    }
  }

  /// The user looked at a tab in `folder`: a finished turn there is seen. Thinking is unaffected.
  public mutating func visited(folder: String?) {
    guard let folder, !folder.isEmpty else { return }
    let key = SessionMatch.normalize(folder, home: home)
    if case .finished? = entries[key] { entries[key] = nil }
  }

  public func status(forTabFolder folder: String?, at now: Date) -> Status {
    guard let folder, !folder.isEmpty else { return .idle }
    switch entries[SessionMatch.normalize(folder, home: home)] {
    case .thinking(let since)?: return now.timeIntervalSince(since) > thinkingTimeout ? .idle : .thinking
    case .finished?: return .finished
    case nil: return .idle
    }
  }
}
