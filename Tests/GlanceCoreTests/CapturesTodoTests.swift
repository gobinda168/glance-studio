import Foundation
import Testing
@testable import GlanceCore

private func decode(_ json: String) throws -> [Captures.Todo] {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode([Captures.Todo].self, from: Data(json.utf8))
}

private func encode(_ todos: [Captures.Todo]) throws -> Data {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  return try encoder.encode(todos)
}

private let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

@Test func anOldFileLoadsWithStatusFromDoneAndDefaults() throws {
  let old = """
    [{"id":"\(id.uuidString)","text":"Ship it","done":true,"created":"2026-10-13T09:41:00Z","source":"Safari"},
     {"id":"22222222-2222-2222-2222-222222222222","text":"Write docs","done":false,"created":"2026-10-12T09:00:00Z"}]
    """
  let todos = try decode(old)
  #expect(todos[0].status == .done)
  #expect(todos[0].done)
  #expect(todos[0].source == "Safari")
  #expect(todos[1].status == .todo)
  #expect(todos[1].notes == "" && todos[1].due == nil && todos[1].priority == .none)
  #expect(todos[1].tags.isEmpty && todos[1].link == nil && todos[1].subitems.isEmpty)
  // Newest first, as the old list showed them.
  #expect(todos[0].order < todos[1].order)
}

@Test func aTodoRoundTripsAndWritesStatusNotDone() throws {
  var todo = Captures.Todo(text: "Rotate keys", status: .doing, created: Date(timeIntervalSince1970: 1_790_000_000), source: "Terminal")
  todo.notes = "See the runbook"
  todo.due = Date(timeIntervalSince1970: 1_800_000_000)
  todo.priority = .high
  todo.tags = ["auth"]
  todo.link = "~/Code/acme/README.md"
  todo.addSubitem("Draft")
  let data = try encode([todo])
  let text = String(decoding: data, as: UTF8.self)
  #expect(text.contains("\"status\":\"doing\""))
  let keys = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first?.keys
  #expect(keys?.contains("done") == false)
  let back = try JSONDecoder.iso.decode([Captures.Todo].self, from: data)
  #expect(back == [todo])
}

@Test func aColumnIsItsStatusInOrder() {
  let a = Captures.Todo(text: "a", order: 2)
  let b = Captures.Todo(text: "b", order: 1)
  let c = Captures.Todo(text: "c", status: .done, order: 0)
  #expect(Captures.column([a, b, c], .todo).map(\.text) == ["b", "a"])
  #expect(Captures.column([a, b, c], .done).map(\.text) == ["c"])
  #expect(Captures.topOrder([a, b, c], .todo) == 0)
  #expect(Captures.topOrder([a, b, c], .doing) == 0)
  #expect(Captures.endOrder([a, b, c], .todo) == 3)
  #expect(Captures.endOrder([a, b, c], .doing) == 0)
}

@Test func movingAcrossColumnsPlacesBetweenNeighbours() {
  let a = Captures.Todo(text: "a", order: 0)
  let x = Captures.Todo(text: "x", status: .doing, order: 0)
  let y = Captures.Todo(text: "y", status: .doing, order: 10)
  let moved = Captures.moving([a, x, y], id: a.id, to: .doing, index: 1)
  #expect(Captures.column(moved, .doing).map(\.text) == ["x", "a", "y"])
  #expect(Captures.column(moved, .todo).isEmpty)
}

@Test func movingToTheTopTheEndAndAnEmptyColumn() {
  let a = Captures.Todo(text: "a", order: 0)
  let b = Captures.Todo(text: "b", order: 1)
  let c = Captures.Todo(text: "c", order: 2)
  #expect(Captures.column(Captures.moving([a, b, c], id: c.id, to: .todo, index: 0), .todo).map(\.text) == ["c", "a", "b"])
  #expect(Captures.column(Captures.moving([a, b, c], id: a.id, to: .todo, index: 99), .todo).map(\.text) == ["b", "c", "a"])
  let done = Captures.moving([a, b, c], id: b.id, to: .done, index: 0)
  #expect(Captures.column(done, .done).map(\.text) == ["b"])
}

@Test func droppingACardOnItselfChangesNothing() {
  let a = Captures.Todo(text: "a", order: 0)
  let b = Captures.Todo(text: "b", order: 1)
  let c = Captures.Todo(text: "c", order: 2)
  let moved = Captures.moving([a, b, c], id: b.id, to: .todo, index: 1)
  #expect(Captures.column(moved, .todo).map(\.text) == ["a", "b", "c"])
}

@Test func movingAnUnknownIDChangesNothing() {
  let a = Captures.Todo(text: "a")
  #expect(Captures.moving([a], id: UUID(), to: .done, index: 0) == [a])
}

@Test func tickingSendsToDoneAndBackToToDo() {
  #expect(Captures.toggled(.todo) == .done)
  #expect(Captures.toggled(.doing) == .done)
  #expect(Captures.toggled(.done) == .todo)
}

@Test func overdueIsByDayAndNeverWhenDone() {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let now = ISO8601DateFormatter().date(from: "2026-10-14T15:00:00Z")!
  var todo = Captures.Todo(text: "x")
  todo.due = ISO8601DateFormatter().date(from: "2026-10-14T08:00:00Z")!
  #expect(!Captures.isOverdue(todo, now: now, calendar: calendar))
  todo.due = ISO8601DateFormatter().date(from: "2026-10-13T23:00:00Z")!
  #expect(Captures.isOverdue(todo, now: now, calendar: calendar))
  todo.status = .done
  #expect(!Captures.isOverdue(todo, now: now, calendar: calendar))
  todo.due = nil
  todo.status = .todo
  #expect(!Captures.isOverdue(todo, now: now, calendar: calendar))
}

@Test func dueLabelsSayTodayAndTomorrow() {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let now = ISO8601DateFormatter().date(from: "2026-10-14T15:00:00Z")!
  #expect(Captures.dueLabel(ISO8601DateFormatter().date(from: "2026-10-14T01:00:00Z")!, now: now, calendar: calendar) == "Today")
  #expect(Captures.dueLabel(ISO8601DateFormatter().date(from: "2026-10-15T20:00:00Z")!, now: now, calendar: calendar) == "Tomorrow")
  let later = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
  #expect(Captures.dueLabel(later, now: now, calendar: calendar) != "Today")
  #expect(Captures.dueLabel(later, now: now, calendar: calendar).contains("17"))
}

@Test func tagsAreUniqueSortedAndTrimmed() {
  var a = Captures.Todo(text: "a")
  a.addTag(" api ")
  a.addTag("api")
  a.addTag("")
  var b = Captures.Todo(text: "b")
  b.addTag("Auth")
  b.addTag("docs")
  #expect(a.tags == ["api"])
  #expect(Captures.allTags([a, b]) == ["api", "Auth", "docs"])
  b.removeTag("Auth")
  #expect(b.tags == ["docs"])
}

@Test func subitemsAddTickRenameRemoveAndMove() {
  var todo = Captures.Todo(text: "Release")
  todo.addSubitem("Tag")
  todo.addSubitem("  ")
  todo.addSubitem("Notes")
  todo.addSubitem("Publish")
  #expect(todo.subitems.map(\.text) == ["Tag", "Notes", "Publish"])
  todo.toggleSubitem(todo.subitems[0].id)
  #expect(todo.progress == (done: 1, total: 3))
  todo.renameSubitem(todo.subitems[1].id, to: "Release notes")
  #expect(todo.subitems[1].text == "Release notes")
  todo.renameSubitem(todo.subitems[1].id, to: "   ")
  #expect(todo.subitems[1].text == "Release notes")
  todo.moveSubitems(fromOffsets: IndexSet(integer: 2), toOffset: 0)
  #expect(todo.subitems.map(\.text) == ["Publish", "Tag", "Release notes"])
  todo.removeSubitem(todo.subitems[0].id)
  #expect(todo.subitems.map(\.text) == ["Tag", "Release notes"])
}

private extension JSONDecoder {
  static var iso: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

// MARK: Groups

@Test func anOldFileHasNoGroupAndAGroupRoundTrips() throws {
  let old = """
    [{"id":"\(id.uuidString)","text":"Ship it","status":"todo","created":"2026-10-13T09:41:00Z"}]
    """
  #expect(try decode(old)[0].group == nil)
  var todo = Captures.Todo(text: "Plan the week", created: Date(timeIntervalSince1970: 1_790_000_000))
  todo.group = UUID()
  let back = try JSONDecoder.iso.decode([Captures.Todo].self, from: try encode([todo]))
  #expect(back == [todo])
  let keys = (try JSONSerialization.jsonObject(with: try encode([Captures.Todo(text: "x")])) as? [[String: Any]])?.first?.keys
  #expect(keys?.contains("group") == false)
}

@Test func theDefaultGroupsAreWorkAndPersonal() {
  #expect(Captures.TodoGroup.defaults().map(\.name) == ["Work", "Personal"])
}

@Test func inGroupFiltersAndNilIsAll() {
  let work = UUID()
  var a = Captures.Todo(text: "a")
  a.group = work
  let b = Captures.Todo(text: "b")
  #expect(Captures.inGroup([a, b], nil).map(\.text) == ["a", "b"])
  #expect(Captures.inGroup([a, b], work).map(\.text) == ["a"])
}

@Test func movingWithinAGroupCountsOnlyThatGroupsCards() {
  let work = UUID()
  var a = Captures.Todo(text: "a", order: 0)
  a.group = work
  let other = Captures.Todo(text: "other", order: 1)
  var b = Captures.Todo(text: "b", order: 2)
  b.group = work
  var c = Captures.Todo(text: "c", status: .done, order: 0)
  c.group = work
  // c to index 1 of Work's To do column: between a and b, whatever lies between them elsewhere.
  let moved = Captures.moving([a, other, b, c], id: c.id, to: .todo, index: 1, group: work)
  let column = Captures.column(Captures.inGroup(moved, work), .todo).map(\.text)
  #expect(column == ["a", "c", "b"])
}

@Test func ungroupingClearsOnlyThatGroup() {
  let work = UUID(), home = UUID()
  var a = Captures.Todo(text: "a")
  a.group = work
  var b = Captures.Todo(text: "b")
  b.group = home
  let next = Captures.ungrouping([a, b], work)
  #expect(next[0].group == nil)
  #expect(next[1].group == home)
}
