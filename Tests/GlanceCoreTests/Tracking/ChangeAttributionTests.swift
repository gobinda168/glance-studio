import Foundation
import Testing
@testable import GlanceCore

private func fp(_ pairs: [String: String]) -> Fingerprint {
  Fingerprint(entries: pairs.mapValues { Fingerprint.Entry(status: ".M", size: 1, mtime: 1, hash: $0) })
}

private let t = Date(timeIntervalSince1970: 50)

struct ChangeAttributionTests {
  @Test func aToolCallsChangeIsItsSessions() {
    let call = TrackState.OpenCall(session: "s1", worktree: "/w", hashes: ["a": "1"], started: t)
    let record = ChangeAttribution.call(call, tool: "Edit", after: fp(["a": "2", "b": "1"]), branch: "main", at: t)
    #expect(record?.kind == .change)
    #expect(record?.session == "s1")
    #expect(record?.files?.map(\.path) == ["a", "b"])
  }

  @Test func overlappingSessionsMakeAChangeAmbiguous() {
    let call = TrackState.OpenCall(session: "s1", worktree: "/w", hashes: [:], started: t, overlapped: ["s2"])
    let record = ChangeAttribution.call(call, tool: "Bash", after: fp(["a": "1"]), branch: nil, at: t)
    #expect(record?.kind == .ambiguous)
    #expect(record?.sessions == ["s1", "s2"])
  }

  @Test func committedOrUnchangedFilesAreNotRecorded() {
    // "a" was committed by the call (it left the uncommitted list); nothing else changed.
    let call = TrackState.OpenCall(session: "s1", worktree: "/w", hashes: ["a": "1"], started: t)
    #expect(ChangeAttribution.call(call, tool: "Bash", after: fp([:]), branch: nil, at: t) == nil)
  }

  @Test func stagingOrTouchingAFileIsNotAChange() {
    let before = fp(["a": "1"])
    let staged = Fingerprint(entries: ["a": Fingerprint.Entry(status: "M.", size: 1, mtime: 1, hash: "1")])
    let touched = Fingerprint(entries: ["a": Fingerprint.Entry(status: ".M", size: 1, mtime: 7, hash: "1")])
    for after in [staged, touched] {
      #expect(ChangeAttribution.outside(last: before, now: after, openThere: [], worktree: "/w", branch: nil, at: t) == nil)
      let call = TrackState.OpenCall(session: "s1", worktree: "/w", hashes: before.hashes, started: t)
      #expect(ChangeAttribution.call(call, tool: "Bash", after: after, branch: nil, at: t) == nil)
    }
    // A real edit still counts.
    #expect(ChangeAttribution.outside(last: before, now: fp(["a": "2"]), openThere: [], worktree: "/w", branch: nil,
                                      at: t)?.files?.map(\.path) == ["a"])
  }

  @Test func changesWithNoCallOpenAreOutsideClaude() {
    let outside = ChangeAttribution.outside(last: fp(["a": "1"]), now: fp(["a": "2"]), openThere: [],
                                            worktree: "/w", branch: nil, at: t)
    #expect(outside?.kind == .outside)
    #expect(outside?.files?.first?.hash == "2")
    // A call is running there: its PostToolUse accounts for the change.
    let running = TrackState.OpenCall(session: "s1", worktree: "/w", hashes: [:], started: t)
    #expect(ChangeAttribution.outside(last: fp(["a": "1"]), now: fp(["a": "2"]), openThere: [running],
                                      worktree: "/w", branch: nil, at: t) == nil)
    // The first look at a worktree has nothing to compare with.
    #expect(ChangeAttribution.outside(last: nil, now: fp(["a": "2"]), openThere: [], worktree: "/w", branch: nil,
                                      at: t) == nil)
  }
}
