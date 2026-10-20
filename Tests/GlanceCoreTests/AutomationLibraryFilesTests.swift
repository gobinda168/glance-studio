import Foundation
import Testing
@testable import GlanceCore

@Test func runsLiveBesideTheirLogsAndOnlyPackageEditsReload() {
  let start = Date(timeIntervalSince1970: 1_791_536_400.125)
  let run = AutomationLibraryLayout.runID(start: start)
  #expect(run == "2026-10-09T09-00-00.125Z")
  #expect(AutomationLibraryLayout.runLog(root: "/L", automation: "a", run: run) == "/L/.runs/a/\(run).jsonl")
  #expect(AutomationLibraryLayout.runDirectory(root: "/L", automation: "a", run: run) == "/L/.runs/a/\(run)")
  #expect(AutomationLibraryLayout.package(ofChange: "/L/fix-red-ci/automation.json", root: "/L") == "fix-red-ci")
  #expect(AutomationLibraryLayout.package(ofChange: "/L/fix-red-ci", root: "/L") == "fix-red-ci")
  #expect(AutomationLibraryLayout.package(ofChange: "/L/.runs/a/x.jsonl", root: "/L") == nil)
  #expect(AutomationLibraryLayout.package(ofChange: "/L/state/a.json", root: "/L") == nil)
  #expect(AutomationLibraryLayout.package(ofChange: "/L/approvals.json", root: "/L") == nil)
  #expect(AutomationLibraryLayout.package(ofChange: "/L/.git/index", root: "/L") == nil)
  #expect(AutomationLibraryLayout.package(ofChange: "/Other/a/b", root: "/L") == nil)
  #expect(AutomationLibraryLayout.gitignore.split(separator: "\n").contains(".runs/"))
}

@Test func gitCommandsNameTheirPathsAndRunWithoutHooksOrSigning() {
  #expect(AutomationGit.stage("fix-red-ci/") == ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "add",
                                                 "-A", "--", "fix-red-ci/"])
  #expect(AutomationGit.commit("fix-red-ci/", message: "m").dropFirst(4)
    == ["commit", "-q", "--no-verify", "-m", "m", "--", "fix-red-ci/"])
  #expect(AutomationGit.history("a").suffix(4) == ["log", "--format=%H%x1f%at%x1f%s", "--", "a/"])
  #expect(AutomationGit.isNothingToCommit("On branch main\nnothing to commit, working tree clean\n"))
  #expect(!AutomationGit.isNothingToCommit("fatal: not a git repository"))
}

@Test func historyLinesParseWithTheirVersions() {
  let output = "abc1234def\u{1f}1791536400\u{1f}Restore Fix red CI (fix-red-ci) v2 from 0011223 as v5\n"
    + "0011223aaa\u{1f}1791450000\u{1f}Save Fix red CI (fix-red-ci) v2\n"
    + "ffff\u{1f}1791440000\u{1f}Delete Fix red CI (fix-red-ci)\n"
    + "broken line\n"
  let entries = AutomationGit.parseHistory(output)
  #expect(entries.map(\.version) == [5, 2, nil])
  #expect(entries[0].shortCommit == "abc1234")
  #expect(entries[1].date == Date(timeIntervalSince1970: 1_791_450_000))
  #expect(AutomationGit.saveMessage(id: "a", name: "A", version: 3) == "Save A (a) v3")
  #expect(AutomationGit.restoreMessage(id: "a", name: "A", version: 6, from: entries[1])
    == "Restore A (a) v2 from 0011223 as v6")
  #expect(AutomationGit.deleteMessage(id: "a", name: "A") == "Delete A (a)")
}

@Test func theVersionChangesInPlaceAndNothingElseMoves() {
  let text = AutomationSample.json
  let bumped = AutomationVersionText.setting(4, in: text)
  #expect(bumped == text.replacingOccurrences(of: "\"version\": 3,", with: "\"version\": 4,"))
  #expect(AutomationManifest.parse(Data(bumped.utf8)).manifest?.inputs.map(\.name) == ["repo", "pr", "dry", "repo_path"])
  // A "version" key deeper in, or a string that says version, is left alone.
  let nested = #"{"inputs": {"version": {"type": "number"}}, "name": "version", "version":7}"#
  #expect(AutomationVersionText.setting(8, in: nested)
    == #"{"inputs": {"version": {"type": "number"}}, "name": "version", "version":8}"#)
  #expect(AutomationVersionText.setting(2, in: "{\"id\": \"a\"}") == "{\n  \"version\": 2,\"id\": \"a\"}")
  #expect(AutomationVersionText.setting(2, in: "{ }") == "{\n  \"version\": 2 }")
  #expect(AutomationVersionText.setting(2, in: "[1]") == "[1]")
  #expect(AutomationVersionText.next(onDisk: 3, given: 3) == 4)
  #expect(AutomationVersionText.next(onDisk: 3, given: 9) == 9)
  #expect(AutomationVersionText.next(onDisk: nil, given: 1) == 1)
  #expect(AutomationVersionText.next(onDisk: nil, given: 0) == 1)
}

private let hello = """
{
  "id": "hello",
  "version": 1,
  "name": "Hello",
  "inputs": { "who": { "type": "string", "default": "world" } },
  "steps": [ { "id": "greet", "run": "echo hello {{inputs.who}}" } ]
}
"""

@Test func aSaveMergesBumpsAndValidatesBeforeWriting() {
  let first = AutomationSave.plan(id: "hello", existing: [:], files: ["automation.json": hello, "README.md": "# Hi"],
                                  delete: [], library: [:], directory: "/L/hello")
  guard case .success(let plan) = first else { Issue.record("\(first)"); return }
  #expect(plan.version == 1)
  #expect(plan.writes.keys.sorted() == ["README.md", "automation.json"])
  let existing = plan.writes
  let second = AutomationSave.plan(id: "hello", existing: existing, files: ["README.md": "# Hello"],
                                   delete: [], library: [:], directory: "/L/hello")
  guard case .success(let next) = second else { Issue.record("\(second)"); return }
  #expect(next.version == 2)
  #expect(next.writes["automation.json"]?.contains("\"version\": 2,") == true)
  #expect(next.manifest.version == 2)
}

@Test func aBadSaveWritesNothingAndSaysWhy() {
  let broken = hello.replacingOccurrences(of: "{{inputs.who}}", with: "{{inputs.whom}}")
  let result = AutomationSave.plan(id: "hello", existing: [:], files: ["automation.json": broken], delete: [],
                                   library: [:], directory: "/L/hello")
  #expect(result == .failure(.problems([
    AutomationProblem("steps[0].run", "`{{inputs.whom}}`: there's no input `whom`"),
  ])))
  let wrongFolder = AutomationSave.plan(id: "other", existing: [:], files: ["automation.json": hello], delete: [],
                                        library: [:], directory: "/L/other")
  #expect(wrongFolder == .failure(.problems([AutomationProblem("id", "`hello` must match its folder `other`")])))
  let noManifest = AutomationSave.plan(id: "hello", existing: [:], files: ["README.md": "x"], delete: [],
                                       library: [:], directory: "/L/hello")
  #expect(noManifest == .failure(.problems([AutomationProblem("automation.json", "is missing")])))
}

// Review Focus: Claude's save can't write outside its package (approvals.json, another automation, .git).
@Test func savePathsStayInsideThePackage() {
  for path in ["../approvals.json", "/etc/passwd", "~/x", ".git/config", "ui/.hidden", "a//b", "", "steps/../../x"] {
    #expect(AutomationSave.pathProblem(path) != nil, "\(path)")
  }
  for path in ["automation.json", "steps/a.sh", "ui/index.html", "prompts/fix.md"] {
    #expect(AutomationSave.pathProblem(path) == nil, "\(path)")
  }
  let result = AutomationSave.plan(id: "hello", existing: ["automation.json": hello], files: ["../x": "y"],
                                   delete: ["automation.json"], library: [:], directory: "/L/hello")
  #expect(result == .failure(.problems([
    AutomationProblem("../x", "must be a file inside the package (no `..`, no leading `/`, no hidden files)"),
    AutomationProblem("automation.json", "can't be deleted; delete the automation"),
  ])))
  #expect(AutomationSave.plan(id: "Bad_ID", existing: [:], files: ["automation.json": hello], delete: [], library: [:],
                              directory: "/L/x") == .failure(.problems([
    AutomationProblem("id", "`Bad_ID` must be 1–48 lowercase letters, digits or dashes"),
  ])))
}

@Test func theLibraryRootMustBeTheRepositoryNotAParentsAndCheckoutTakesOnlyHex() {
  #expect(AutomationGit.isRepository().suffix(2) == ["rev-parse", "--show-toplevel"])
  #expect(AutomationGit.isLibraryRoot("/Users/me/Library/Glance/automations\n", root: "/Users/me/Library/Glance/automations/"))
  #expect(AutomationGit.isLibraryRoot("/private/var/x/lib\n", root: "/var/x/lib"))
  #expect(!AutomationGit.isLibraryRoot("/Users/me\n", root: "/Users/me/Library/Glance/automations"))
  #expect(!AutomationGit.isLibraryRoot("", root: "/L"))
  #expect(!AutomationGit.isLibraryRoot("fatal: not a git repository\n", root: "/L"))
  #expect(AutomationGit.checkout("a", commit: "0011223")?.suffix(4) == ["checkout", "0011223", "--", "a/"])
  for bad in ["-f", "--orphan=x", "HEAD", "001122", "zzzzzzz", "", String(repeating: "a", count: 41)] {
    #expect(AutomationGit.checkout("a", commit: bad) == nil, "\(bad)")
  }
}

@Test func reservedIDsCaseCollisionsAndWrittenAndDeletedFiles() {
  let state = AutomationSave.plan(id: "state", existing: [:], files: ["automation.json": hello], delete: [],
                                  library: [:], directory: "/L/state")
  guard case .failure(.problems(let reserved)) = state else { Issue.record("\(state)"); return }
  #expect(reserved.first == AutomationProblem("id", "`state` is reserved by the library; pick another id"))
  let clash = AutomationSave.plan(id: "hello", existing: [:], files: ["automation.json": hello, "AUTOMATION.JSON": "{}"],
                                  delete: [], library: [:], directory: "/L/hello")
  #expect(clash == .failure(.problems([
    AutomationProblem("AUTOMATION.JSON", "differs only in letter case from another file in the package"),
    AutomationProblem("automation.json", "differs only in letter case from another file in the package"),
  ])))
  let againstDisk = AutomationSave.plan(id: "hello", existing: ["automation.json": hello, "README.md": "a"],
                                        files: ["readme.md": "b"], delete: [], library: [:], directory: "/L/hello")
  #expect(againstDisk == .failure(.problems([
    AutomationProblem("readme.md", "differs only in letter case from another file in the package"),
  ])))
  // Deleting the old spelling while writing the new one is a rename, not a clash.
  let rename = AutomationSave.plan(id: "hello", existing: ["automation.json": hello, "README.md": "a"],
                                   files: ["readme.md": "b"], delete: ["README.md"], library: [:],
                                   directory: "/L/hello")
  guard case .success(let renamed) = rename else { Issue.record("\(rename)"); return }
  #expect(renamed.deletes == ["README.md"])
  // Written and deleted in one save: it is written, not deleted.
  let both = AutomationSave.plan(id: "hello", existing: ["automation.json": hello, "notes.md": "old"],
                                 files: ["notes.md": "new"], delete: ["notes.md", "automation.json"], library: [:],
                                 directory: "/L/hello")
  guard case .failure(.problems(let bothProblems)) = both else { Issue.record("\(both)"); return }
  #expect(bothProblems == [AutomationProblem("automation.json", "can't be deleted; delete the automation")])
  let written = AutomationSave.plan(id: "hello", existing: ["automation.json": hello, "notes.md": "old"],
                                    files: ["notes.md": "new"], delete: ["notes.md"], library: [:],
                                    directory: "/L/hello")
  guard case .success(let plan) = written else { Issue.record("\(written)"); return }
  #expect(plan.deletes.isEmpty)
  #expect(plan.writes["notes.md"] == "new")
}
