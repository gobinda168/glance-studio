import Foundation
import Testing
@testable import GlanceCore

@Suite struct CaptureToolsTests {
  private let work = Captures.TodoGroup(name: "Work")
  private let personal = Captures.TodoGroup(name: "Personal")

  @Test func aGroupIsFoundByNameInAnyCase() {
    #expect(CaptureTools.group(named: nil, in: [work, personal]) == .success(nil))
    #expect(CaptureTools.group(named: "work", in: [work, personal]) == .success(work.id))
    #expect(CaptureTools.group(named: "Home", in: [work, personal])
      == .failure(.init("There's no to-do group named Home. The groups are Work, Personal.")))
    #expect(CaptureTools.group(named: "Home", in: [])
      == .failure(.init("There's no to-do group named Home. There are no groups.")))
  }

  @Test func todoRowsListOpenOnesFirstWithTheirGroup() {
    var filed = Captures.Todo(text: "Reply to Ankit", created: Date(timeIntervalSince1970: 2_000))
    filed.group = work.id
    let loose = Captures.Todo(text: "Buy milk", created: Date(timeIntervalSince1970: 1_000))
    let finished = Captures.Todo(text: "Ship ECI", status: .done, created: Date(timeIntervalSince1970: 3_000))
    let todos = [finished, loose, filed]

    let open = CaptureTools.todoRows(todos, groups: [work], group: nil, includeDone: false)
    #expect(open == [
      ["id": .string(filed.id.uuidString), "text": "Reply to Ankit", "status": "todo", "group": "Work"],
      ["id": .string(loose.id.uuidString), "text": "Buy milk", "status": "todo", "group": .null],
    ])
    let all = CaptureTools.todoRows(todos, groups: [work], group: nil, includeDone: true)
    #expect(all.array?.last?["text"] == "Ship ECI")
    #expect(all.array?.last?["status"] == "done")
    let inWork = CaptureTools.todoRows(todos, groups: [work], group: work.id, includeDone: true)
    #expect(inWork.array?.compactMap { $0["text"]?.string } == ["Reply to Ankit"])
  }

  @Test func noteRowsAreNewestFirstAndMatchTheQuery() {
    let older = NoteDoc(title: "Sumo attachments", body: "PNG and JPEG are built.\nHAR later.",
                        created: Date(timeIntervalSince1970: 1_000))
    let newer = NoteDoc(title: "", body: "# Groceries\nmilk", created: Date(timeIntervalSince1970: 2_000))

    let rows = CaptureTools.noteRows([older, newer], query: nil)
    #expect(rows.array?.compactMap { $0["title"]?.string } == ["Groceries", "Sumo attachments"])
    #expect(rows.array?.last?["id"] == .string(older.id.uuidString))
    #expect(rows.array?.last?["preview"] == "PNG and JPEG are built. HAR later.")
    #expect(rows.array?.last?["updated"] == "1970-01-01T00:16:40Z")
    #expect(CaptureTools.noteRows([older, newer], query: "har").array?.count == 1)
    #expect(CaptureTools.noteRows([older, newer], query: "SUMO").array?.first?["title"] == "Sumo attachments")
  }

  @Test func anIDMustBeOneTheToolsGaveOut() {
    let id = UUID()
    #expect(CaptureTools.id(id.uuidString, of: "to-do") == .success(id))
    #expect(CaptureTools.id(id.uuidString.lowercased(), of: "note") == .success(id))
    #expect(CaptureTools.id("abc", of: "note")
      == .failure(.init("abc isn't a note id; use the id that notes() gives.")))
  }
}
