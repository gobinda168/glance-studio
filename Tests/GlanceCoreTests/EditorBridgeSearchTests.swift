import Foundation
import Testing
@testable import GlanceCore

@Test func searchRequestsCarryTheQueryAndOptions() {
  let body: [String: Any] = ["type": "search", "id": 4, "query": "foo(", "options": ["caseSensitive": true, "wholeWord": false, "regex": true]]
  #expect(EditorRequest(body: body) == .search(id: 4, query: "foo(", options: SearchOptions(caseSensitive: true, wholeWord: false, regex: true)))
  #expect(EditorRequest(body: ["type": "search", "id": 5, "query": "x"]) == .search(id: 5, query: "x", options: SearchOptions()))
  #expect(EditorRequest(body: ["type": "search", "query": "x"]) == nil) // no id
  #expect(EditorRequest(body: ["type": "search", "id": 5]) == nil) // no query
}

@Test func replaceRequestsCarryTheReplacementTargetsAndSkips() {
  let body: [String: Any] = ["type": "replace", "id": 9, "query": "a", "replacement": "b", "options": ["regex": false],
                             "paths": ["x.txt"], "skip": ["y.txt", "z.txt"]]
  #expect(EditorRequest(body: body) == .replace(id: 9, query: "a", options: SearchOptions(), replacement: "b", paths: ["x.txt"], skip: ["y.txt", "z.txt"]))
  let bare: [String: Any] = ["type": "replace", "id": 10, "query": "a", "replacement": ""]
  #expect(EditorRequest(body: bare) == .replace(id: 10, query: "a", options: SearchOptions(), replacement: "", paths: nil, skip: []))
  #expect(EditorRequest(body: ["type": "replace", "id": 10, "query": "a"]) == nil) // no replacement
}

private func result(of script: String) throws -> [String: Any] {
  let prefix = "editorHost.reply("
  #expect(script.hasPrefix(prefix))
  let reply = try #require(JSONSerialization.jsonObject(with: Data(script.dropFirst(prefix.count).dropLast().utf8)) as? [String: Any])
  return try #require(reply["result"] as? [String: Any])
}

@Test func searchResultsReachThePageIntact() throws {
  let match = SearchMatch(path: "src/é.swift", line: 3, column: 7, length: 5, preview: "let \"value\" = 1", previewStart: 5)
  let r = try result(of: EditorReply.searchResults(id: 1, SearchResult(matches: [match], truncated: true, fileCount: 1)))
  #expect(r["truncated"] as? Bool == true)
  #expect(r["files"] as? Int == 1)
  let matches = try #require(r["matches"] as? [[String: Any]])
  #expect(matches.count == 1)
  #expect(matches[0]["path"] as? String == "src/é.swift")
  #expect(matches[0]["line"] as? Int == 3)
  #expect(matches[0]["column"] as? Int == 7)
  #expect(matches[0]["length"] as? Int == 5)
  #expect(matches[0]["preview"] as? String == "let \"value\" = 1")
  #expect(matches[0]["previewStart"] as? Int == 5)
}

@Test func replaceResultsListSkippedAndFailedFiles() throws {
  let done = ReplaceResult(replacements: 4, files: 2, skipped: ["a.txt"], failed: [ReplaceFailure(path: "b.txt", message: "The file changed on disk.")])
  let r = try result(of: EditorReply.replaced(id: 2, done))
  #expect(r["replacements"] as? Int == 4)
  #expect(r["files"] as? Int == 2)
  #expect(r["skipped"] as? [String] == ["a.txt"])
  let failed = try #require(r["failed"] as? [[String: Any]])
  #expect(failed.first?["path"] as? String == "b.txt")
  #expect(failed.first?["message"] as? String == "The file changed on disk.")
}

@Test func codedFailuresCarryTheirCodeAndMessage() throws {
  let script = EditorReply.failed(id: 3, code: "invalid-pattern", message: "Invalid regular expression: x")
  let reply = try #require(JSONSerialization.jsonObject(with: Data(script.dropFirst("editorHost.reply(".count).dropLast().utf8)) as? [String: Any])
  #expect(reply["ok"] as? Bool == false)
  let error = try #require(reply["error"] as? [String: Any])
  #expect(error["code"] as? String == "invalid-pattern")
  #expect(error["message"] as? String == "Invalid regular expression: x")
}
