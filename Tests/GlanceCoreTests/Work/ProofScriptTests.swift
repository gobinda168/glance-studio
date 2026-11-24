import Darwin
import Foundation
import Testing
@testable import GlanceCore

/// A folder with scripts in it, removed after the test.
private final class Scripts {
  let root: String
  init() {
    root = NSTemporaryDirectory() + "proof-script-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }
  deinit { try? FileManager.default.removeItem(atPath: root) }

  @discardableResult func add(_ name: String, _ body: String) -> String {
    let path = root + "/" + name
    try? ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return name
  }
}

private func lastLine(_ outcome: ProofScript.Outcome) -> String? {
  if case .output(let text) = outcome { return text.split(whereSeparator: \.isNewline).last.map(String.init) }
  return nil
}

@Test func aScriptThatPrintsAURLGivesIt() {
  let s = Scripts()
  s.add("url.sh", "echo https://preview.example.com/pr-7")
  let outcome = ProofScript.run("url.sh", root: s.root)
  #expect(lastLine(outcome) == "https://preview.example.com/pr-7")
}

@Test func theScriptRunsInTheRootWithTheSessionEnvironment() {
  let s = Scripts()
  s.add("env.sh", #"echo "$GLANCE_BRANCH|$GLANCE_PR|$GLANCE_WORKTREE|$(pwd -P)""#)
  let outcome = ProofScript.run("env.sh", root: s.root,
                                environment: ["GLANCE_BRANCH": "feat/x", "GLANCE_PR": "12", "GLANCE_WORKTREE": "/wt/x"])
  let real = realpath(s.root, nil).map { String(cString: $0) } ?? s.root
  #expect(lastLine(outcome) == "feat/x|12|/wt/x|\(real)")
}

@Test func anAbsolutePathIsRunAsIs() {
  let s = Scripts()
  let name = s.add("abs.sh", "echo https://abs.example.com")
  #expect(lastLine(ProofScript.run(s.root + "/" + name, root: "/")) == "https://abs.example.com")
}

@Test func aScriptWithSpacesAndQuotesInItsPathRuns() {
  let s = Scripts()
  s.add("it's here.sh", "echo https://quoted.example.com")
  #expect(lastLine(ProofScript.run("it's here.sh", root: s.root)) == "https://quoted.example.com")
}

@Test func aScriptThatPrintsNothingIsAnEmptyOutput() {
  let s = Scripts()
  s.add("quiet.sh", "true")
  guard case .output(let text) = ProofScript.run("quiet.sh", root: s.root) else { Issue.record("failed"); return }
  // A login shell may greet; the script itself added nothing.
  #expect(ProofScript.lastURL(in: text) == nil)
}

@Test func aFailureReturnsItsOutputAndStatus() {
  let s = Scripts()
  s.add("bad.sh", "echo 'no deploy found' >&2; exit 3")
  guard case .failed(let message) = ProofScript.run("bad.sh", root: s.root) else { Issue.record("did not fail"); return }
  #expect(message.contains("exited with 3"))
  #expect(message.contains("no deploy found"))
}

@Test func aMissingScriptFailsWithTheShellsWords() {
  let s = Scripts()
  guard case .failed(let message) = ProofScript.run("missing.sh", root: s.root) else { Issue.record("did not fail"); return }
  #expect(message.contains("missing.sh"))
}

@Test func aBackgroundChildHoldingTheOutputDoesNotHoldTheCall() {
  let s = Scripts()
  let pidFile = s.root + "/child.pid"
  s.add("bg.sh", "sleep 20 &\necho $! > '\(pidFile)'\necho https://bg.example.com")
  defer {
    if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
       let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
  }
  let start = Date()
  let outcome = ProofScript.run("bg.sh", root: s.root, timeout: 10)
  #expect(lastLine(outcome) == "https://bg.example.com")
  #expect(Date().timeIntervalSince(start) < 8)
}

@Test func aScriptDoesNotInheritStudiosOpenFiles() {
  let s = Scripts()
  // A descriptor without close-on-exec, as a leftover from some other code in Studio could be.
  let fd = open("/dev/null", O_RDONLY)
  defer { close(fd) }
  s.add("fd.sh", #"if [ -e "/dev/fd/$LEAK_FD" ]; then echo leaked; else echo closed; fi"#)
  let outcome = ProofScript.run("fd.sh", root: s.root, environment: ["LEAK_FD": String(fd)])
  #expect(lastLine(outcome) == "closed")
}

@Test func aFloodOfOutputStillTimesOut() {
  let s = Scripts()
  s.add("flood.sh", "exec yes")
  let start = Date()
  guard case .failed(let message) = ProofScript.run("flood.sh", root: s.root, timeout: 1) else {
    Issue.record("did not time out"); return
  }
  #expect(message.contains("took longer than 1 s"))
  #expect(Date().timeIntervalSince(start) < 8)
}

@Test func aHungScriptIsStoppedWithItsChildrenAndShowsWhatItPrinted() {
  let s = Scripts()
  let pidFile = s.root + "/child.pid"
  s.add("hang.sh", "echo starting\nsleep 60 &\necho $! > '\(pidFile)'\nwait")
  let start = Date()
  guard case .failed(let message) = ProofScript.run("hang.sh", root: s.root, timeout: 1) else {
    Issue.record("did not time out"); return
  }
  #expect(message.contains("took longer than 1 s"))
  #expect(message.contains("starting"))
  #expect(Date().timeIntervalSince(start) < 8)
  let pid = pid_t((try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
  guard let pid else { Issue.record("no child pid"); return }
  var gone = false
  for _ in 0..<40 where !gone {
    gone = kill(pid, 0) != 0 && errno == ESRCH
    if !gone { usleep(50_000) }
  }
  #expect(gone, "the child outlived the timeout")
}

@Test func theLastURLLineWins() {
  #expect(ProofScript.lastURL(in: "building…\nhttps://a.example.com\n\ndone\nhttps://b.example.com/x?y=1\n\n")
    == "https://b.example.com/x?y=1")
  #expect(ProofScript.lastURL(in: "  http://localhost:3000  \nbye") == "http://localhost:3000")
  #expect(ProofScript.lastURL(in: "") == nil)
  #expect(ProofScript.lastURL(in: "Preview at https://a.example.com") == nil)
  #expect(ProofScript.lastURL(in: "https://") == nil)
}

@Test func previewURLTakesTheLastURLOfAScript() {
  let s = Scripts()
  s.add("preview.sh", #"echo "deploying $GLANCE_BRANCH"; echo "https://pr-$GLANCE_PR.example.com""#)
  let env = ProofSetup.Environment(name: "Preview", urlScript: "preview.sh")
  let info = ProofPR.Info(number: 31, url: "", state: "OPEN", merged: false, checksFailing: false, head: "feat/x",
                          repository: "o/r")
  #expect(ProofPR.previewURL(env: env, info: info, root: s.root, branch: "feat/x", worktree: "/wt")
    == .success("https://pr-31.example.com"))
}

@Test func aScriptWithNoURLInItsOutputIsAFailure() {
  let s = Scripts()
  s.add("none.sh", "echo not ready yet")
  let env = ProofSetup.Environment(name: "Preview", urlScript: "none.sh")
  guard case .failure(let message) = ProofPR.previewURL(env: env, info: nil, root: s.root, branch: nil, worktree: nil)
  else { Issue.record("expected a failure"); return }
  #expect(message.message.contains("printed no URL"))
  #expect(message.message.contains("not ready yet"))
}
