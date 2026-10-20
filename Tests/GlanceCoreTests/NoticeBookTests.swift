import Foundation
import Testing
@testable import GlanceCore

private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

private func notice(_ id: String, thread: String = "t1", kind: Notice.Kind = .slackChannel, at seconds: TimeInterval = 0)
  -> Notice {
  Notice(id: id, source: kind.source, kind: kind, title: "Riya", place: "#infra", preview: "msg \(id)",
         date: t0.addingTimeInterval(seconds), threadKey: thread, target: .none)
}

@Test func addingTheSameIdTwiceKeepsOne() {
  var book = NoticeBook()
  let first = book.add(notice("a"), now: t0)
  let second = book.add(notice("a"), now: t0)
  #expect(first)
  #expect(!second)
  #expect(book.notices.count == 1)
}

@Test func aThreadFoldsIntoItsNewestNotice() {
  var book = NoticeBook()
  for i in 0..<20 { book.add(notice("m\(i)", at: TimeInterval(i)), now: t0) }
  let rows = book.rows(filter: nil, showDone: false)
  #expect(rows.count == 1)
  #expect(rows[0].newest.id == "m19")
  #expect(rows[0].folded == 19)
  #expect(rows[0].unread)
}

@Test func rowsAreNewestFirstAndFilterBySource() {
  var book = NoticeBook()
  book.add(notice("s", thread: "slack", kind: .slackDM, at: 1), now: t0)
  book.add(notice("g", thread: "gh", kind: .githubComment, at: 2), now: t0)
  #expect(book.rows(filter: nil, showDone: false).map(\.newest.id) == ["g", "s"])
  #expect(book.rows(filter: .slack, showDone: false).map(\.newest.id) == ["s"])
}

@Test func doneThreadsHideAndANewNoticeReopensThem() {
  var book = NoticeBook()
  book.add(notice("a"), now: t0)
  book.markDone(threadKey: "t1")
  #expect(book.rows(filter: nil, showDone: false).isEmpty)
  #expect(book.rows(filter: nil, showDone: true).count == 1)
  book.add(notice("b", at: 5), now: t0)
  let rows = book.rows(filter: nil, showDone: false)
  #expect(rows.count == 1 && rows[0].unread && rows[0].folded == 1)
}

@Test func sectionsPutUnreadDirectAsksFirst() {
  var book = NoticeBook()
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let now = t0.addingTimeInterval(60)
  book.add(notice("dm", thread: "dm", kind: .slackDM), now: now)
  book.add(notice("ch", thread: "ch", kind: .slackChannel), now: now)
  book.add(notice("old", thread: "old", kind: .slackChannel, at: -3 * 86_400), now: now)
  let sections = book.sections(filter: nil, showDone: false, now: now, calendar: calendar)
  #expect(sections.map(\.kind) == [.needsYou, .today, .earlier])
  #expect(sections[0].rows.map(\.newest.id) == ["dm"])
  // A read direct ask is no longer "Needs you".
  book.markRead(threadKey: "dm")
  #expect(book.sections(filter: nil, showDone: false, now: now, calendar: calendar).first?.kind == .today)
}

@Test func theBadgeCountsUnreadNeedsYouThreads() {
  var book = NoticeBook()
  book.add(notice("a", thread: "a", kind: .slackDM), now: t0)
  book.add(notice("b", thread: "a", kind: .slackDM, at: 1), now: t0)
  book.add(notice("c", thread: "c", kind: .slackChannel), now: t0)
  #expect(book.badge == 1)
  #expect(book.unreadCount(nil) == 2)
  #expect(book.unreadCount(.github) == 0)
  book.markAllRead(filter: .slack)
  #expect(book.badge == 0)
}

@Test func pruningKeepsThirtyDaysAndTwoThousand() {
  var book = NoticeBook()
  book.add(notice("old", thread: "o", at: -31 * 86_400), now: t0)
  for i in 0..<2_005 { book.add(notice("n\(i)", thread: "n\(i)", at: TimeInterval(i)), now: t0) }
  book.prune(now: t0)
  #expect(book.notices.count == 2_000)
  #expect(!book.notices.contains { $0.id == "old" })
  #expect(!book.notices.contains { $0.id == "n0" })
}

@Test func garbageDoesNotDecode() {
  #expect(NoticeBook.decode(Data("not json".utf8)) == nil)
  var book = NoticeBook()
  book.add(notice("a"), now: t0)
  #expect(NoticeBook.decode(book.encoded()) == book)
}
