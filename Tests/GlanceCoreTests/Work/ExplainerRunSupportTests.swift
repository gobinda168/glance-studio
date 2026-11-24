import Darwin
import Foundation
import Testing
@testable import GlanceCore

// Make explainer's Core pieces (Task 11): the state kept on the record, the diff's base, a command line run through the
// login shell with a Cancel that reaches its children, and the rules Claude is started with.

// MARK: ExplainerState

@Test func aRecordWithoutAnExplainerStillDecodes() throws {
  let json = #"{"session":"s1","updated":"2026-11-01T10:00:00Z"}"#
  let record = try WorkRecord.decoder.decode(WorkRecord.self, from: Data(json.utf8))
  #expect(record.explainer == nil)
}

@Test func anExplainerStateRoundTripsThroughTheRecord() throws {
  var record = WorkRecord(session: "s1", updated: Date(timeIntervalSince1970: 1_000))
  let started = Date(timeIntervalSince1970: 900)
  record.explainer = ExplainerState(id: "run-1", phase: .running, step: .rendering, progress: 0.4, log: nil, startedAt: started)
  let data = try WorkRecord.encoder.encode(record)
  let back = try WorkRecord.decoder.decode(WorkRecord.self, from: data)
  #expect(back.explainer == record.explainer)
  #expect(back.explainer?.step == .rendering && back.explainer?.progress == 0.4)
}

@Test func anExplainerStateInAnUnknownShapeIsDroppedNotFatal() throws {
  let json = #"{"session":"s1","updated":"2026-11-01T10:00:00Z","explainer":{"id":"x","phase":"exploded"}}"#
  let record = try WorkRecord.decoder.decode(WorkRecord.self, from: Data(json.utf8))
  #expect(record.explainer == nil)
}

@Test func aRunningStateNobodyRunsShowsAsFailed() {
  let state = ExplainerState(id: "r", phase: .running, step: .narrating, progress: 0.2, log: nil, startedAt: Date())
  #expect(state.shown(active: true) == .running)
  #expect(state.shown(active: false) == .failed)
  var failed = state
  failed.phase = .failed
  #expect(failed.shown(active: true) == .failed && failed.shown(active: false) == .failed)
  var done = state
  done.phase = .done
  #expect(done.shown(active: false) == .done)
}

// MARK: RepoBase

private func git(_ root: String, _ arguments: String...) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = ["-C", root, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + arguments
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
}

/// A folder removed after the test; `repo(...)` makes a repository in it with one commit on `main`.
private final class Temp {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("repobase-\(UUID().uuidString)").path
  init() { try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true) }
  deinit { try? FileManager.default.removeItem(atPath: root) }
  func repo(_ name: String) throws -> String {
    let path = root + "/" + name
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try git(path, "init", "-q", "-b", "main")
    try git(path, "commit", "-q", "--allow-empty", "-m", "first")
    return path
  }
}

@Test func theBaseIsTheRemoteBranchWhenThereIsOne() throws {
  let t = Temp()
  let upstream = try t.repo("upstream")
  try git(t.root, "clone", "-q", upstream, t.root + "/clone")
  try git(t.root + "/clone", "switch", "-q", "-c", "feat/x")
  #expect(RepoBase.find(cwd: t.root + "/clone", prBase: "main") == "origin/main")
}

@Test func theBaseFallsBackToTheLocalBranch() throws {
  let t = Temp()
  let repo = try t.repo("solo")
  try git(repo, "branch", "develop")
  try git(repo, "switch", "-q", "-c", "feat/x")
  #expect(RepoBase.find(cwd: repo, prBase: "develop") == "develop")
}

@Test func withoutAPRBaseTheRemotesDefaultBranchIsTheBase() throws {
  let t = Temp()
  let upstream = try t.repo("upstream")
  try git(t.root, "clone", "-q", upstream, t.root + "/clone")
  try git(t.root + "/clone", "switch", "-q", "-c", "feat/x")
  #expect(RepoBase.find(cwd: t.root + "/clone", prBase: nil) == "origin/main")
  #expect(RepoBase.find(cwd: t.root + "/clone", prBase: "") == "origin/main")
  #expect(RepoBase.find(cwd: t.root + "/clone", prBase: "gone") == "origin/main")
}

@Test func aRepositoryWithOnlyTheCurrentBranchHasNoBase() throws {
  let t = Temp()
  let repo = try t.repo("only")
  #expect(RepoBase.find(cwd: repo, prBase: nil) == nil)
  #expect(RepoBase.find(cwd: repo, prBase: "") == nil)
  // The PR's base doesn't exist here and nothing else does: never the current branch.
  #expect(RepoBase.find(cwd: repo, prBase: "release") == nil)
  try git(repo, "switch", "-q", "-c", "feat/x")
  #expect(RepoBase.find(cwd: repo, prBase: nil) == nil)
}

@Test func aBaseThatLooksLikeAnOptionIsRefused() throws {
  let t = Temp()
  let repo = try t.repo("opt")
  #expect(RepoBase.find(cwd: repo, prBase: "--help") == nil)
  #expect(RepoBase.find(cwd: repo, prBase: "-main") == nil)
  #expect(RepoBase.find(cwd: t.root + "/not-a-repo", prBase: "main") == nil)
}

@Test func theDiffIsTheWorkSinceTheBaseAndIgnoresExternalDiffTools() throws {
  let t = Temp()
  let repo = try t.repo("diff")
  try git(repo, "switch", "-q", "-c", "feat/x")
  try "hello\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
  try git(repo, "add", "a.txt")
  try git(repo, "commit", "-q", "-m", "add a")
  // A configured external diff would replace git's output (here it prints nothing and fails).
  try git(repo, "config", "diff.external", "/usr/bin/false")
  let diff = try #require(RepoBase.diff(cwd: repo, base: "main"))
  #expect(diff.contains("+hello") && diff.contains("a.txt"))
  #expect(RepoBase.diff(cwd: repo, base: "no-such-ref") == nil)
  #expect(RepoBase.diff(cwd: repo, base: "--stat") == nil)
}

// MARK: A command line through the login shell

private func scratchFolder() -> String {
  let path = NSTemporaryDirectory() + "explainer-cmd-" + UUID().uuidString
  try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

@Test func aCommandLineRunsThroughTheLoginShellWithItsEnvironment() throws {
  let folder = scratchFolder()
  defer { try? FileManager.default.removeItem(atPath: folder) }
  let real = realpath(folder, nil).map { String(cString: $0) } ?? folder
  let outcome = ProofScript.runCommand(
    #"printf '%s|%s|%s|%s|%s' "$GLANCE_EXPLAINER_OUT" "$GLANCE_RECORD" "$GLANCE_BASE" "$GLANCE_BRANCH" "$(pwd -P)" && echo " ok" | cat"#,
    root: folder,
    environment: ["GLANCE_EXPLAINER_OUT": "/out dir", "GLANCE_RECORD": "/w/record.json", "GLANCE_BASE": "origin/main",
                  "GLANCE_BRANCH": "feat/x"])
  guard case .output(let text) = outcome else { Issue.record("\(outcome)"); return }
  #expect(text.hasSuffix("/out dir|/w/record.json|origin/main|feat/x|\(real) ok"), "\(text)")
}

@Test func aCommandLineWithArgumentsAndOperatorsIsNotTreatedAsOneFilename() {
  let folder = scratchFolder()
  defer { try? FileManager.default.removeItem(atPath: folder) }
  guard case .output(let text) = ProofScript.runCommand("echo one two && echo three", root: folder) else {
    Issue.record("failed"); return
  }
  #expect(text.hasSuffix("one two\nthree"), "\(text)")
  guard case .failed(let message) = ProofScript.runCommand("echo nope; exit 3", root: folder) else {
    Issue.record("should fail"); return
  }
  #expect(message.contains("exited with 3") && message.contains("nope"), "\(message)")
}

@Test func theCommandsOwnTimeoutStopsItsGroup() {
  let folder = scratchFolder()
  defer { try? FileManager.default.removeItem(atPath: folder) }
  let started = Date()
  guard case .failed(let message) = ProofScript.runCommand("sleep 30", root: folder, timeout: 1) else {
    Issue.record("should time out"); return
  }
  #expect(message.contains("took longer than 1 s"), "\(message)")
  #expect(Date().timeIntervalSince(started) < 10)
}

@Test func cancelStopsTheCommandAndItsChildren() throws {
  let folder = scratchFolder()
  defer { try? FileManager.default.removeItem(atPath: folder) }
  let pidFile = folder + "/child.pid"
  let stop = ProofScript.Stop()
  let done = DispatchSemaphore(value: 0)
  nonisolated(unsafe) var outcome: ProofScript.Outcome?
  let started = Date()
  DispatchQueue.global().async {
    // A grandchild in the same group, which a plain kill of the shell would leave running.
    outcome = ProofScript.runCommand("(sleep 60 & echo $! > '\(pidFile)'; wait)", root: folder, timeout: 120, stop: stop)
    done.signal()
  }
  var child: pid_t = 0
  for _ in 0..<200 where child == 0 {
    if let text = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
      child = pid
    } else {
      usleep(25_000)
    }
  }
  try #require(child > 0, "the command never started")
  #expect(kill(child, 0) == 0)
  stop.cancel()
  #expect(done.wait(timeout: .now() + 10) == .success, "the run did not end after Cancel")
  #expect(Date().timeIntervalSince(started) < 20)
  guard case .failed(let message)? = outcome else { Issue.record("\(String(describing: outcome))"); return }
  #expect(message.contains("stopped"), "\(message)")
  // The grandchild goes with the group.
  var alive = true
  for _ in 0..<100 where alive {
    var status: Int32 = 0
    _ = waitpid(child, &status, WNOHANG)
    alive = kill(child, 0) == 0
    if alive { usleep(50_000) }
  }
  #expect(!alive, "the child of the command is still running")
}

@Test func aStopThatIsAlreadySetNeverStartsTheCommand() {
  let folder = scratchFolder()
  defer { try? FileManager.default.removeItem(atPath: folder) }
  let stop = ProofScript.Stop()
  stop.cancel()
  let marker = folder + "/ran"
  guard case .failed = ProofScript.runCommand("touch '\(marker)'", root: folder, stop: stop) else {
    Issue.record("should fail"); return
  }
  #expect(!FileManager.default.fileExists(atPath: marker))
}

// MARK: What Claude may read

@Test func claudeReadsOnlyTheSessionsFolderAndTheSkillsNotAnyFile() throws {
  let rules = try #require(ExplainerPrompt.arguments(folder: "/w/media/e-1", readable: ["/Users/me/My App"],
                                                     files: ["/c/skills/glance-explainer/tokens.css"]))
  #expect(rules.last == "Read(//Users/me/My App/**),Read(//c/skills/glance-explainer/tokens.css),Skill,Edit(//w/media/e-1/**)")
  #expect(!rules.last!.split(separator: ",").contains("Read"))
  #expect(rules[rules.firstIndex(of: "--tools")! + 1] == "Read,Skill,Write")
}

@Test func aReadFolderThatCannotBeARuleIsLeftOutNotFatal() throws {
  let rules = try #require(ExplainerPrompt.arguments(folder: "/w/e", readable: ["/Users/me/App (2)", "relative", "/", "/ok"]))
  #expect(rules.last == "Read(//ok/**),Skill,Edit(//w/e/**)")
  // A file that can't be a rule is left out too.
  let files = try #require(ExplainerPrompt.arguments(folder: "/w/e", readable: [], files: ["/a/b(1).css", "rel.css", "/a/ok.css"]))
  #expect(files.last == "Read(//a/ok.css),Skill,Edit(//w/e/**)")
  let none = try #require(ExplainerPrompt.arguments(folder: "/w/e", readable: []))
  #expect(none.last == "Skill,Edit(//w/e/**)")
}

// MARK: The skills

private let modFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mods/glance-proof/skills")

@Test func theExplainerSkillIsInertOutsideMakeExplainerAndTeachesTheContract() throws {
  let text = try String(contentsOf: modFolder.appendingPathComponent("glance-explainer/SKILL.md"), encoding: .utf8)
  #expect(text.hasPrefix("---\nname: glance-explainer\ndescription: Only for Glance Studio's Make explainer run"))
  let description = try #require(text.components(separatedBy: "\n").first { $0.hasPrefix("description: ") })
  #expect(description.contains("In any other conversation, ignore this skill."))
  for needle in ["scenes.html", "narration.json", "glance:scene", "__seek", "150 words a minute", "tokens.css", "backdrop-filter",
                 "requestAnimationFrame", "Web Animations API", "No network", "data-scene"] {
    #expect(text.contains(needle), "the skill never says \(needle)")
  }
  // Its narration sample is the format the renderer reads.
  let lines = text.components(separatedBy: "\n")
  let start = try #require(lines.firstIndex(of: "    {"))
  let end = try #require(lines[start...].firstIndex(of: "    }"))
  let json = lines[start...end].map { String($0.dropFirst(4)) }.joined(separator: "\n")
  guard case .success(let script) = ExplainerScript.parse(Data(json.utf8)) else { Issue.record("the sample isn't narration.json"); return }
  #expect(script.scenes.count == 1 && script.title.isEmpty == false)
  // The prompt names the skill the way the skill is named.
  #expect(ExplainerPrompt.prompt(record: "{}", diff: nil, folder: "/w/e").contains("glance-explainer skill"))
}

@Test func theSetupSkillExplainsExplainerCommandAsACommandLineWithItsVariables() throws {
  let text = try String(contentsOf: modFolder.appendingPathComponent("glance-proof-setup/SKILL.md"), encoding: .utf8)
  for needle in ["explainer.command", "zsh -lc", "GLANCE_EXPLAINER_OUT", "GLANCE_RECORD", "GLANCE_BASE", "GLANCE_BRANCH",
                 "explainer.mp4", "30 minute"] {
    #expect(text.contains(needle), "glance-proof-setup never says \(needle)")
  }
}

// MARK: Is the skill loaded

private let loadedDirs = "/Users/me/plugins/other:/Users/me/Library/Caches/Glance Studio/mods/glance-proof:/x"

@Test func theSkillIsLoadedWhenTheModFolderIsOnThePluginPath() {
  #expect(ExplainerSkill.problem(pluginDirs: loadedDirs, modOn: true) == nil)
  // Switched off since launch: the skill is really there, so the run goes ahead.
  #expect(ExplainerSkill.problem(pluginDirs: loadedDirs, modOn: false) == nil)
  #expect(ExplainerSkill.problem(pluginDirs: "/a/glance-proof/:/b", modOn: true) == nil)
}

@Test func aModThatWasNotLoadedAtLaunchNeedsARestart() {
  let restart = "Glance needs a restart to load the Glance Proof mod. Restart Studio and try again."
  #expect(ExplainerSkill.problem(pluginDirs: nil, modOn: true) == restart)
  #expect(ExplainerSkill.problem(pluginDirs: "", modOn: true) == restart)
  #expect(ExplainerSkill.problem(pluginDirs: "/a/glance-proof-setup:/b/not-glance-proof", modOn: true) == restart)
}

@Test func aModThatIsOffAndNotLoadedSaysToTurnItOnThenToRestart() throws {
  let message = try #require(ExplainerSkill.problem(pluginDirs: "/a:/b", modOn: false))
  #expect(message.contains("Turn it on under Mods"))
  #expect(message.hasSuffix("Glance needs a restart to load the Glance Proof mod. Restart Studio and try again."))
  #expect(message.range(of: "Turn it on under Mods")!.lowerBound < message.range(of: "needs a restart")!.lowerBound)
}
