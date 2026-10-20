import Foundation
import Testing
@testable import GlanceCore

/// The JSON argument of an `editorHost.<name>(…)` call.
private func argument(_ script: String, _ name: String) throws -> Any {
  let prefix = "editorHost.\(name)("
  #expect(script.hasPrefix(prefix) && script.hasSuffix(")"))
  let json = String(script.dropFirst(prefix.count).dropLast())
  return try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
}

@Test func thePageAsksForChangesAndHeadText() {
  #expect(EditorRequest(body: ["type": "changes", "id": 4]) == .changes(id: 4))
  #expect(EditorRequest(body: ["type": "headText", "id": 5, "path": "a b.swift"]) == .headText(id: 5, path: "a b.swift"))
  #expect(EditorRequest(body: ["type": "headText", "id": 5]) == nil)
  #expect(EditorRequest(body: ["type": "changes"]) == nil)
}

@Test func outsideGitTheChangesReplyFails() throws {
  let reply = try #require(try argument(EditorReply.changes(id: 4, nil), "reply") as? [String: Any])
  #expect(reply["ok"] as? Bool == false)
  #expect((reply["error"] as? [String: Any])?["code"] as? String == "notGit")
}

@Test func headTextIsNullForANewFile() throws {
  let some = try #require(try argument(EditorReply.headText(id: 2, "x\ny"), "reply") as? [String: Any])
  #expect((some["result"] as? [String: Any])?["text"] as? String == "x\ny")
  let none = try #require(try argument(EditorReply.headText(id: 2, nil), "reply") as? [String: Any])
  #expect((none["result"] as? [String: Any])?["text"] is NSNull)
}

@Test func claudesFilesGoToBothEditors() throws {
  #expect(try argument(EditorReply.claudeFiles(["a.swift", "d/b.md"]), "claudeFiles") as? [String] == ["a.swift", "d/b.md"])
  let line = EditorBridgeCommand.claudeFiles(["a b.swift"]).line
  let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
  #expect(json["type"] as? String == "claudeFiles" && json["paths"] as? [String] == ["a b.swift"])
}

@Test func thePageAsksForTheBranch() throws {
  #expect(EditorRequest(body: ["type": "branch", "id": 3]) == .branch(id: 3))
  #expect(EditorRequest(body: ["type": "branch"]) == nil)
  let named = try #require(try argument(EditorReply.branch(id: 3, "main"), "reply") as? [String: Any])
  #expect((named["result"] as? [String: Any])?["branch"] as? String == "main")
  let none = try #require(try argument(EditorReply.branch(id: 3, nil), "reply") as? [String: Any])
  #expect((none["result"] as? [String: Any])?["branch"] is NSNull)
}

@Test func thePageStagesUnstagesRevertsAndCommits() {
  #expect(EditorRequest(body: ["type": "indexText", "id": 1, "path": "a"]) == .indexText(id: 1, path: "a"))
  #expect(EditorRequest(body: ["type": "stage", "id": 1, "paths": ["a", "b"]]) == .stage(id: 1, paths: ["a", "b"]))
  #expect(EditorRequest(body: ["type": "stage", "id": 1, "paths": []]) == nil)
  #expect(EditorRequest(body: ["type": "unstage", "id": 2, "paths": ["a"]]) == .unstage(id: 2, paths: ["a"]))
  #expect(EditorRequest(body: ["type": "discard", "id": 3, "tracked": ["a"], "untracked": ["b"]])
    == .discard(id: 3, tracked: ["a"], untracked: ["b"]))
  #expect(EditorRequest(body: ["type": "discard", "id": 3]) == nil)
  #expect(EditorRequest(body: ["type": "commit", "id": 4, "message": "feat: x"]) == .commit(id: 4, message: "feat: x"))
  #expect(EditorRequest(body: ["type": "commit", "id": 4, "message": "  \n"]) == nil)
  #expect(EditorRequest(body: ["type": "draftCommit"]) == .draftCommit)
  #expect(EditorRequest(body: ["type": "draftCommitStop"]) == .draftCommitStop)
}

@Test func changesReplyListsStagedAndUnstaged() throws {
  let lists = GitChanges.Lists(staged: [.init(path: "b.swift", status: .renamed, oldPath: "c.swift")],
                               unstaged: [.init(path: "a.swift", status: .untracked)])
  let reply = try #require(try argument(EditorReply.changes(id: 4, lists), "reply") as? [String: Any])
  let result = try #require(reply["result"] as? [String: Any])
  let staged = try #require(result["staged"] as? [[String: Any]])
  let unstaged = try #require(result["unstaged"] as? [[String: Any]])
  #expect(staged.count == 1 && staged[0]["status"] as? String == "R" && staged[0]["oldPath"] as? String == "c.swift")
  #expect(unstaged.count == 1 && unstaged[0]["path"] as? String == "a.swift" && unstaged[0]["status"] as? String == "U")
}

@Test func gitActionsAnswerDoneOrGitsMessage() throws {
  let done = try #require(try argument(EditorReply.gitDone(id: 1, error: nil), "reply") as? [String: Any])
  #expect(done["ok"] as? Bool == true)
  let failed = try #require(try argument(EditorReply.gitDone(id: 1, error: "hook failed"), "reply") as? [String: Any])
  let error = try #require(failed["error"] as? [String: Any])
  #expect(error["code"] as? String == "git" && error["message"] as? String == "hook failed")
}

@Test func theCommitDraftStreamsToThePage() throws {
  let text = try #require(try argument(EditorReply.commitDraft(.text("feat")), "commitDraft") as? [String: Any])
  #expect(text["kind"] as? String == "text" && text["text"] as? String == "feat")
  let done = try #require(try argument(EditorReply.commitDraft(.done("```\nfeat: x\n```")), "commitDraft") as? [String: Any])
  #expect(done["kind"] as? String == "done" && done["text"] as? String == "feat: x")
  let failed = try #require(try argument(EditorReply.commitDraft(.failed("no claude")), "commitDraft") as? [String: Any])
  #expect(failed["kind"] as? String == "failed" && failed["message"] as? String == "no claude")
}
