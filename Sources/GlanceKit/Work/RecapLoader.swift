import Foundation
import GlanceCore

/// Fills a worktree recap from what already exists: stored summaries, git, the records. Runs no Claude. Blocking: it
/// reads files and runs git and `gh`, so never call it on the main thread.
public enum RecapLoader {
  public struct Input: Sendable {
    public var worktree: String, exists: Bool, branch: String?, main: String?, sessions: [String], title: String, pr: BoardPR?
    /// Sessions already left out of `sessions` as older (a reload passes the recap's own count back).
    public var older: Int
    public init(worktree: String, exists: Bool, branch: String?, main: String?, sessions: [String], title: String, pr: BoardPR?,
                older: Int = 0) {
      self.worktree = worktree; self.exists = exists; self.branch = branch; self.main = main
      self.sessions = sessions; self.title = title; self.pr = pr; self.older = older
    }
  }

  /// What is known quickly (summaries, records, git) goes to `partial` as soon as it is, with `spendPending` set while a
  /// transcript is still to be read; the PR's commits (`gh`, which can be slow) fill in after, and the spend, read from the
  /// transcripts as a stream, comes with the returned recap. When every transcript's spend is already known (read before,
  /// unchanged) and git had the commits there is nothing to wait for and `partial` is not called. Only the newest
  /// `RecapText.sessionsRead` sessions are read; the rest are counted in `older`. `isCancelled` is asked between steps and
  /// during a transcript: a cancelled load returns what it had, with no spend.
  public static func load(_ input: Input, store: WorkStore = WorkStore(),
                          projects: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path,
                          prCommits: (Int, String) -> [WorktreeRecap.Commit] = commitsFromPR,
                          isCancelled: () -> Bool = { false }, partial: (WorktreeRecap) -> Void = { _ in }) -> WorktreeRecap {
    let sessions = Array(input.sessions.prefix(RecapText.sessionsRead))
    var recap = WorktreeRecap(worktree: input.worktree, title: input.title, exists: input.exists)
    recap.branch = input.branch
    recap.main = input.main
    recap.sessions = sessions
    recap.older = input.older + (input.sessions.count - sessions.count)
    recap.pr = input.pr
    let stored = sessions.compactMap { id in SummaryStore.load(id).map { (id, $0) } }
    let summaries = stored.map(\.1)
    let summarized = Set(stored.map(\.0))
    recap.bullets = RecapText.bullets(summaries: summaries)

    let records = sessions.compactMap { store.record(session: $0) }
    recap.lastActive = records.map(\.updated).max()
    if let last = records.max(by: { $0.updated < $1.updated }) {
      let setup = ProofRecords.folder(of: last).flatMap { ProofSetupFile.load(cwd: $0).setup }
      recap.pill = ProofReview.pill(last, setup: setup, facts: ProofFacts(prChecksFailing: input.pr?.checks == .failing, prMerged: input.pr?.merged ?? false))
    }
    if isCancelled() { return recap }

    // git runs where it still can: the worktree, else the main checkout. A deleted branch simply has no log. The base is
    // the remote's default branch and never the current one: against that the log would be empty and say nothing.
    let folder = input.exists ? input.worktree : input.main
    if let folder, let branch = input.branch, !branch.hasPrefix("-"), let base = RepoBase.find(cwd: folder, prBase: nil) {
      recap.commits = RecapText.commits(log: GitRun.text(folder, ["log", "--format=%h%x09%s", "\(base)..\(branch)"], timeout: 10) ?? "")
      let stat = GitRun.text(folder, ["diff", "--numstat", "\(base)...\(branch)"], timeout: 10) ?? ""
      if !stat.isEmpty {
        (recap.added, recap.removed) = WorktreeBook.numstat(stat)
        recap.files = stat.split(separator: "\n").count
      }
    }
    // A removed worktree can be recreated only while its branch exists (it is usually deleted after the merge).
    if !input.exists, let main = input.main, let branch = input.branch, !branch.isEmpty, !branch.hasPrefix("-") {
      recap.branchExists = GitRun.data(main, ["show-ref", "--verify", "--quiet", "refs/heads/" + branch], timeout: 10) != nil
    }
    recap.source = RecapText.source(summaries: summaries, hasCommits: !recap.commits.isEmpty, pr: input.pr?.number)

    // Which sessions still have a transcript, and so a spend to read and a summary to ask for.
    var transcripts: [String] = []
    for id in sessions {
      let folders = [records.first { $0.session == id }?.cwd, input.worktree].compactMap { $0 }
      guard let path = BoardEntries.transcript(session: id, folders: folders, projects: projects) else { continue }
      transcripts.append(path)
      if !summarized.contains(id) { recap.unsummarized.append(id) }
    }
    if isCancelled() { return recap }

    var spend = 0.0
    var known = false
    var unread: [(path: String, stamp: SpendCache.Stamp)] = []
    for path in transcripts {
      let stamp = SpendCache.stamp(path)
      if let cost = SpendCache.cost(path, stamp) { spend += cost; known = true } else { unread.append((path, stamp)) }
    }
    // A merged branch has nothing left in `base..branch` (or no branch at all): its PR still lists the commits. gh can take
    // many seconds, so what is known goes out first and the commits fill in after.
    let prLookup = recap.commits.isEmpty ? input.pr.flatMap { pr in folder.map { (pr.number, $0) } } : nil
    func publishEarly() {
      var early = recap
      // With every transcript's spend already known, it goes with this; otherwise it follows.
      early.spend = unread.isEmpty && known ? spend : nil
      early.spendPending = !unread.isEmpty
      partial(early)
    }
    if !unread.isEmpty || prLookup != nil { publishEarly() }
    if let (number, folder) = prLookup {
      if isCancelled() { return recap }
      recap.commits = prCommits(number, folder)
      recap.source = RecapText.source(summaries: summaries, hasCommits: !recap.commits.isEmpty, pr: input.pr?.number)
      if !unread.isEmpty, !recap.commits.isEmpty { publishEarly() }
    }
    for (path, stamp) in unread {
      if isCancelled() { return recap }
      guard let cost = TranscriptSpend.total(of: URL(fileURLWithPath: path), isCancelled: isCancelled) else { continue }
      SpendCache.store(path, stamp, cost)
      spend += cost
      known = true
    }
    if isCancelled() { return recap }
    recap.spend = known ? spend : nil
    return recap
  }

  /// A transcript's spend by (size, modification time), so reading the recap again after a summary landed reads no
  /// transcript that hasn't grown.
  private enum SpendCache {
    struct Stamp: Equatable {
      var size: Int
      var modified: Date
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: (stamp: Stamp, cost: Double)] = [:]

    static func stamp(_ path: String) -> Stamp {
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      return Stamp(size: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
                   modified: attributes?[.modificationDate] as? Date ?? .distantPast)
    }

    static func cost(_ path: String, _ stamp: Stamp) -> Double? {
      lock.lock(); defer { lock.unlock() }
      guard let entry = entries[path], entry.stamp == stamp else { return nil }
      return entry.cost
    }

    static func store(_ path: String, _ stamp: Stamp, _ cost: Double) {
      lock.lock(); defer { lock.unlock() }
      if entries.count > 2000 { entries.removeAll() }
      entries[path] = (stamp, cost)
    }
  }

  /// A merged branch's commits, from the PR. Empty when gh can't say.
  public static func commitsFromPR(number: Int, folder: String) -> [WorktreeRecap.Commit] {
    guard case .success(let data) = GitHubCLI.run(PullRequests.executable(), ["pr", "view", String(number), "--json", "commits"], folder: folder, timeout: 20) else {
      return []
    }
    return RecapText.commits(prJSON: data)
  }
}
