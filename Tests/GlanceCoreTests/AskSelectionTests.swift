import Foundation
import Testing
@testable import GlanceCore

private let reply = """
  ```json
  {"answer": "A failing **deploy** log.",
   "recommended": "ticket",
   "ticket": {"title": "Deploy fails on step 3", "description": "exit 1 in build.sh"},
   "todo": {"title": "Check the deploy"},
   "note": {"title": "Deploy log", "text": "exit 1 in build.sh"}}
  ```
  """

@Test func aReplyBecomesDraftsWithTheRecommendedKindFirst() {
  let parsed = AskSelection.parse(reply)
  #expect(parsed?.answer == "A failing **deploy** log.")
  #expect(parsed?.drafts.map(\.kind) == [.ticket, .todo, .note])
  #expect(parsed?.drafts.first == .init(kind: .ticket, title: "Deploy fails on step 3", detail: "exit 1 in build.sh"))
}

@Test func theRecommendedKindMovesToTheFront() {
  let moved = reply.replacingOccurrences(of: "\"recommended\": \"ticket\"", with: "\"recommended\": \"note\"")
  #expect(AskSelection.parse(moved)?.drafts.map(\.kind) == [.note, .ticket, .todo])
}

@Test func draftsWithoutATitleAreLeftOut() {
  let parsed = AskSelection.parse(#"{"answer": "Hi", "todo": {"title": ""}, "note": {"title": "", "text": ""}}"#)
  #expect(parsed == .init(answer: "Hi", drafts: []))
}

@Test func aCodeBlockInsideTheAnswerDoesNotEndTheFence() {
  let nested = """
    ```json
    {"answer": "In `vite.config.ts`:\\n```ts\\nserver: { port: 4100, strictPort: true }\\n```\\nThen grep for `4000`.",
     "recommended": "todo",
     "todo": {"title": "Pin Vite to port 4100"}}
    ```
    """
  let parsed = AskSelection.parse(nested)
  #expect(parsed?.answer == "In `vite.config.ts`:\n```ts\nserver: { port: 4100, strictPort: true }\n```\nThen grep for `4000`.")
  #expect(parsed?.drafts.first?.title == "Pin Vite to port 4100")
}

@Test func proseOrEmptyJSONIsNotAReply() {
  #expect(AskSelection.parse("Sorry, I can't.") == nil)
  #expect(AskSelection.parse("{}") == nil)
}

@Test func thePromptCarriesTheSelectionSourceAndQuestion() {
  let prompt = AskSelection.prompt(selection: "  error: nope\n", source: "Terminal", question: "Is this bad?")
  #expect(prompt.contains("(from Terminal)"))
  #expect(prompt.contains("\"\"\"\nerror: nope\n\"\"\""))
  #expect(prompt.contains("What I want: Is this bad?"))
  #expect(!AskSelection.prompt(selection: "x", source: nil, question: " ").contains("What I want"))
}

@Test func aLongSelectionKeepsItsStartAndEnd() {
  let long = String(repeating: "a", count: 15_000) + String(repeating: "b", count: 15_000)
  let sent = AskSelection.trimmed(long)
  #expect(sent.hasPrefix("aaa") && sent.hasSuffix("bbb"))
  #expect(sent.contains("middle left out"))
  #expect(sent.count < long.count)
}

@Test func thePreviewCollapsesWhitespaceAndCuts() {
  #expect(AskSelection.preview("a\n  b\t c") == "a b c")
  #expect(AskSelection.preview(String(repeating: "x", count: 400), limit: 10) == String(repeating: "x", count: 10) + "…")
}

@Test func openTodosComeFirstNewestFirst() {
  let old = Date(timeIntervalSince1970: 1_000)
  let new = Date(timeIntervalSince1970: 2_000)
  let todos = [
    Captures.Todo(text: "done new", status: .done, created: new),
    Captures.Todo(text: "open old", created: old),
    Captures.Todo(text: "open new", created: new),
    Captures.Todo(text: "done old", status: .done, created: old),
  ]
  #expect(Captures.ordered(todos).map(\.text) == ["open new", "open old", "done new", "done old"])
}

@Test func notesGoAtTheTopUnderOneTitle() {
  let date = Date(timeIntervalSince1970: 0)
  let first = Captures.noteEntry(title: "One", text: "body", source: "Safari", date: date)
  #expect(first.hasPrefix("## One\n_"))
  #expect(first.contains("from Safari"))
  let file = Captures.prepending(first, to: "")
  let second = Captures.noteEntry(title: "", text: "", source: nil, date: date)
  let both = Captures.prepending(second, to: file)
  #expect(both.hasPrefix("# Notes\n\n## Note\n"))
  #expect(both.components(separatedBy: "# Notes").count == 2)
  #expect(both.range(of: "## Note")!.lowerBound < both.range(of: "## One")!.lowerBound)
}

private let cloud = AtlassianSite.cloud(base: URL(string: "https://acme.atlassian.net")!)
private let credential = AtlassianAPI.Credential.cloudToken(email: "ada@acme.com", token: "t")

@Test func aCreateRequestPostsTheFieldsToTheIssueEndpoint() throws {
  let request = try #require(JiraREST.createRequest(cloud, project: "ABC", issueType: "Task", summary: "Fix it",
                                                     description: "why", credential: credential))
  #expect(request.httpMethod == "POST")
  #expect(request.url?.path == "/rest/api/2/issue")
  let body = try #require(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
  let fields = try #require(body["fields"] as? [String: Any])
  #expect((fields["project"] as? [String: String])?["key"] == "ABC")
  #expect((fields["issuetype"] as? [String: String])?["name"] == "Task")
  #expect(fields["summary"] as? String == "Fix it")
  #expect(fields["description"] as? String == "why")
}

@Test func anEmptyDescriptionIsLeftOut() throws {
  let request = try #require(JiraREST.createRequest(cloud, project: "ABC", issueType: "Task", summary: "s",
                                                     description: "", credential: credential))
  let body = try #require(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
  #expect((body["fields"] as? [String: Any])?["description"] == nil)
}

@Test func projectsAndTheNewKeyAreRead() {
  let list = JiraREST.projects(Data(#"[{"key":"ABC","name":"Alpha"},{"key":"","name":"x"},{"key":"ZED"}]"#.utf8))
  #expect(list == [.init(key: "ABC", name: "Alpha"), .init(key: "ZED", name: "ZED")])
  #expect(JiraREST.projects(Data("<html>".utf8)) == nil)
  #expect(JiraREST.createdKey(Data(#"{"id":"1","key":"ABC-12"}"#.utf8)) == "ABC-12")
  #expect(JiraREST.browseURL(cloud, key: "ABC-12")?.absoluteString == "https://acme.atlassian.net/browse/ABC-12")
}

@Test func aTaskTypeIsPreferredAndSubtasksAreSkipped() {
  let tasks = Data(#"{"issueTypes":[{"name":"Sub-task","subtask":true},{"name":"Bug"},{"name":"Task"}]}"#.utf8)
  #expect(JiraREST.issueType(inProject: tasks) == "Task")
  let noTask = Data(#"{"issueTypes":[{"name":"Sub-task","subtask":true},{"name":"Story"}]}"#.utf8)
  #expect(JiraREST.issueType(inProject: noTask) == "Story")
}

@Test func aCreateFailureShowsJirasFieldError() {
  let data = Data(#"{"errorMessages":[],"errors":{"summary":"Summary is required."}}"#.utf8)
  #expect(JiraREST.failure(status: 400, data: data, site: cloud, key: nil).message == "Summary is required.")
}

@Test func savedNotesReadBackNewestFirstWithTheirMeta() {
  let date = Date(timeIntervalSince1970: 0)
  var file = ""
  file = Captures.prepending(Captures.noteEntry(title: "First", text: "one\n\ntwo", source: "Safari", date: date), to: file)
  file = Captures.prepending(Captures.noteEntry(title: "Second", text: "", source: nil, date: date), to: file)
  let entries = Captures.entries(in: file)
  #expect(entries.map(\.title) == ["Second", "First"])
  #expect(entries[1].text == "one\n\ntwo")
  #expect(entries[1].meta.hasSuffix("from Safari"))
  #expect(entries[0].text.isEmpty)
  #expect(Captures.entries(in: "").isEmpty)
}

@Test func aNoteIsTitledByItsTitleElseItsFirstLine() {
  #expect(NoteDoc(title: "Plan").displayTitle == "Plan")
  #expect(NoteDoc(body: "## Deploy steps\nmore").displayTitle == "Deploy steps")
  #expect(NoteDoc().displayTitle == "Untitled")
}

@Test func aNoteExportsItsDiagramsAsMermaidBlocks() {
  let note = NoteDoc(title: "Flow", body: "Body.",
                     diagrams: [.init(title: "Steps", code: "flowchart TD\n  A --> B", explanation: "A then B.")])
  #expect(note.markdown == "# Flow\n\nBody.\n\n## Steps\n\n```mermaid\nflowchart TD\n  A --> B\n```\n\nA then B.\n")
}

@Test func theOldNotesFileBecomesOneNoteEach() {
  let date = Date(timeIntervalSince1970: 0)
  var file = Captures.prepending(Captures.noteEntry(title: "Old", text: "a", source: nil, date: date), to: "")
  file = Captures.prepending(Captures.noteEntry(title: "New", text: "b", source: nil, date: date), to: file)
  let notes = NoteDoc.imported(from: file, now: Date(timeIntervalSince1970: 100))
  #expect(notes.map(\.title) == ["New", "Old"])
  #expect(notes[0].created > notes[1].created)
}

@Test func aDiagramReplyLosesItsFence() {
  let reply = #"{"title":"Login","mermaid":"```mermaid\nsequenceDiagram\n  A->>B: hi\n```","explanation":"A greets B."}"#
  let parsed = NoteDiagramPrompt.parse(reply)
  #expect(parsed?.title == "Login")
  #expect(parsed?.code == "sequenceDiagram\n  A->>B: hi")
  #expect(parsed?.explanation == "A greets B.")
  #expect(NoteDiagramPrompt.parse(#"{"title":"x","mermaid":""}"#) == nil)
}

@Test func theDiagramPromptCarriesTheNoteTheAskAndAFixRequest() {
  let note = NoteDoc(title: "Auth", body: "Users sign in.")
  let draw = NoteDiagramPrompt.prompt(note: note, request: "")
  #expect(draw.contains("Note: Auth") && draw.contains("Users sign in.") && draw.contains("best explains"))
  let diagram = NoteDoc.Diagram(title: "Old", code: "flowchart TD\n A-->")
  let fix = NoteDiagramPrompt.prompt(note: note, request: "fix it", revising: diagram, renderError: "Parse error")
  #expect(fix.contains("Mermaid can't render it: Parse error") && fix.contains("Change the diagram: fix it"))
}
