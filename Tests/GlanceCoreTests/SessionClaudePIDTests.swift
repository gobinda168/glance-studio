import Foundation
import Testing
@testable import GlanceCore

/// Which `claude` process a Studio tab's session runs under, to find that session's browser windows (the table keys
/// them by the process, which survives `/clear`; the session id does not).
struct SessionClaudePIDTests {
  private let repo = "/Users/me/app/.git"

  private func ledger(_ records: [LedgerRecord]) throws -> (Ledger, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-pid-\(UUID().uuidString)")
    let ledger = Ledger(folder: folder)
    var state = TrackState(repo: repo)
    for record in records { state.apply(record) }
    ledger.save(state)
    return (ledger, folder)
  }

  private func start(_ session: String, pid: Int32?, at seconds: TimeInterval) -> LedgerRecord {
    LedgerRecord(t: Date(timeIntervalSince1970: seconds), kind: .sessionStart, worktree: "/Users/me/app", session: session,
                 branch: "main", pid: pid, terminal: "studio:5C1D")
  }

  @Test func theTerminalsForegroundClaudeIsTheProcess() throws {
    let (ledger, folder) = try ledger([])
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(SessionClaudePID.find(foregroundPID: 4100, sessionID: "new", cwd: "/Users/me/app", ledger: ledger,
                                  commonDir: { _ in repo }, isClaude: { $0 == 4100 }) == 4100)
  }

  @Test func afterClearTheLedgerKnowsTheNewSessionRunsInTheSameProcess() throws {
    // Claude Code's /clear starts a new session id in the same process: the ledger's session-start for the new id
    // carries the pid the window table was keyed by.
    let (ledger, folder) = try ledger([start("old", pid: 4100, at: 1), start("new", pid: 4100, at: 2)])
    defer { try? FileManager.default.removeItem(at: folder) }
    let pid = SessionClaudePID.find(foregroundPID: nil, sessionID: "new", cwd: "/Users/me/app", ledger: ledger,
                                    commonDir: { _ in repo }, isClaude: { $0 == 4100 })
    #expect(pid == 4100)

    // The wrapper said "old" in its hello; asking by the new id alone finds nothing, asking with the pid finds the window.
    var table = BrowserSessionTable()
    table.apply(.hello(wrapperPID: 4121, claudePID: 4100, session: "old", cwd: "/Users/me/app"), client: 1, at: Date())
    table.apply(.page(targetId: "AB12", adopted: false), client: 1, at: Date())
    #expect(table.pages(claudePID: nil, session: "new") == [])
    #expect(table.pages(claudePID: pid, session: "new") == ["AB12"])
  }

  @Test func aTabNotInFrontOfClaudeStillFindsItByItsSession() throws {
    // Claude is suspended or something else is in front: the foreground process isn't claude.
    let (ledger, folder) = try ledger([start("s", pid: 4100, at: 1)])
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(SessionClaudePID.find(foregroundPID: 900, sessionID: "s", cwd: "/Users/me/app", ledger: ledger,
                                  commonDir: { _ in repo }, isClaude: { $0 == 4100 }) == 4100)
  }

  @Test func aPidThatIsNoLongerClaudeIsNotTheAnswer() throws {
    // The system reused the number for another program.
    let (ledger, folder) = try ledger([start("s", pid: 4100, at: 1)])
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(SessionClaudePID.find(foregroundPID: nil, sessionID: "s", cwd: "/Users/me/app", ledger: ledger,
                                  commonDir: { _ in repo }, isClaude: { _ in false }) == nil)
  }

  @Test func aSessionTheLedgerDoesNotKnowHasNoProcess() throws {
    let (ledger, folder) = try ledger([start("other", pid: 4100, at: 1), start("nopid", pid: nil, at: 2)])
    defer { try? FileManager.default.removeItem(at: folder) }
    for id in ["unknown", "nopid"] {
      #expect(SessionClaudePID.find(foregroundPID: nil, sessionID: id, cwd: "/Users/me/app", ledger: ledger,
                                    commonDir: { _ in repo }, isClaude: { _ in true }) == nil)
    }
  }

  @Test func outsideGitTheLedgerIsSearchedByTheSessionId() throws {
    // The hooks key a repository by git's own spelling of its folder; when the cwd's spelling differs, or there is no
    // repository, the session id (a UUID) still finds the one record.
    let (ledger, folder) = try ledger([start("s", pid: 4100, at: 1)])
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(SessionClaudePID.find(foregroundPID: nil, sessionID: "s", cwd: "/tmp/not-a-repo", ledger: ledger,
                                  commonDir: { _ in nil }, isClaude: { $0 == 4100 }) == 4100)
    #expect(SessionClaudePID.find(foregroundPID: nil, sessionID: "s", cwd: nil, ledger: ledger,
                                  commonDir: { _ in nil }, isClaude: { $0 == 4100 }) == 4100)
  }
}
