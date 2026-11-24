import Darwin
import Foundation
import Testing
@testable import GlanceCore

struct UncommittedTests {
  @Test func filesAreCreditedOnlyWhileTheirContentIsTheAuthors() {
    let now = Fingerprint(entries: [
      "mine": .init(status: ".M", size: 1, mtime: 1, hash: "h1"),
      "edited-after": .init(status: ".M", size: 1, mtime: 1, hash: "h9"),
      "unknown": .init(status: "??", size: 1, mtime: 1, hash: "h3"),
    ])
    let authors: [String: TrackState.Authorship] = [
      "mine": .init(hash: "h1", author: .session("s1")),
      "edited-after": .init(hash: "h2", author: .session("s1")), // changed by hand since
    ]
    let files = Uncommitted.attribute(now, authors: authors)
    #expect(files.map(\.path) == ["edited-after", "mine", "unknown"])
    #expect(files.map(\.author) == [.outside, .session("s1"), .outside])
  }

  @Test func sessionNamePrefersTheSummaryTitleThenTheTask() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("summaries-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"title":"Release beta.18"}"#.utf8).write(to: folder.appendingPathComponent("s1.json"))
    #expect(SessionName.of("s1", task: "bump it", summaries: folder) == "Release beta.18")
    #expect(SessionName.of("s2", task: "fix the shell tests", summaries: folder) == "fix the shell tests")
    #expect(SessionName.of("abcdef1234", task: nil, summaries: folder) == "session abcdef12")
    let long = String(repeating: "x", count: 80)
    #expect(SessionName.of("s3", task: long, summaries: folder).count == 58)
  }

  @Test func processTreeFindsParentsAndLiveness() {
    let me = getpid()
    let parent = ProcessTree.parent(of: me)
    #expect(parent != nil)
    if let parent, let name = ProcessTree.name(of: parent) {
      #expect(ProcessTree.ancestor(of: me, named: name) == parent)
      #expect(ProcessTree.ancestor(of: me, names: [name, "something-else"]) == parent)
      #expect(ProcessTree.ancestor(of: me, names: ["something-else"]) == nil)
    }
    #expect(ProcessTree.isAlive(me))
    #expect(!ProcessTree.isAlive(999_999))
  }

  @Test func onlyAClaudeProcessMakesASessionLive() {
    // A reused pid now running something else isn't a live session.
    #expect(!ProcessTree.isClaude(getpid()))
    #expect(!ProcessTree.isClaude(0))
    #expect(!ProcessTree.isClaude(-1))
    #expect(!ProcessTree.isClaude(999_999))
  }
}
