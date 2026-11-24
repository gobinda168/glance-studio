import Foundation

/// Turns two fingerprints into a ledger record (spec §1): a tool call's change is its session's, or ambiguous when
/// another session's call overlapped it; a change seen while no call ran is outside Claude. Only paths still
/// uncommitted are recorded: a commit or a revert isn't a change to show. Only content counts: staging, touching or
/// rewriting a file unchanged leaves it with its author. Nothing is recorded across a fingerprint with too many files:
/// what changed meanwhile is unknown.
public enum ChangeAttribution {
  public static func outside(last: Fingerprint?, now: Fingerprint, openThere: [TrackState.OpenCall],
                             worktree: String, branch: String?, at time: Date) -> LedgerRecord? {
    guard openThere.isEmpty, let last, !last.tooMany, !now.tooMany else { return nil }
    let files = files(last.changedContent(to: now), in: now)
    return files.isEmpty ? nil : LedgerRecord(t: time, kind: .outside, worktree: worktree, branch: branch, files: files)
  }

  public static func call(_ call: TrackState.OpenCall, tool: String?, after: Fingerprint, branch: String?,
                          at time: Date) -> LedgerRecord? {
    guard let before = call.hashes, !after.tooMany else { return nil }
    let files = files(Fingerprint.changed(from: before, to: after.hashes), in: after)
    guard !files.isEmpty else { return nil }
    let others = Set(call.overlapped).subtracting([call.session]).sorted()
    guard !others.isEmpty else {
      return LedgerRecord(t: time, kind: .change, worktree: call.worktree, session: call.session, branch: branch,
                          tool: tool, files: files)
    }
    return LedgerRecord(t: time, kind: .ambiguous, worktree: call.worktree, sessions: [call.session] + others,
                        branch: branch, tool: tool, files: files)
  }

  static func files(_ paths: [String], in print: Fingerprint) -> [LedgerRecord.File] {
    paths.compactMap { path in
      print.entries[path].map { LedgerRecord.File(path: path, status: $0.status, hash: $0.hash) }
    }
  }
}
