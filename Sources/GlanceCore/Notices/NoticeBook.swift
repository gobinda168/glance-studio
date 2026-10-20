import Foundation

/// The Notifications inbox: every notice, newest first, folded by thread for display (spec
/// 2026-10-09-notifications-design.md, "NoticeBook"). Pure; the hub owns one and saves it.
public struct NoticeBook: Codable, Equatable, Sendable {
  public static let keepDays: Double = 30
  public static let keepCount = 2_000

  public struct Row: Equatable, Identifiable, Sendable {
    public let newest: Notice
    /// The thread's other notices, under the newest.
    public let folded: Int
    public let unread: Bool
    public var id: String { newest.threadKey }
  }

  public enum SectionKind: String, Sendable { case needsYou, today, earlier, done

    public var title: String {
      switch self {
      case .needsYou: "Needs you"
      case .today: "Today"
      case .earlier: "Earlier"
      case .done: "Done"
      }
    }
  }

  public struct Section: Equatable, Identifiable, Sendable {
    public let kind: SectionKind
    public let rows: [Row]
    public var id: String { kind.rawValue }
  }

  public private(set) var notices: [Notice] = []

  public init() {}

  /// Adds a notice unless its id is already here. A notice in a done thread reopens the thread.
  @discardableResult
  public mutating func add(_ notice: Notice, now: Date) -> Bool {
    guard !notices.contains(where: { $0.id == notice.id }) else { return false }
    var notice = notice
    if notice.state == .done { notice.state = .unread }
    for index in notices.indices where notices[index].threadKey == notice.threadKey && notices[index].state == .done {
      notices[index].state = .read
    }
    let at = notices.firstIndex { $0.date <= notice.date } ?? notices.endIndex
    notices.insert(notice, at: at)
    prune(now: now)
    return true
  }

  public func rows(filter: Notice.Source?, showDone: Bool) -> [Row] {
    var order: [String] = []
    var groups: [String: [Notice]] = [:]
    for notice in notices where filter == nil || notice.source == filter {
      if groups[notice.threadKey] == nil { order.append(notice.threadKey) }
      groups[notice.threadKey, default: []].append(notice)
    }
    return order.compactMap { key in
      let group = groups[key]!
      let done = group.allSatisfy { $0.state == .done }
      if done && !showDone { return nil }
      return Row(newest: group[0], folded: group.count - 1, unread: group.contains { $0.state == .unread })
    }
  }

  public func sections(filter: Notice.Source?, showDone: Bool, now: Date, calendar: Calendar = .current)
    -> [Section] {
    var needs: [Row] = [], today: [Row] = [], earlier: [Row] = [], done: [Row] = []
    for row in rows(filter: filter, showDone: showDone) {
      if row.newest.state == .done && !row.unread { done.append(row) }
      else if row.unread && row.newest.kind.needsYou { needs.append(row) }
      else if calendar.isDate(row.newest.date, inSameDayAs: now) { today.append(row) }
      else { earlier.append(row) }
    }
    return [Section(kind: .needsYou, rows: needs), Section(kind: .today, rows: today),
            Section(kind: .earlier, rows: earlier), Section(kind: .done, rows: done)].filter { !$0.rows.isEmpty }
  }

  public mutating func markRead(threadKey: String) {
    for index in notices.indices where notices[index].threadKey == threadKey && notices[index].state == .unread {
      notices[index].state = .read
    }
  }

  public mutating func markDone(threadKey: String) {
    for index in notices.indices where notices[index].threadKey == threadKey { notices[index].state = .done }
  }

  public mutating func markAllRead(filter: Notice.Source?) {
    for index in notices.indices where notices[index].state == .unread && (filter == nil || notices[index].source == filter) {
      notices[index].state = .read
    }
  }

  /// Unread "Needs you" threads: the strip's badge.
  public var badge: Int {
    rows(filter: nil, showDone: false).filter { $0.unread && $0.newest.kind.needsYou }.count
  }

  /// Unread threads, of one source or all.
  public func unreadCount(_ source: Notice.Source?) -> Int {
    rows(filter: source, showDone: false).filter(\.unread).count
  }

  /// Drops notices older than 30 days, then the oldest beyond 2,000.
  public mutating func prune(now: Date) {
    let cutoff = now.addingTimeInterval(-Self.keepDays * 86_400)
    notices.removeAll { $0.date < cutoff }
    if notices.count > Self.keepCount { notices.removeLast(notices.count - Self.keepCount) }
  }

  public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

  public static func decode(_ data: Data) -> NoticeBook? { try? JSONDecoder().decode(NoticeBook.self, from: data) }
}
