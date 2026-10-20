import Foundation
import Testing
@testable import GlanceCore

private func run(_ command: String, _ seconds: Double, folder: String? = "/proj", tab: String? = "A", exit: Int? = 0,
                 imported: Bool = false) -> CommandRecord {
  CommandRecord(command: command, folder: folder, start: Date(timeIntervalSince1970: seconds), duration: 1,
                exitCode: exit, tab: tab, gitRoot: nil, branch: nil, imported: imported)
}

@Test func upListPutsThisTabFirst() {
  let index = CommandIndex([
    run("make", 10, tab: "A"),
    run("rm -rf build", 50, tab: "B"),          // newest overall, but another tab
    run("git status", 20, tab: "A"),
    run("ls", 30, folder: "/elsewhere", tab: "C"),
    run("npm test", 40, folder: "/proj", tab: "C"),
  ])
  let rows = index.upList(typed: "", tab: "A", folder: "/proj")
  #expect(rows.map(\.entry.command) == ["git status", "make", "rm -rf build", "npm test", "ls"])
  #expect(rows.map(\.section) == [.tab, .tab, .folder, .folder, .everywhere])
}

@Test func upListShowsEachCommandOnceAtItsLatestRun() {
  let index = CommandIndex([run("ls", 1), run("pwd", 2), run("ls", 3)])
  let rows = index.upList(typed: "", tab: "A", folder: "/proj")
  #expect(rows.map(\.entry.command) == ["ls", "pwd"])
  #expect(rows[0].entry.count == 2)
  #expect(rows[0].entry.lastStart == Date(timeIntervalSince1970: 3))
}

@Test func typingNarrowsPrefixBeforeSubstring() {
  let index = CommandIndex([run("echo git", 3), run("git push", 2), run("git status", 1), run("ls", 4)])
  let rows = index.upList(typed: "git", tab: "A", folder: "/proj")
  #expect(rows.map(\.entry.command) == ["git push", "git status", "echo git"])
  #expect(rows[0].highlight == [0..<3])
  #expect(rows[2].highlight == [5..<8])
}

@Test func aTypoStillFindsTheCommand() {
  let index = CommandIndex([run("pnpm dev", 3), run("pnpm build", 2), run("npm test", 1), run("pwd", 4)])
  let rows = index.upList(typed: "pnpf de", tab: "A", folder: "/proj")
  #expect(rows.map(\.entry.command) == ["pnpm dev"])
  #expect(rows[0].highlight == [0..<4, 5..<7])
  // Each word in its place: `gti stauts` is git status, a word too short to guess at must match.
  let git = CommandIndex([run("git status", 1), run("gh pr list", 2)])
  #expect(git.upList(typed: "gti stauts", tab: "A", folder: "/proj").map(\.entry.command) == ["git status"])
  #expect(git.upList(typed: "gx", tab: "A", folder: "/proj").isEmpty)
}

@Test func typoMatchesOnlyWhenNothingMatchesExactly() {
  let index = CommandIndex([run("nmp dev", 2), run("npm dev", 1)])
  #expect(index.upList(typed: "npm d", tab: "A", folder: "/proj").map(\.entry.command) == ["npm dev"])
}

@Test func commandsThatWouldntRunAreLeftOut() {
  let index = CommandIndex([run("pnpf dev", 3, exit: 127), run("pnpm dev", 2), run("pnpm build", 1)])
  let runs: (String) -> Bool = { LineMarks.runs($0) { $0 == "pnpm" } }
  #expect(index.upList(typed: "pn", tab: "A", folder: "/proj", runs: runs).map(\.entry.command)
    == ["pnpm dev", "pnpm build"])
  #expect(index.upList(typed: "pnpf de", tab: "A", folder: "/proj", runs: runs).map(\.entry.command) == ["pnpm dev"])
  #expect(!index.search("dev", scope: .all, tab: "A", folder: "/proj", runs: runs).map(\.entry.command)
    .contains("pnpf dev"))
}

@Test func searchFindsWordsInAnyOrder() {
  let index = CommandIndex([run("docker compose up -d", 1), run("docker ps", 2), run("make up", 3)])
  let hits = index.search("comp dock up", scope: .all, tab: "A", folder: "/proj")
  #expect(hits.map(\.entry.command) == ["docker compose up -d"])
  #expect(hits[0].highlight == [0..<4, 7..<11, 15..<17])
}

@Test func searchFallsBackToASubsequenceForOneWord() {
  let index = CommandIndex([run("git status", 1), run("grep -r stuff", 2)])
  let hits = index.search("gst", scope: .all, tab: "A", folder: "/proj")
  #expect(hits.first?.entry.command == "git status")
}

@Test func searchScopesToTheFolderOrTheTab() {
  let index = CommandIndex([run("make a", 1, folder: "/x", tab: "A"), run("make b", 2, folder: "/y", tab: "B")])
  #expect(index.search("make", scope: .all, tab: "A", folder: "/y").count == 2)
  #expect(index.search("make", scope: .folder, tab: "A", folder: "/y").map(\.entry.command) == ["make b"])
  #expect(index.search("make", scope: .tab, tab: "A", folder: "/y").map(\.entry.command) == ["make a"])
  #expect(HistoryScope.all.next == .folder && HistoryScope.folder.next == .tab && HistoryScope.tab.next == .all)
}

@Test func failedRunsSortBelowGoodOnes() {
  let index = CommandIndex([run("deploy --prod", 10, exit: 1), run("deploy --staging", 5, exit: 0)])
  let hits = index.search("deploy", scope: .all, tab: "A", folder: "/proj")
  #expect(hits.map(\.entry.command) == ["deploy --staging", "deploy --prod"])
}

@Test func emptySearchListsNewestFirst() {
  let index = CommandIndex([run("a", 1), run("b", 3), run("c", 2)])
  #expect(index.search("  ", scope: .all, tab: "A", folder: "/proj").map(\.entry.command) == ["b", "c", "a"])
}

@Test func addingAndRemoving() {
  var index = CommandIndex([run("ls", 1)])
  index.add(run("ls", 5, folder: "/other", tab: "Z", exit: 2))
  let ls = index.upList(typed: "ls", tab: "Z", folder: "/other")
  #expect(ls.first?.section == .tab)
  #expect(ls.first?.entry.lastExit == 2)
  #expect(ls.first?.entry.count == 2)
  index.remove(command: "ls")
  #expect(index.upList(typed: "", tab: "Z", folder: "/other").isEmpty)
}

@Test func importedRunsHaveNoTabOrFolderButStillShow() {
  let index = CommandIndex([run("old thing", 1, folder: nil, tab: nil, exit: nil, imported: true)])
  let rows = index.upList(typed: "", tab: "A", folder: "/proj")
  #expect(rows.map(\.section) == [.everywhere])
  #expect(rows[0].entry.recordedCount == 0)
}
