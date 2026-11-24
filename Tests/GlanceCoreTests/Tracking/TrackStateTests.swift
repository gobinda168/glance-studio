import Foundation
import Testing
@testable import GlanceCore

struct TrackStateTests {
  private func session(_ id: String, pid: Int32?, started: TimeInterval, ended: Bool = false) -> TrackedSession {
    TrackedSession(id: id, worktree: "/w", branch: nil, pid: pid, terminal: nil, task: nil,
                   started: Date(timeIntervalSince1970: started), ended: ended ? Date() : nil)
  }

  private func state(_ sessions: [TrackedSession]) -> TrackState {
    var state = TrackState(repo: "/r")
    for session in sessions { state.sessions[session.id] = session }
    return state
  }

  @Test func noClaudeProcessMatchesNoSession() {
    // A session without a pid must not match a missing claude pid (nil == nil).
    let state = state([session("a", pid: nil, started: 1)])
    #expect(state.liveSession(claudePID: nil, alive: { _ in true }) == nil)
  }

  @Test func findsTheLiveSessionOfThatProcess() {
    let state = state([session("a", pid: 10, started: 1), session("b", pid: 20, started: 2)])
    #expect(state.liveSession(claudePID: 10, alive: { _ in true }) == "a")
    #expect(state.liveSession(claudePID: 30, alive: { _ in true }) == nil)
  }

  @Test func skipsEndedAndDeadSessions() {
    let state = state([session("ended", pid: 10, started: 1, ended: true)])
    #expect(state.liveSession(claudePID: 10, alive: { _ in true }) == nil)
    let dead = self.state([session("a", pid: 10, started: 1)])
    #expect(dead.liveSession(claudePID: 10, alive: { _ in false }) == nil)
  }

  @Test func pruneDropsOldSessionsTheirToldAndGoneWorktrees() {
    let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 100 * day)
    func at(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }
    var state = TrackState(repo: "/r")
    let session = { (id: String, pid: Int32, started: Date, ended: Date?) in
      TrackedSession(id: id, worktree: "/w", branch: nil, pid: pid, terminal: nil, task: nil, started: started,
                     ended: ended)
    }
    state.sessions = [
      "endedLongAgo": session("endedLongAgo", 1, at(40), at(31)),
      "endedRecently": session("endedRecently", 1, at(10), at(5)),
      "deadAndOld": session("deadAndOld", 2, at(31), nil), // crashed: never ended, process gone
      "deadButRecent": session("deadButRecent", 2, at(3), nil),
      "liveAndOld": session("liveAndOld", 1, at(60), nil),
    ]
    state.told = ["endedLongAgo": ["topics": ["a"]], "liveAndOld": ["topics": ["b"]], "unknown": ["topics": ["c"]]]
    let print = Fingerprint(entries: ["a": .init(status: ".M", size: 1, mtime: 1, hash: "h")])
    state.fingerprints = ["/w": print, "/gone": print]
    state.authors = ["/w": ["a": .init(hash: "h", author: .outside)], "/gone": ["a": .init(hash: "h", author: .outside)]]
    state.prune(before: at(30), alive: { $0 == 1 }, exists: { $0 == "/w" })
    #expect(Set(state.sessions.keys) == ["endedRecently", "deadButRecent", "liveAndOld"])
    #expect(Set(state.told.keys) == ["liveAndOld"])
    #expect(Array(state.fingerprints.keys) == ["/w"])
    #expect(Array(state.authors.keys) == ["/w"])
  }

  @Test func decodesAStateFileWithoutTheNewerFields() throws {
    // Only the repository and a session, plus an open call in an older shape: the rest falls back to empty.
    let json = """
    {"repo":"/r/.git","sessions":{"s1":{"id":"s1","worktree":"/w","started":"2026-10-01T10:00:00Z"}},
     "open":{"t1":{"session":"s1","worktree":"/w","before":{"entries":{},"tooMany":false},
                   "started":"2026-10-01T10:00:00Z","overlapped":[]}},
     "somethingNewer":42}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let state = try decoder.decode(TrackState.self, from: Data(json.utf8))
    #expect(state.repo == "/r/.git")
    #expect(state.sessions["s1"]?.worktree == "/w")
    #expect(state.fingerprints.isEmpty)
    #expect(state.authors.isEmpty)
    #expect(state.told.isEmpty)
    #expect(state.pruned == nil)
    #expect(throws: DecodingError.self) { try decoder.decode(TrackState.self, from: Data("{}".utf8)) }
  }

  @Test func prefersTheMostRecentlyStartedOnAReusedPid() {
    let state = state([session("old", pid: 10, started: 1), session("new", pid: 10, started: 5)])
    #expect(state.liveSession(claudePID: 10, alive: { _ in true }) == "new")
  }
}
