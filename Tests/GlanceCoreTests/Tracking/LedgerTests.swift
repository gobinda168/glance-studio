import Darwin
import Foundation
import Testing
@testable import GlanceCore

private func scratchLedger() -> Ledger {
  Ledger(folder: FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)"))
}

struct LedgerTests {
  @Test func appendsReadsAndPrunesRecords() {
    let ledger = scratchLedger()
    let old = LedgerRecord(t: Date(timeIntervalSince1970: 1_000), kind: .sessionStart, worktree: "/w", session: "s1")
    let new = LedgerRecord(t: Date(timeIntervalSince1970: 9_000), kind: .change, worktree: "/w", session: "s1",
                           files: [LedgerRecord.File(path: "a", status: ".M", hash: "h")])
    ledger.append([old, new], repo: "/r/.git")
    #expect(ledger.records(repo: "/r/.git") == [old, new])
    ledger.prune(repo: "/r/.git", before: Date(timeIntervalSince1970: 5_000))
    #expect(ledger.records(repo: "/r/.git") == [new])
  }

  @Test func stateRoundTripsAndListsRepositories() {
    let ledger = scratchLedger()
    var state = ledger.state(repo: "/r/.git")
    #expect(state == TrackState(repo: "/r/.git"))
    state.setFingerprint(Fingerprint(entries: ["a": .init(status: ".M", size: 1, mtime: 1, hash: "h")]), for: "/w")
    ledger.save(state)
    #expect(ledger.state(repo: "/r/.git") == state)
    #expect(ledger.repos() == ["/r/.git"])
  }

  @Test func applyKeepsSessionsAndAuthors() {
    var state = TrackState(repo: "/r/.git")
    let t = Date(timeIntervalSince1970: 100)
    state.apply(LedgerRecord(t: t, kind: .sessionStart, worktree: "/w", session: "s1", pid: 42, terminal: "Warp"))
    state.apply(LedgerRecord(t: t, kind: .prompt, worktree: "/w", session: "s1", text: "fix the build"))
    state.apply(LedgerRecord(t: t, kind: .prompt, worktree: "/w", session: "s1", text: "and then this"))
    state.apply(LedgerRecord(t: t, kind: .change, worktree: "/w", session: "s1",
                             files: [.init(path: "a", status: ".M", hash: "h1")]))
    state.apply(LedgerRecord(t: t, kind: .ambiguous, worktree: "/w", sessions: ["s1", "s2"],
                             files: [.init(path: "b", status: "??", hash: "h2")]))
    #expect(state.sessions["s1"]?.task == "fix the build")
    #expect(state.authors["/w"]?["a"] == TrackState.Authorship(hash: "h1", author: .session("s1")))
    #expect(state.authors["/w"]?["b"]?.author == .ambiguous(["s1", "s2"]))
    state.apply(LedgerRecord(t: t, kind: .sessionEnd, worktree: "/w", session: "s1"))
    #expect(state.sessions["s1"]?.isLive { _ in true } == false)
    // Setting a fingerprint forgets the authors of files that are no longer uncommitted (committed or reverted).
    state.setFingerprint(Fingerprint(entries: ["b": .init(status: "??", size: 1, mtime: 1, hash: "h2")]), for: "/w")
    #expect(state.authors["/w"]?["a"] == nil)
    #expect(state.authors["/w"]?["b"] != nil)
  }

  @Test func lockedGivesUpWhenAnotherHolderHasTheLock() throws {
    let ledger = scratchLedger()
    #expect(ledger.locked(repo: "/r/.git") { 1 } == 1)
    // Another open file description holding the lock (as another hook process would).
    let path = ledger.folder.appendingPathComponent(Ledger.key(repo: "/r/.git") + ".lock").path
    let fd = open(path, O_RDWR)
    #expect(fd >= 0)
    #expect(flock(fd, LOCK_EX) == 0)
    #expect(ledger.locked(repo: "/r/.git", budget: 0.02) { 1 } == nil)
    flock(fd, LOCK_UN)
    close(fd)
  }

  @Test func anOlderLookInTheSameSecondDoesntReplaceANewerOneAfterASave() {
    // Hooks re-read the state from disk, so the newer look's time must survive a save to the sub-second.
    let ledger = scratchLedger()
    let newer = Fingerprint(entries: ["a": .init(status: ".M", size: 2, mtime: 2, hash: "new")])
    let older = Fingerprint(entries: ["a": .init(status: ".M", size: 1, mtime: 1, hash: "old")])
    var state = ledger.state(repo: "/r/.git")
    state.setFingerprint(newer, for: "/w", at: Date(timeIntervalSince1970: 10.7))
    ledger.save(state)
    var reloaded = ledger.state(repo: "/r/.git")
    reloaded.setFingerprint(older, for: "/w", at: Date(timeIntervalSince1970: 10.3))
    #expect(reloaded.fingerprints["/w"]?.entries["a"]?.hash == "new")
  }
}
