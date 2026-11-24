import Darwin
import Foundation
import Testing
@testable import GlanceCore

/// The hook payloads here have the shapes Claude Code sends: a successful Bash call is a PostToolUse whose
/// `tool_response` has stdout, stderr and flags but no exit code; one that exited non-zero is a PostToolUseFailure whose
/// `error` starts "Exit code N".
@Suite struct WorkObserverTests {
  struct Fixture {
    let store: WorkStore
    let repo: URL
  }

  func fixture(setup: Bool = true) throws -> Fixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("obs-\(UUID().uuidString)")
    let repo = base.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "ref: refs/heads/feat/x\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    if setup {
      try FileManager.default.createDirectory(at: repo.appendingPathComponent(".glance"), withIntermediateDirectories: true)
      try #"""
      {"version":1,"environments":[{"name":"Local","url":"http://localhost:3000","match":["localhost:*"]}],
       "checks":[{"name":"Unit","match":"^(npm|pnpm) (run )?test\\b","env":"Local"}]}
      """#.write(to: repo.appendingPathComponent(".glance/proof.json"), atomically: true, encoding: .utf8)
    }
    return Fixture(store: WorkStore(folder: base.appendingPathComponent("work")), repo: repo)
  }

  func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

  /// A Bash PostToolUse as Claude Code sends it (no exit code in `tool_response`).
  func bashDone(_ f: Fixture, _ command: String, stdout: String = "", stderr: String = "", interrupted: Bool = false,
                id: String = "toolu_01A", extra: [String: Any] = [:]) -> Data {
    var response: [String: Any] = ["stdout": stdout, "stderr": stderr, "interrupted": interrupted, "isImage": false,
                                   "noOutputExpected": false]
    response.merge(extra) { $1 }
    return data(["session_id": "s1", "transcript_path": "/x/s1.jsonl", "cwd": f.repo.path, "permission_mode": "default",
                 "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": id,
                 "tool_input": ["command": command, "description": "Run the tests"], "tool_response": response])
  }

  /// A Bash PostToolUseFailure.
  func bashFailed(_ f: Fixture, _ command: String, error: String, id: String = "toolu_01B", isInterrupt: Bool = false) -> Data {
    data(["session_id": "s1", "transcript_path": "/x/s1.jsonl", "cwd": f.repo.path, "permission_mode": "default",
          "hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "tool_use_id": id,
          "tool_input": ["command": command], "error": error, "is_interrupt": isInterrupt, "duration_ms": 4187])
  }

  let jestFailing = """
  FAIL src/cart.test.ts
    ● cart › totals › applies the discount

  Test Suites: 1 failed, 1 passed, 2 total
  Tests:       2 failed, 38 passed, 40 total
  Snapshots:   3 passed, 3 total
  Time:        4.187 s
  """
  let jestNoSummary = "    at Object.<anonymous> (src/cart.test.ts:31:5)\n\nPASS src/checkout.test.ts\n"

  func runs(_ f: Fixture) -> [ProofCheckRun] { f.store.record(session: "s1")?.checks ?? [] }

  // MARK: checks

  @Test func passingCheckIsRecorded() throws {
    let f = try fixture()
    WorkObserver(store: f.store).observe(bashDone(f, "npm test", stdout: "Tests: 40 passed, 40 total"))
    let run = try #require(runs(f).first)
    #expect(run.name == "Unit" && run.environment == "Local" && run.ok && run.result == .passed)
    #expect(run.exitCode == 0 && run.passed == 40 && run.source == .glance && run.id == "toolu_01A")
    #expect(f.store.record(session: "s1")?.branch == "feat/x")
  }

  @Test func theRecordRemembersTheRepositoryOfItsBranch() throws {
    let f = try fixture()
    WorkObserver(store: f.store).observe(bashDone(f, "npm test", stdout: "Tests: 40 passed, 40 total"))
    #expect(f.store.record(session: "s1")?.commonDir == GitCommonDir.normalize(f.repo.appendingPathComponent(".git").path))
  }

  @Test func aLinkedWorktreeRecordsTheMainRepositoryAndItsOwnBranch() throws {
    let f = try fixture()
    let base = f.repo.deletingLastPathComponent()
    let gitdir = f.repo.appendingPathComponent(".git/worktrees/wt")
    try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
    try "../..\n".write(to: gitdir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
    try "ref: refs/heads/feat/y\n".write(to: gitdir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    let wt = base.appendingPathComponent("wt")
    try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
    try "gitdir: \(gitdir.path)\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    let linked = Fixture(store: f.store, repo: wt)
    WorkObserver(store: f.store).observe(bashDone(linked, "npm test", stdout: "Tests: 4 passed, 4 total"))
    let record = try #require(f.store.record(session: "s1"))
    #expect(record.branch == "feat/y")
    #expect(record.commonDir == GitCommonDir.normalize(f.repo.appendingPathComponent(".git").path))
  }

  @Test func aToolResponseExitCodeWinsWhenClaudeCodeSendsOne() throws {
    let f = try fixture()
    WorkObserver(store: f.store).observe(bashDone(f, "npm test", stdout: "Tests: 40 passed, 40 total", extra: ["exit_code": 3]))
    let run = try #require(runs(f).first)
    #expect(run.exitCode == 3 && run.result == .failed && !run.ok)
  }

  @Test func failureEventRecordsExitCode() throws {
    let f = try fixture()
    WorkObserver(store: f.store).observe(bashFailed(f, "npm test", error: "Exit code 1\n" + jestFailing))
    let run = try #require(runs(f).first)
    #expect(run.exitCode == 1 && run.result == .failed && !run.ok)
    #expect(run.failed == 2 && run.passed == 38 && run.duration == 4.187)
  }

  @Test func failureWithoutAnExitCodeFallsBackOnTheSummary() throws {
    let f = try fixture()
    let observer = WorkObserver(store: f.store)
    // Interrupted: no "Exit code N", but the runner printed a summary before it was stopped.
    observer.observe(bashFailed(f, "npm test", error: jestFailing, id: "t1", isInterrupt: true))
    let run = try #require(runs(f).first)
    #expect(run.exitCode == nil && run.result == .failed)
    // Timed out with nothing to read: nothing is recorded.
    observer.observe(bashFailed(f, "npm test", error: "Command timed out after 120s", id: "t2"))
    #expect(runs(f).count == 1)
  }

  @Test func aPipedFailureWithExitZeroIsRecordedFailed() throws {
    let f = try fixture()
    // tail exits 0; the Jest summary says the tests failed.
    WorkObserver(store: f.store).observe(bashDone(f, "pnpm test 2>&1 | tail -20", stdout: jestFailing))
    let run = try #require(runs(f).first)
    #expect(run.result == .failed && !run.ok && run.failed == 2)
    #expect(run.exitCode == nil) // the pipeline's exit code is not the check's, so it is not stored
  }

  @Test func aPipedRunWithoutASummaryRecordsNothing() throws {
    let f = try fixture()
    WorkObserver(store: f.store).observe(bashDone(f, "pnpm test | tail", stdout: jestNoSummary))
    #expect(f.store.record(session: "s1") == nil)
  }

  @Test func aLaterAndCommandsFailureDoesNotFailTheCheck() throws {
    let f = try fixture()
    WorkObserver(store: f.store).observe(
      bashFailed(f, "pnpm test && pnpm build", error: "Exit code 1\nTests: 40 passed, 40 total\nbuild error"))
    let run = try #require(runs(f).first)
    #expect(run.result == .passed && run.ok && run.exitCode == nil)
  }

  @Test func anInterruptedCallWithoutASummaryRecordsNothing() throws {
    let f = try fixture()
    WorkObserver(store: f.store).observe(bashDone(f, "npm test", stdout: "running...", interrupted: true))
    #expect(f.store.record(session: "s1") == nil)
  }

  @Test func observeWithoutSetupRecordsNoCheck() throws {
    let f = try fixture(setup: false)
    WorkObserver(store: f.store).observe(bashDone(f, "npm test", stdout: "Tests: 40 passed"))
    #expect(f.store.record(session: "s1") == nil)
  }

  @Test func otherCommandsAndPayloadsAreIgnored() throws {
    let f = try fixture()
    let observer = WorkObserver(store: f.store)
    observer.observe(bashDone(f, "git status"))
    observer.observe(Data("not json".utf8))
    observer.observe(data(["session_id": "../evil", "cwd": f.repo.path, "hook_event_name": "PostToolUse", "tool_name": "Bash",
                           "tool_input": ["command": "npm test"], "tool_response": ["stdout": ""]]))
    observer.observe(data(["session_id": "s1", "cwd": f.repo.path, "hook_event_name": "PreToolUse", "tool_name": "Bash",
                           "tool_input": ["command": "npm test"]]))
    #expect(f.store.record(session: "s1") == nil)
    #expect(f.store.records().isEmpty)
  }

  @Test func sameToolUseIsRecordedOnce() throws {
    let f = try fixture()
    let p = bashDone(f, "npm test")
    WorkObserver(store: f.store).observe(p)
    WorkObserver(store: f.store).observe(p)
    #expect(runs(f).count == 1)
  }

  @Test func aBusyRecordStaysSilent() throws {
    let f = try fixture()
    let folder = f.store.sessionFolder("s1")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fd = open(folder.appendingPathComponent("record.lock").path, O_CREAT | O_RDWR, 0o644)
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    defer { flock(fd, LOCK_UN); close(fd) }
    let started = Date()
    WorkObserver(store: f.store).observe(bashDone(f, "npm test"))
    #expect(Date().timeIntervalSince(started) < 0.5) // the 50 ms lock budget, not a wait for the lock
    #expect(f.store.record(session: "s1") == nil)
  }

  @Test func largePayloadStaysInBudget() throws {
    let f = try fixture()
    let big = String(repeating: "line of output\n", count: 70_000) // ~1 MB
    let p = bashDone(f, "npm test", stdout: big)
    // The hook's budget is 30 ms; twice that tolerates a loaded test machine.
    let started = Date()
    WorkObserver(store: f.store).observe(p)
    #expect(Date().timeIntervalSince(started) < 0.030 * 2)
    #expect(runs(f).first?.outputTail.split(separator: "\n").count == 60)
  }

  // MARK: backgrounded checks

  @Test func aBackgroundedCheckIsNotRecorded() throws {
    let f = try fixture()
    // run_in_background: PostToolUse fires at once with an empty response and the id of the background task.
    let background = data(["session_id": "s1", "cwd": f.repo.path, "hook_event_name": "PostToolUse", "tool_name": "Bash",
                           "tool_use_id": "toolu_0BG",
                           "tool_input": ["command": "npm test", "run_in_background": true],
                           "tool_response": ["stdout": "", "stderr": "", "interrupted": false, "isImage": false,
                                             "noOutputExpected": false, "backgroundTaskId": "bkxyz12"]])
    WorkObserver(store: f.store).observe(background)
    #expect(f.store.record(session: "s1") == nil)
    // The task id alone is enough.
    WorkObserver(store: f.store).observe(bashDone(f, "npm test", extra: ["backgroundTaskId": "bkxyz12"]))
    #expect(f.store.record(session: "s1") == nil)
  }

  // MARK: browser screenshots

  /// A real `browser_take_screenshot` result: a text part whose path is relative to the browser's folder, the base64
  /// image, and a note about where Claude Code kept the image. There is no `Page URL` in it.
  func screenshotResponse(_ file: String) -> [[String: Any]] {
    [["type": "text", "text": """
      ### Result
      - [Screenshot of viewport](\(file))
      ### Ran Playwright code
      ```js
      // Screenshot viewport and save it as \(file)
      await page.screenshot({
        path: '\(file)',
        scale: 'css',
        type: 'png'
      });
      ```
      """],
     ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="]],
     ["type": "text", "text": "[Image: source: /Users/me/.claude/projects/-x/s1/tool-results/mcp-glance-browser-blob-1793588724729-10tob5.png]"]]
  }

  func screenshot(_ f: Fixture, response: Any, event: String = "PostToolUse", id: String = "toolu_09") -> Data {
    data(["session_id": "s1", "cwd": f.repo.path, "hook_event_name": event,
          "tool_name": WorkObserver.screenshotTool, "tool_use_id": id, "tool_input": ["type": "png"],
          "tool_response": response])
  }

  /// Any other glance-browser tool: its result carries the page's URL.
  func browserCall(_ f: Fixture, _ tool: String = "browser_navigate", url: String, id: String = "toolu_0N") -> Data {
    let text = """
      ### Ran Playwright code
      ```js
      await page.goto('\(url)');
      ```
      ### Page
      - Page URL: \(url)
      - Page Title: Sign in
      ### Snapshot
      - [Snapshot](../../../../var/folders/86/T/glance-browser/page-2026-11-02T03-05-10-617Z.yml)
      """
    return data(["session_id": "s1", "cwd": f.repo.path, "hook_event_name": "PostToolUse",
                 "tool_name": "mcp__glance-browser__" + tool, "tool_use_id": id, "tool_input": ["url": url],
                 "tool_response": [["type": "text", "text": text]]])
  }

  /// A temp folder standing in for $TMPDIR with a browser screenshot in glance-browser/.
  func browserTemp(_ name: String = "page-2026-11-02T03-05-24-713Z.png") throws -> URL {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tmpdir-\(UUID().uuidString)")
    let folder = tmp.appendingPathComponent("glance-browser")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appendingPathComponent(name))
    return tmp
  }

  @Test func screenshotFoundInTheBrowsersTempFolderFromItsRelativePath() throws {
    let f = try fixture(setup: false)
    let tmp = try browserTemp()
    // The browser's cwd isn't the hook's, so the ../ path resolves to nothing here: the temp folder is the fallback.
    let path = "../../../../var/folders/86/T/glance-browser/page-2026-11-02T03-05-24-713Z.png"
    WorkObserver(store: f.store, tmpDir: tmp.path).observe(screenshot(f, response: screenshotResponse(path)))
    let capture = try #require(f.store.record(session: "s1")?.captures.first)
    #expect(capture.kind == .screenshot && capture.purpose == .test && capture.source == .glance)
    #expect(capture.url == nil && capture.environment == nil && capture.caption == "Screenshot")
    #expect(capture.file == "toolu_09.png")
    #expect(FileManager.default.fileExists(atPath: f.store.mediaFolder(session: "s1").appendingPathComponent(capture.file).path))
  }

  @Test func aCaptureStoresTheSHA256OfItsFile() throws {
    let f = try fixture(setup: false)
    try Data("abc".utf8).write(to: f.repo.appendingPathComponent("p.png"))
    WorkObserver(store: f.store).observe(screenshot(f, response: screenshotResponse("p.png")))
    let capture = try #require(f.store.record(session: "s1")?.captures.first)
    #expect(capture.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    // It survives a round trip through the record file.
    #expect(f.store.record(session: "s1")?.captures.first?.sha256 == capture.sha256)
  }

  @Test func aRecordWrittenBeforeHashesExistedStillDecodes() throws {
    let json = """
    {"session":"s1","updated":"2026-11-01T10:00:00Z","captures":[{"id":"toolu_09","kind":"screenshot","file":"toolu_09.png",
     "caption":"Screenshot","purpose":"test","at":"2026-11-01T10:00:00Z","source":"glance"}]}
    """
    let record = try WorkRecord.decoder.decode(WorkRecord.self, from: Data(json.utf8))
    #expect(record.captures.count == 1 && record.captures[0].sha256 == nil)
  }

  @Test func aScreenshotCaptureStaysInTheHooksBudget() throws {
    let f = try fixture(setup: false)
    try Data(repeating: 0x5A, count: 2 * 1024 * 1024).write(to: f.repo.appendingPathComponent("big.png"))
    let p = screenshot(f, response: screenshotResponse("big.png"))
    // Copy and hash of a 2 MB screenshot; the hook's budget is 30 ms, twice that tolerates a loaded test machine.
    let started = Date()
    WorkObserver(store: f.store).observe(p)
    #expect(Date().timeIntervalSince(started) < 0.030 * 2)
    #expect(f.store.record(session: "s1")?.captures.first?.sha256?.count == 64)
  }

  @Test func aBigScreenshotIsCapturedButNotHashedInTheHook() throws {
    let f = try fixture(setup: false)
    let limit = WorkStore.hookHashLimit
    try Data(repeating: 0x5A, count: limit + 1).write(to: f.repo.appendingPathComponent("huge.png"))
    try Data(repeating: 0x5A, count: limit).write(to: f.repo.appendingPathComponent("edge.png"))
    WorkObserver(store: f.store).observe(screenshot(f, response: screenshotResponse("huge.png"), id: "over"))
    WorkObserver(store: f.store).observe(screenshot(f, response: screenshotResponse("edge.png"), id: "at"))
    let captures = try #require(f.store.record(session: "s1")?.captures)
    #expect(captures.map(\.id) == ["over", "at"])
    #expect(captures[0].sha256 == nil) // over the limit: recorded, hash unknown
    #expect(captures[1].sha256?.count == 64) // at the limit: hashed
    #expect(FileManager.default.fileExists(atPath: f.store.mediaFolder(session: "s1").appendingPathComponent("over.png").path))
  }

  @Test func otherCapturePathsHashWhateverTheSize() throws {
    let f = try fixture(setup: false)
    let file = f.repo.appendingPathComponent("huge.png")
    try Data(repeating: 0x5A, count: WorkStore.hookHashLimit + 1).write(to: file)
    let added = f.store.addCapture(session: "s1", id: "tool", from: file, kind: .screenshot, url: nil, environment: nil,
                                   caption: "c", purpose: .outcome, source: .claude, commonDir: nil)
    #expect(added?.sha256?.count == 64)
  }

  @Test func screenshotRelativePathResolvesAgainstTheHookFolderFirst() throws {
    let f = try fixture(setup: false)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: f.repo.appendingPathComponent("page-1.png"))
    WorkObserver(store: f.store, tmpDir: "/nonexistent").observe(screenshot(f, response: screenshotResponse("page-1.png")))
    #expect(f.store.record(session: "s1")?.captures.first?.file == "toolu_09.png")
  }

  @Test func screenshotAfterANavigationCarriesItsURLAndEnvironment() throws {
    let f = try fixture()
    let tmp = try browserTemp()
    let observer = WorkObserver(store: f.store, tmpDir: tmp.path)
    observer.observe(browserCall(f, url: "http://localhost:3000/login"))
    #expect(f.store.record(session: "s1")?.lastBrowserURL == "http://localhost:3000/login")
    observer.observe(screenshot(f, response: screenshotResponse("../../x/glance-browser/page-2026-11-02T03-05-24-713Z.png")))
    let record = try #require(f.store.record(session: "s1"))
    let capture = try #require(record.captures.first)
    #expect(capture.url == "http://localhost:3000/login" && capture.environment == "Local")
    #expect(capture.caption == "localhost:3000/login")
    #expect(record.branch == "feat/x")
  }

  @Test func theLatestBrowserURLWinsAndAnUnchangedOneIsNotRewritten() throws {
    let f = try fixture(setup: false)
    let observer = WorkObserver(store: f.store)
    observer.observe(browserCall(f, url: "http://localhost:3000/", id: "a"))
    let file = f.store.sessionFolder("s1").appendingPathComponent("record.json")
    let first = try Data(contentsOf: file)
    observer.observe(browserCall(f, "browser_snapshot", url: "http://localhost:3000/", id: "b"))
    #expect(try Data(contentsOf: file) == first) // same URL: no write
    observer.observe(browserCall(f, "browser_click", url: "http://localhost:3000/settings", id: "c"))
    #expect(f.store.record(session: "s1")?.lastBrowserURL == "http://localhost:3000/settings")
  }

  @Test func screenshotWithNoEarlierBrowserCallHasNoURLButIsCaptured() throws {
    let f = try fixture()
    let tmp = try browserTemp()
    WorkObserver(store: f.store, tmpDir: tmp.path).observe(
      screenshot(f, response: screenshotResponse("../../x/glance-browser/page-2026-11-02T03-05-24-713Z.png")))
    let capture = try #require(f.store.record(session: "s1")?.captures.first)
    #expect(capture.url == nil && capture.environment == nil)
  }

  @Test func theSameScreenshotCallIsAddedOnce() throws {
    let f = try fixture(setup: false)
    try Data([1]).write(to: f.repo.appendingPathComponent("p.png"))
    let p = screenshot(f, response: screenshotResponse("p.png"))
    WorkObserver(store: f.store).observe(p)
    WorkObserver(store: f.store).observe(p)
    #expect(f.store.record(session: "s1")?.captures.count == 1)
  }

  @Test func screenshotInAStringOrAbsolutePathForm() throws {
    let f = try fixture(setup: false)
    let shot = f.repo.appendingPathComponent("abs.jpeg")
    try Data([0xFF, 0xD8]).write(to: shot)
    WorkObserver(store: f.store).observe(screenshot(f, response: "### Result\n- [Screenshot of viewport](\(shot.path))\n", id: "a"))
    #expect(f.store.record(session: "s1")?.captures.first?.file == "a.jpeg")
  }

  @Test func missingScreenshotSkipped() throws {
    let f = try fixture(setup: false)
    WorkObserver(store: f.store, tmpDir: "/nonexistent").observe(screenshot(f, response: screenshotResponse("nope.png")))
    #expect(f.store.record(session: "s1") == nil)
  }

  @Test func aToolUseIDCannotLeaveTheMediaFolder() throws {
    let f = try fixture(setup: false)
    try Data([1]).write(to: f.repo.appendingPathComponent("p.png"))
    WorkObserver(store: f.store).observe(screenshot(f, response: screenshotResponse("p.png"), id: "../../../evil"))
    let capture = try #require(f.store.record(session: "s1")?.captures.first)
    #expect(!capture.file.contains("/"))
    let media = f.store.mediaFolder(session: "s1")
    #expect(try FileManager.default.contentsOfDirectory(atPath: media.path) == [capture.file])
  }

  @Test func aFailedScreenshotCallAndOtherToolsAddNothing() throws {
    let f = try fixture(setup: false)
    try Data([1]).write(to: f.repo.appendingPathComponent("p.png"))
    WorkObserver(store: f.store).observe(screenshot(f, response: screenshotResponse("p.png"), event: "PostToolUseFailure"))
    WorkObserver(store: f.store).observe(data([
      "session_id": "s1", "cwd": f.repo.path, "hook_event_name": "PostToolUse", "tool_name": "mcp__other__shot",
      "tool_response": screenshotResponse("p.png")]))
    #expect(f.store.record(session: "s1") == nil)
  }
}
