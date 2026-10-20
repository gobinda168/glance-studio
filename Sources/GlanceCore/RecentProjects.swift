import Foundation

/// The projects worked in lately, newest first, for the Home tab's Recent list: each project root once, with when it
/// was last active. The app keeps it in its preferences (`encoded()`, `init(data:)`).
public struct RecentProjects: Equatable, Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public let path: String
    public let lastActive: Date

    public init(path: String, lastActive: Date) {
      self.path = path
      self.lastActive = lastActive
    }
  }

  /// How many projects are kept.
  public static let capacity = 12

  public private(set) var entries: [Entry]

  public init(entries: [Entry] = []) {
    self.entries = Array(entries.prefix(Self.capacity))
  }

  /// The stored list; missing or unreadable data is an empty one.
  public init(data: Data?) {
    self.init(entries: data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? [])
  }

  public func encoded() -> Data {
    (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8)
  }

  /// `path` was active at `date`: it moves to the front, listed once whatever the spelling (`~`, a trailing slash).
  /// The home folder and `/` are where shells start, not projects.
  public mutating func record(_ path: String, at date: Date, home: String = NSHomeDirectory()) {
    guard !path.isEmpty else { return }
    let normalized = SessionMatch.normalize(path, home: home)
    guard normalized != "/", normalized != SessionMatch.normalize(home, home: home) else { return }
    entries.removeAll { $0.path == normalized }
    entries.insert(Entry(path: normalized, lastActive: date), at: 0)
    if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
  }

  /// Drops the projects whose folder is gone.
  public mutating func prune(exists: (String) -> Bool) {
    entries.removeAll { !exists($0.path) }
  }

  /// A first list from projects known another way (the editor's saved sessions), most recently active first. A
  /// project with no date is left out.
  public static func seeded(
    paths: [String], lastActive: (String) -> Date?, home: String = NSHomeDirectory()
  ) -> RecentProjects {
    var list = RecentProjects()
    let dated = paths.compactMap { path in lastActive(path).map { (path: path, date: $0) } }
    for project in dated.sorted(by: { $0.date < $1.date }) {
      list.record(project.path, at: project.date, home: home)
    }
    return list
  }

  /// "just now", "5m ago", "2h ago", "3d ago", "2w ago".
  public static func age(of date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    if seconds < 7 * 86400 { return "\(seconds / 86400)d ago" }
    return "\(seconds / (7 * 86400))w ago"
  }
}
