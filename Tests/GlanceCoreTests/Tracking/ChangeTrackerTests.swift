import Foundation
import Testing
@testable import GlanceCore

/// A fake worktree: tests set `files` (path → hash) between hook calls.
private final class FakeTree: @unchecked Sendable {
  var files: [String: String] = [:]
  /// Above the file limit: git lists too many files to fingerprint.
  var tooMany = false
  var print: Fingerprint {
    tooMany ? Fingerprint(tooMany: true)
      : Fingerprint(entries: files.mapValues { Fingerprint.Entry(status: ".M", size: 1, mtime: 1, hash: $0) })
  }
}

private func tracker(_ tree: FakeTree, ledger: Ledger, cwdRepo: Bool = true) -> ChangeTracker {
  ChangeTracker(ledger: ledger, now: { Date(timeIntervalSince1970: 1_000) }, claudePID: 42, terminal: "Warp",
          alive: { _ in true },
          location: { _ in cwdRepo ? RepoLocation(worktree: "/w", commonDir: "/r/.git", branch: "main") : nil },
          fingerprint: { _, _ in tree.print })
}

private func scratch() -> Ledger {
  Ledger(folder: FileManager.default.temporaryDirectory.appendingPathComponent("tracker-\(UUID().uuidString)"))
}

private func hook(_ event: String, _ session: String, tool: String? = nil, id: String? = nil,
                  command: String? = nil, prompt: String? = nil) -> HookInput {
  HookInput(sessionID: session, cwd: "/w", event: event, toolName: tool, toolUseID: id, command: command,
            prompt: prompt)
}

struct ChangeTrackerTests {
  @Test func recordsASessionsEditAndAHandEdit() {
    let tree = FakeTree()
    let ledger = scratch()
    let track = tracker(tree, ledger: ledger)
    _ = track.handle(hook("SessionStart", "s1"))
    _ = track.handle(hook("UserPromptSubmit", "s1", prompt: "fix the build"))
    _ = track.handle(hook("PreToolUse", "s1", tool: "Edit", id: "t1"))
    tree.files["a.swift"] = "h1"
    _ = track.handle(hook("PostToolUse", "s1", tool: "Edit", id: "t1"))
    tree.files["notes.md"] = "h2" // by hand, between calls
    _ = track.handle(hook("UserPromptSubmit", "s1", prompt: "next"))
    let state = ledger.state(repo: "/r/.git")
    #expect(state.authors["/w"]?["a.swift"]?.author == .session("s1"))
    #expect(state.authors["/w"]?["notes.md"]?.author == .outside)
    #expect(state.sessions["s1"]?.task == "fix the build")
    #expect(state.sessions["s1"]?.terminal == "Warp")
    #expect(ledger.records(repo: "/r/.git").map(\.kind) == [.sessionStart, .prompt, .change, .outside])
  }

  @Test func interleavedCallsOfTwoSessionsAreAmbiguous() {
    let tree = FakeTree()
    let ledger = scratch()
    let track = tracker(tree, ledger: ledger)
    _ = track.handle(hook("PreToolUse", "s1", tool: "Bash", id: "a"))
    _ = track.handle(hook("PreToolUse", "s2", tool: "Edit", id: "b"))
    tree.files["x"] = "1"
    _ = track.handle(hook("PostToolUse", "s2", tool: "Edit", id: "b")) // s2 finishes first
    _ = track.handle(hook("PostToolUse", "s1", tool: "Bash", id: "a"))
    #expect(ledger.state(repo: "/r/.git").authors["/w"]?["x"]?.author == .ambiguous(["s2", "s1"])
      || ledger.state(repo: "/r/.git").authors["/w"]?["x"]?.author == .ambiguous(["s1", "s2"]))
    #expect(ledger.records(repo: "/r/.git").allSatisfy { $0.kind == .ambiguous })
  }

  @Test func outsideARepositoryNothingHappens() {
    let ledger = scratch()
    let reply = tracker(FakeTree(), ledger: ledger, cwdRepo: false).handle(hook("SessionStart", "s1"))
    #expect(reply == .none)
    #expect(ledger.repos().isEmpty)
  }

  @Test func sessionEndClosesItsCalls() {
    let tree = FakeTree()
    let ledger = scratch()
    let track = tracker(tree, ledger: ledger)
    _ = track.handle(hook("SessionStart", "s1"))
    _ = track.handle(hook("PreToolUse", "s1", tool: "Bash", id: "t"))
    _ = track.handle(hook("SessionEnd", "s1"))
    let state = ledger.state(repo: "/r/.git")
    #expect(state.open.isEmpty)
    #expect(state.sessions["s1"]?.ended != nil)
  }

  @Test func replyJSONCarriesTheNoteForClaude() {
    #expect(HookReply.none.output(event: "PreToolUse") == nil)
    let out = HookReply(context: "hello").output(event: "PreToolUse") ?? ""
    let object = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
    let specific = object?["hookSpecificOutput"] as? [String: Any]
    #expect(specific?["hookEventName"] as? String == "PreToolUse")
    #expect(specific?["additionalContext"] as? String == "hello")
  }

  @Test func aSessionIsToldAboutAnotherSessionsEditsOnceAndBeforeACommit() {
    let tree = FakeTree()
    let ledger = scratch()
    let track = tracker(tree, ledger: ledger)
    _ = track.handle(hook("SessionStart", "s1"))
    _ = track.handle(hook("UserPromptSubmit", "s1", prompt: "release beta.18"))
    _ = track.handle(hook("PreToolUse", "s1", tool: "Edit", id: "t1"))
    tree.files["Info.plist"] = "h1"
    _ = track.handle(hook("PostToolUse", "s1", tool: "Edit", id: "t1"))

    let start = track.handle(hook("SessionStart", "s2"))
    #expect(start.context?.contains("release beta.18: Info.plist") == true)
    #expect(start.context?.contains("another Claude session is working in this worktree") == true)
    // The same state isn't told twice.
    let first = track.handle(hook("UserPromptSubmit", "s2", prompt: "fix the tests"))
    #expect(first.context?.contains("aren't this session's") != true)
    #expect(first.context?.contains("by who made them") == true) // topics on the first prompt
    let commit = track.handle(hook("PreToolUse", "s2", tool: "Bash", id: "c", command: "git commit -am x"))
    #expect(commit.context?.contains("by who made them") == true)
    let again = track.handle(hook("PreToolUse", "s2", tool: "Bash", id: "c2", command: "git commit -am y"))
    #expect(again.context?.contains("by who made them") == true) // commits are always checked
  }

  @Test func tooManyFilesKeepTheAuthorsAndRecordNothing() {
    let tree = FakeTree()
    let ledger = scratch()
    let track = tracker(tree, ledger: ledger)
    _ = track.handle(hook("PreToolUse", "s1", tool: "Edit", id: "t1"))
    tree.files["a"] = "1"
    _ = track.handle(hook("PostToolUse", "s1", tool: "Edit", id: "t1"))
    #expect(ledger.records(repo: "/r/.git").map(\.kind) == [.change])

    // Over the limit: the authors stay, and neither a look nor a call records anything.
    tree.tooMany = true
    tree.files["b"] = "1"
    _ = track.handle(hook("UserPromptSubmit", "s1", prompt: "go on"))
    _ = track.handle(hook("PreToolUse", "s2", tool: "Edit", id: "t2"))
    tree.files["c"] = "1"
    _ = track.handle(hook("PostToolUse", "s2", tool: "Edit", id: "t2"))
    _ = track.handle(hook("PreToolUse", "s2", tool: "Bash", id: "t3")) // starts over the limit, ends below it
    var state = ledger.state(repo: "/r/.git")
    #expect(state.authors["/w"]?["a"]?.author == .session("s1"))
    #expect(state.fingerprints["/w"]?.tooMany == true)

    // Back below the limit: the files that changed meanwhile aren't credited to anyone.
    tree.tooMany = false
    tree.files["d"] = "1"
    _ = track.handle(hook("PostToolUse", "s2", tool: "Bash", id: "t3"))
    _ = track.handle(hook("UserPromptSubmit", "s1", prompt: "and more"))
    state = ledger.state(repo: "/r/.git")
    #expect(ledger.records(repo: "/r/.git").map(\.kind) == [.change, .sessionStart, .prompt]) // s1's first prompt
    #expect(state.authors["/w"]?["a"]?.author == .session("s1"))
    #expect(state.authors["/w"]?["b"] == nil)
    #expect(state.fingerprints["/w"]?.tooMany == false)
  }

  @Test func readOnlyToolCallsAreSkipped() {
    let ledger = scratch()
    var looks = 0
    let track = ChangeTracker(ledger: ledger, alive: { _ in true },
                              location: { _ in RepoLocation(worktree: "/w", commonDir: "/r/.git", branch: "main") },
                              fingerprint: { _, _ in looks += 1; return Fingerprint() })
    for tool in ["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "TodoWrite", "Task", "Agent", "NotebookRead"] {
      #expect(track.handle(hook("PreToolUse", "s1", tool: tool, id: tool)) == .none)
      #expect(track.handle(hook("PostToolUse", "s1", tool: tool, id: tool)) == .none)
    }
    #expect(looks == 0)
    #expect(ledger.repos().isEmpty) // no state written, so no open call either
    #expect(ledger.records(repo: "/r/.git").isEmpty)
  }

  @Test func sessionsOnlySkipsToolEvents() {
    let ledger = scratch()
    var looks = 0
    var track = ChangeTracker(ledger: ledger, alive: { _ in true },
                              location: { _ in Issue.record("git ran"); return nil },
                              fingerprint: { _, _ in looks += 1; return Fingerprint() })
    track.sessionsOnly = true
    for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {
      #expect(track.handle(hook(event, "s1", tool: "Edit", id: "t1")) == .none)
    }
    #expect(looks == 0)
    #expect(ledger.repos().isEmpty)
  }

  @Test func sessionsOnlyKeepsTheSessionListButNeverFingerprintsOrWarns() {
    let ledger = scratch()
    var looks = 0
    // A second live session in the same worktree with an edit by hand would warn on SessionStart with Worktrees on.
    var track = ChangeTracker(ledger: ledger, now: { Date(timeIntervalSince1970: 1_000) }, claudePID: 42, terminal: "Warp",
                              alive: { _ in true },
                              location: { _ in RepoLocation(worktree: "/w", commonDir: "/r/.git", branch: "main") },
                              fingerprint: { _, _ in looks += 1; return Fingerprint(entries: ["a": .init(status: ".M", size: 1, mtime: 1, hash: "h")]) })
    track.sessionsOnly = true
    #expect(track.handle(hook("SessionStart", "s1")) == .none)
    #expect(track.handle(hook("UserPromptSubmit", "s1", prompt: "fix the build")) == .none)
    #expect(track.handle(hook("SessionStart", "s2")) == .none)
    #expect(track.handle(hook("UserPromptSubmit", "s2", prompt: "other")) == .none)
    #expect(looks == 0)
    let state = ledger.state(repo: "/r/.git")
    #expect(state.sessions["s1"]?.task == "fix the build" && state.sessions["s2"] != nil)
    #expect(state.fingerprints.isEmpty && state.told.isEmpty)
  }

  @Test func aFailedToolCallEndsTheCallLikeASuccessfulOne() {
    let tree = FakeTree()
    let ledger = scratch()
    let track = tracker(tree, ledger: ledger)
    _ = track.handle(hook("PreToolUse", "s1", tool: "Bash", id: "t1"))
    tree.files["a.swift"] = "h1" // the command changed a file, then exited non-zero
    _ = track.handle(hook("PostToolUseFailure", "s1", tool: "Bash", id: "t1"))
    let state = ledger.state(repo: "/r/.git")
    #expect(state.open.isEmpty)
    #expect(state.authors["/w"]?["a.swift"]?.author == .session("s1"))
  }

  @Test func anOlderLookDoesntReplaceANewerOne() {
    // Hooks fingerprint before the lock: a look that began earlier can reach the lock after a later one.
    let entry = { (hash: String) in Fingerprint(entries: ["a": .init(status: ".M", size: 1, mtime: 1, hash: hash)]) }
    var state = TrackState(repo: "/r/.git")
    state.setFingerprint(entry("new"), for: "/w", at: Date(timeIntervalSince1970: 20))
    let stale = ChangeTracker.Look(tree: "/w", print: entry("old"), at: Date(timeIntervalSince1970: 10))
    let looked = tracker(FakeTree(), ledger: scratch())
      .lookOutside(stale, branch: nil, time: Date(timeIntervalSince1970: 30), state: &state)
    #expect(looked.outside == nil)
    #expect(looked.print == entry("new"))
    #expect(state.fingerprints["/w"] == entry("new"))
    state.setFingerprint(entry("old"), for: "/w", at: Date(timeIntervalSince1970: 10))
    #expect(state.fingerprints["/w"] == entry("new"))
  }

  @Test func noNoteWhenTheWorktreeIsOnlyMine() {
    let tree = FakeTree()
    let ledger = scratch()
    let track = tracker(tree, ledger: ledger)
    _ = track.handle(hook("SessionStart", "s1"))
    _ = track.handle(hook("PreToolUse", "s1", tool: "Edit", id: "t1"))
    tree.files["a"] = "1"
    #expect(track.handle(hook("PostToolUse", "s1", tool: "Edit", id: "t1")).context == nil)
    // Committing only its own work, alone in the worktree: nothing to warn about.
    #expect(track.handle(hook("PreToolUse", "s1", tool: "Bash", id: "c1", command: "git commit -am a")).context == nil)
    // Another live session in the worktree: the commit gets the note.
    _ = track.handle(hook("SessionStart", "s2"))
    let shared = track.handle(hook("PreToolUse", "s1", tool: "Bash", id: "c2", command: "git commit -am a"))
    #expect(shared.context?.contains("by who made them") == true)
  }
}
