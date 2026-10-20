import Foundation
import Testing
@testable import GlanceCore

@Test func theListLeavesOutRemoteHeadsAndBranchesAlreadyLocal() {
  let list = GitBranches.list(current: "dev\n", local: "dev\nmain\n", remote: "origin\norigin/HEAD\norigin/main\norigin/feat/x\n")
  #expect(list == .init(current: "dev", local: ["dev", "main"], remote: ["origin/feat/x"]))
  #expect(GitBranches.list(current: nil, local: "main\n", remote: "").current == nil)
}

@Test func switchingRunsGitSwitch() {
  #expect(GitBranches.switchArguments(to: "main", create: false, remote: false) == ["switch", "main"])
  #expect(GitBranches.switchArguments(to: "feat/y", create: true, remote: false) == ["switch", "-c", "feat/y"])
  #expect(GitBranches.switchArguments(to: "origin/feat/x", create: false, remote: true) == ["switch", "feat/x"])
}

@Test func thePageAsksForBranchesAndASwitch() throws {
  #expect(EditorRequest(body: ["type": "branches", "id": 1]) == .branches(id: 1))
  #expect(EditorRequest(body: ["type": "switchBranch", "id": 2, "name": "dev"]) == .switchBranch(id: 2, name: "dev", create: false, remote: false))
  #expect(EditorRequest(body: ["type": "switchBranch", "id": 2, "name": "x", "create": true]) == .switchBranch(id: 2, name: "x", create: true, remote: false))
  #expect(EditorRequest(body: ["type": "switchBranch", "id": 2, "name": ""]) == nil)
  #expect(EditorReply.branches(id: 1, nil).contains("notGit"))
  #expect(EditorReply.switchedBranch(id: 2, error: "local changes").contains("\"code\":\"git\""))
}

@Test func switchesARealRepository() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("glance-branches-\(UUID().uuidString)").path
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: root) }
  for arguments in [["init", "-q", "-b", "main"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"]] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root] + arguments
    try process.run()
    process.waitUntilExit()
  }
  #expect(GitBranches.switchBranch(root: root, to: "feat/y", create: true, remote: false) == nil)
  #expect(GitBranches.list(root: root)?.current == "feat/y")
  #expect(GitBranches.switchBranch(root: root, to: "main", create: false, remote: false) == nil)
  let list = try #require(GitBranches.list(root: root))
  #expect(list.current == "main" && Set(list.local) == ["feat/y", "main"] && list.remote.isEmpty)
  #expect(GitBranches.switchBranch(root: root, to: "nope", create: false, remote: false) != nil)
}
