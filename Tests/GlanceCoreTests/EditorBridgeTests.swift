import Foundation
import Testing
@testable import GlanceCore

@Test func requestsDecodeFromThePagesMessages() {
  #expect(EditorRequest(body: ["type": "ready"]) == .ready)
  #expect(EditorRequest(body: ["type": "read", "id": 3, "path": "a/b.swift"]) == .read(id: 3, path: "a/b.swift"))
  #expect(EditorRequest(body: ["type": "list", "id": 8, "path": ""]) == .list(id: 8, path: ""))
  #expect(EditorRequest(body: ["type": "create", "id": 9, "path": "a/b.ts"]) == .create(id: 9, path: "a/b.ts", directory: false))
  #expect(EditorRequest(body: ["type": "create", "id": 9, "path": "a", "dir": true]) == .create(id: 9, path: "a", directory: true))
  #expect(EditorRequest(body: ["type": "quickOpen", "id": 4, "query": "app"]) == .quickOpen(id: 4, query: "app"))
  #expect(EditorRequest(body: ["type": "save", "id": 5, "path": "x", "text": "t", "modified": 12.5, "bom": false])
    == .save(id: 5, path: "x", text: "t", modified: 12.5, bom: false))
  #expect(EditorRequest(body: ["type": "save", "id": 6, "path": "x", "text": "t", "modified": NSNull(), "bom": true])
    == .save(id: 6, path: "x", text: "t", modified: nil, bom: true))
  #expect(EditorRequest(body: ["type": "saveDone", "ok": true]) == .saveDone(ok: true))
  #expect(EditorRequest(body: ["type": "session", "json": "{\"open\":[]}"]) == .session(json: "{\"open\":[]}"))
}

@Test func theStateMessageCarriesActiveDirtyAndOpenFiles() {
  #expect(EditorRequest(body: ["type": "state", "active": "a.swift", "dirty": ["a.swift"], "open": ["a.swift", "b.swift"]])
    == .state(active: "a.swift", dirty: ["a.swift"], open: ["a.swift", "b.swift"]))
  #expect(EditorRequest(body: ["type": "state", "active": NSNull(), "dirty": [], "open": []])
    == .state(active: nil, dirty: [], open: []))
  #expect(EditorRequest(body: ["type": "state"]) == .state(active: nil, dirty: [], open: []))
}

@Test func malformedMessagesAreIgnored() {
  #expect(EditorRequest(body: "nope") == nil)
  #expect(EditorRequest(body: ["type": "read", "path": "a"]) == nil) // no id
  #expect(EditorRequest(body: ["type": "launch"]) == nil)
  #expect(EditorRequest(body: ["type": "save", "id": 1, "path": "x"]) == nil) // no text
  #expect(EditorRequest(body: ["type": "saveDone"]) == nil)
  #expect(EditorRequest(body: ["type": "session"]) == nil)
}

private func payload(of script: String, call: String) throws -> [String: Any] {
  #expect(script.hasPrefix(call + "("), "\(script.prefix(60))")
  let json = String(script.dropFirst(call.count + 1).dropLast())
  return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

@Test func anOpenedFileReachesThePageIntact() throws {
  let text = "line \"quoted\" \\ back\u{2028}sep 🙂 </script>\n\tend"
  let script = EditorReply.opened(id: 7, .init(path: "src/é.swift", text: text, modified: 1_700_000_000.123456, bom: true))
  let reply = try payload(of: script, call: "editorHost.reply")
  #expect(reply["id"] as? Int == 7)
  #expect(reply["ok"] as? Bool == true)
  let result = try #require(reply["result"] as? [String: Any])
  #expect(result["text"] as? String == text)
  #expect(result["path"] as? String == "src/é.swift")
  #expect(result["language"] as? String == "swift")
  #expect(result["modified"] as? Double == 1_700_000_000.123456)
  #expect(result["bom"] as? Bool == true)
}

@Test func failuresCarryACodeAndAMessage() throws {
  let reply = try payload(of: EditorReply.failed(id: 2, .changedOnDisk), call: "editorHost.reply")
  #expect(reply["ok"] as? Bool == false)
  let error = try #require(reply["error"] as? [String: Any])
  #expect(error["code"] as? String == "changed-on-disk")
  #expect(!(error["message"] as? String ?? "").isEmpty)
}

@Test func savedPathAndDirectoryRepliesCarryTheirData() throws {
  let saved = try payload(of: EditorReply.saved(id: 1, modified: 5.5), call: "editorHost.reply")
  #expect((saved["result"] as? [String: Any])?["modified"] as? Double == 5.5)
  let paths = try payload(of: EditorReply.paths(id: 2, ["a", "b/c"]), call: "editorHost.reply")
  #expect((paths["result"] as? [String: Any])?["paths"] as? [String] == ["a", "b/c"])
  let listing = try payload(of: EditorReply.entries(id: 3, [.init(name: "src", isDirectory: true), .init(name: "a b.txt", isDirectory: false)]),
                            call: "editorHost.reply")
  let entries = try #require((listing["result"] as? [String: Any])?["entries"] as? [[String: Any]])
  #expect(entries.count == 2)
  #expect(entries[0]["name"] as? String == "src")
  #expect(entries[0]["dir"] as? Bool == true)
  #expect(entries[1]["name"] as? String == "a b.txt")
  #expect(entries[1]["dir"] as? Bool == false)
}

@Test func externalChangesNameTheFile() throws {
  let changed = try payload(of: EditorReply.externalChange(path: "a/b.swift", modified: 9), call: "editorHost.externalChange")
  #expect(changed["path"] as? String == "a/b.swift")
  #expect(changed["modified"] as? Double == 9)
  let gone = try payload(of: EditorReply.externalChange(path: "a/b.swift", modified: nil), call: "editorHost.externalChange")
  #expect(gone["modified"] is NSNull)
}

@Test func openRequestsCarryTheFileAndPosition() throws {
  let both = try payload(of: EditorReply.open(path: "src/x.swift", line: 12, column: 5), call: "editorHost.open")
  #expect(both["path"] as? String == "src/x.swift")
  #expect(both["line"] as? Int == 12)
  #expect(both["column"] as? Int == 5)
  let bare = try payload(of: EditorReply.open(path: "x", line: nil, column: nil), call: "editorHost.open")
  #expect(bare["line"] is NSNull)
  #expect(bare["column"] is NSNull)
}

@Test func theProjectReplyNamesTheRootFolder() throws {
  let project = try payload(of: EditorReply.project(root: "/Users/me/Code/my \"app\""), call: "editorHost.project")
  #expect(project["name"] as? String == "my \"app\"")
  #expect(project["root"] as? String == "/Users/me/Code/my \"app\"")
}

@Test func aStoredSessionIsRestoredOnlyWhenItIsAJSONObject() throws {
  let json = #"{"open":["a \"b\".swift"],"active":"a \"b\".swift","treeWidth":240}"#
  let script = try #require(EditorReply.restore(sessionJSON: json))
  let restored = try payload(of: script, call: "editorHost.restore")
  #expect(restored["open"] as? [String] == ["a \"b\".swift"])
  #expect(restored["treeWidth"] as? Int == 240)
  #expect(EditorReply.restore(sessionJSON: "[1,2]") == nil)
  #expect(EditorReply.restore(sessionJSON: "not json") == nil)
  #expect(EditorReply.restore(sessionJSON: "") == nil)
  #expect(EditorReply.restore(sessionJSON: #"{"open":[]} ; alert(1)"#) == nil)
}

@Test func formatRequestsAndReplies() throws {
  #expect(EditorRequest(body: ["type": "format", "id": 4, "path": "a.py", "text": "x=1", "onSave": true])
    == .format(id: 4, path: "a.py", text: "x=1", onSave: true, range: nil))
  #expect(EditorRequest(body: ["type": "format", "id": 5, "path": "a.ts"]) == .format(id: 5, path: "a.ts", text: nil, onSave: false, range: nil))
  #expect(EditorRequest(body: ["type": "format", "id": 6, "path": "a.ts", "text": "t", "rangeStart": 2, "rangeEnd": 9])
    == .format(id: 6, path: "a.ts", text: "t", onSave: false, range: 2..<9))
  #expect(EditorRequest(body: ["type": "format", "id": 7, "path": "a.ts", "rangeStart": 9, "rangeEnd": 2])
    == .format(id: 7, path: "a.ts", text: nil, onSave: false, range: nil)) // backwards: ignored
  #expect(EditorRequest(body: ["type": "format", "path": "a.ts"]) == nil)

  let prettier = try payload(of: EditorReply.formatWithPrettier(id: 1, parser: "babel", options: ["semi": false]), call: "editorHost.reply")
  let how = try #require((prettier["result"] as? [String: Any])?["prettier"] as? [String: Any])
  #expect(how["parser"] as? String == "babel")
  #expect((how["options"] as? [String: Any])?["semi"] as? Bool == false)
  let failed = try payload(of: EditorReply.formatFailed(id: 2, .noFormatter("No formatter")), call: "editorHost.reply")
  #expect((failed["error"] as? [String: Any])?["code"] as? String == "noFormatter")

  let opened = { (path: String) throws -> Any? in
    let reply = try payload(of: EditorReply.opened(id: 1, .init(path: path, text: "", modified: 0, bom: false)), call: "editorHost.reply")
    return (reply["result"] as? [String: Any])?["formatter"]
  }
  #expect(try opened("web/a.tsx") as? String == "prettier")
  #expect(try opened("a.go") as? String == "command")
  #expect(try opened("notes.txt") is NSNull)
}
