import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func run(_ command: String, minutesAgo: Double, folder: String? = "/proj", tab: String? = "A", exit: Int? = 0,
                 imported: Bool = false) -> CommandRecord {
  CommandRecord(command: command, folder: folder, start: now.addingTimeInterval(-minutesAgo * 60), duration: 1,
                exitCode: exit, tab: tab, gitRoot: nil, branch: nil, imported: imported)
}

private func context(_ line: String, folder: String = "/proj", previous: String? = nil, names: Set<String> = [],
                     exists: @escaping (String) -> Bool = { _ in true },
                     list: @escaping (String) -> [String]? = { _ in nil }) -> GhostContext {
  GhostContext(line: line, folder: folder, tab: "A", previous: previous, now: now, names: names, exists: exists,
               list: list)
}

@Test func theSameFolderWins() {
  let index = CommandIndex([run("npm run dev", minutesAgo: 30, folder: "/web"),
                            run("npm run build", minutesAgo: 90, folder: "/proj")])
  #expect(GhostSuggester.suggest(index, context("npm r"))?.text == "un build")
  #expect(GhostSuggester.suggest(index, context("npm r", folder: "/web"))?.text == "un dev")
}

@Test func whatFollowedThePreviousCommandWins() {
  var records: [CommandRecord] = []
  for i in 0..<4 {
    records.append(run("git add -A", minutesAgo: Double(100 - i * 10)))
    records.append(run("git commit -m \"step \(i)\"", minutesAgo: Double(99 - i * 10)))
  }
  records.append(run("git checkout main", minutesAgo: 1))
  let index = CommandIndex(records.sorted { $0.start < $1.start })
  #expect(GhostSuggester.suggest(index, context("git c", previous: "git add -A"))?.text.hasPrefix("ommit") == true)
  #expect(GhostSuggester.suggest(index, context("git c"))?.text == "heckout main")
}

@Test func failedCommandsRankBelow() {
  let index = CommandIndex([run("make deploy", minutesAgo: 1, exit: 2), run("make test", minutesAgo: 60, exit: 0)])
  #expect(GhostSuggester.suggest(index, context("make "))?.text == "test")
}

@Test func pathsThatDontExistAreSkipped() {
  let index = CommandIndex([run("cd old-module", minutesAgo: 1), run("cd src/app", minutesAgo: 50)])
  let exists = { (path: String) in path == "src/app" }
  #expect(GhostSuggester.suggest(index, context("cd ", exists: exists))?.text == "src/app")
  #expect(GhostSuggester.suggest(index, context("cd o", exists: exists)) == nil)
}

@Test func nothingForAnExactMatchOrABlankLine() {
  let index = CommandIndex([run("ls", minutesAgo: 1)])
  #expect(GhostSuggester.suggest(index, context("ls")) == nil)
  #expect(GhostSuggester.suggest(index, context("")) == nil)
  #expect(GhostSuggester.suggest(index, context(" l")) == nil)
}

@Test func multiLineCommandsAreNotGhostText() {
  let index = CommandIndex([run("for x in a b; do\n  echo $x\ndone", minutesAgo: 1)])
  #expect(GhostSuggester.suggest(index, context("for x")) == nil)
}

@Test func theFirstWordCompletesToACommandName() {
  let index = CommandIndex([run("docker ps", minutesAgo: 5)])
  #expect(GhostSuggester.suggest(index, context("dock", names: ["docker", "dockutil"]))?.text == "er ps")
  // Nothing in history: the shortest known name.
  #expect(GhostSuggester.suggest(CommandIndex(), context("kub", names: ["kubectl", "kubectx-extra"]))?.text == "ectl")
  #expect(GhostSuggester.suggest(CommandIndex(), context("k", names: ["kubectl"])) == nil) // too short to guess
}

@Test func aPathCompletesWhenOnlyOneEntryFits() {
  let list = { (folder: String) -> [String]? in folder == "src" ? ["app/", "apple.txt", "lib/"] : nil }
  #expect(GhostSuggester.suggest(CommandIndex(), context("cat src/l", list: list))?.text == "ib/")
  // Two fit: their shared start.
  #expect(GhostSuggester.suggest(CommandIndex(), context("cat src/a", list: list))?.text == "pp")
  #expect(GhostSuggester.suggest(CommandIndex(), context("cat src/x", list: list)) == nil)
}

@Test func suggestionsNeverContradictTheLine() {
  let index = CommandIndex([run("git status", minutesAgo: 1), run("git stash pop", minutesAgo: 2),
                            run("grep -r x .", minutesAgo: 3), run("go test ./...", minutesAgo: 4)])
  for line in ["g", "gi", "git", "git ", "git s", "git st", "git sta", "git stas", "gr", "go t", "x", "git z"] {
    if let suggestion = GhostSuggester.suggest(index, context(line, names: ["git", "go", "grep"])) {
      #expect(!suggestion.text.isEmpty)
      #expect(index.entries.contains { $0.command == line + suggestion.text } || !(line + suggestion.text).contains(" "),
              "\(line) → \(suggestion.text)")
    }
  }
}

@Test func nextCommandEmptiesChangingQuotes() {
  #expect(GhostSuggester.template("git commit -m \"fix the build\"") == ("git commit -m \"\"", 15))
  #expect(GhostSuggester.template("echo 'a b' \"c\"") == ("echo '' \"\"", 6))
  #expect(GhostSuggester.template("git push") == ("git push", nil))
  #expect(GhostSuggester.template("echo \"say \\\"hi\\\"\" done") == ("echo \"\" done", 6))
}

@Test func nextCommandNeedsAHabit() {
  var records: [CommandRecord] = []
  for i in 0..<3 {
    records.append(run("git add -A", minutesAgo: Double(60 - i * 10)))
    records.append(run("git commit -m \"wip \(i)\"", minutesAgo: Double(59 - i * 10)))
  }
  let index = CommandIndex(records.sorted { $0.start < $1.start })
  let next = GhostSuggester.next(index, previous: "git add -A", folder: "/proj")
  #expect(next == GhostSuggestion(text: "git commit -m \"\"", cursor: 15))
  // Seen twice is not a habit.
  let twice = CommandIndex(Array(records.sorted { $0.start < $1.start }.prefix(4)))
  #expect(GhostSuggester.next(twice, previous: "git add -A", folder: "/proj") == nil)
  // Nothing follows an unknown command.
  #expect(GhostSuggester.next(index, previous: "make", folder: "/proj") == nil)
}

@Test func runsMoreThanAnHourApartAreNotAHabit() {
  var records: [CommandRecord] = []
  for i in 0..<4 {
    records.append(run("ls", minutesAgo: Double(1000 - i * 200)))
    records.append(run("pwd", minutesAgo: Double(1000 - i * 200 - 90))) // 90 minutes later
  }
  let index = CommandIndex(records.sorted { $0.start < $1.start })
  #expect(GhostSuggester.next(index, previous: "ls", folder: "/proj") == nil)
}

@Test func forgettingACommandForgetsItsHabits() {
  var records: [CommandRecord] = []
  for i in 0..<3 {
    records.append(run("git add -A", minutesAgo: Double(60 - i * 10)))
    records.append(run("git commit -m \"wip \(i)\"", minutesAgo: Double(59 - i * 10)))
  }
  var index = CommandIndex(records.sorted { $0.start < $1.start })
  #expect(GhostSuggester.next(index, previous: "git add -A", folder: "/proj") != nil)
  // One commit forgotten: the others still share the template, so the habit stays.
  index.remove(command: "git commit -m \"wip 0\"")
  #expect(GhostSuggester.next(index, previous: "git add -A", folder: "/proj") != nil)
  for command in index.entries.map(\.command) where command.hasPrefix("git commit") { index.remove(command: command) }
  #expect(GhostSuggester.next(index, previous: "git add -A", folder: "/proj") == nil)
}

@Test func aCommandThatWouldntRunIsNeverSuggested() {
  let index = CommandIndex([run("pnpf dev", minutesAgo: 1, exit: 127), run("pnpm dev:web", minutesAgo: 60)])
  var ghost = context("pn")
  ghost.runs = { LineMarks.runs($0) { $0 == "pnpm" } }
  #expect(GhostSuggester.suggest(index, ghost)?.text == "pm dev:web")
}

@Test func theSameRepositoryBeatsAnotherOne() {
  func at(_ command: String, _ minutes: Double, _ folder: String, root: String) -> CommandRecord {
    CommandRecord(command: command, folder: folder, start: now.addingTimeInterval(-minutes * 60), duration: 1,
                  exitCode: 0, tab: nil, gitRoot: root, branch: nil, imported: false)
  }
  let index = CommandIndex([at("make api", 10, "/other/x", root: "/other"), at("make web", 60, "/proj/web", root: "/proj")])
  var here = context("make ", folder: "/proj/api")
  here.gitRoot = "/proj"
  #expect(GhostSuggester.suggest(index, here)?.text == "web")
}

@Test func aFailureHereCountsAgainstTheCommandHere() {
  let index = CommandIndex([run("npm test", minutesAgo: 5, folder: "/proj", exit: 1),
                            run("npm test", minutesAgo: 60, folder: "/other", exit: 0),
                            run("npm run lint", minutesAgo: 90, folder: "/proj", exit: 0)])
  #expect(GhostSuggester.suggest(index, context("npm "))?.text == "run lint")
}

@Test func foldersAboveAndBelowCountAsNearby() {
  #expect(GhostSuggester.isNearby("/proj", "/proj/web"))
  #expect(!GhostSuggester.isNearby("/proj", "/project"))
}
