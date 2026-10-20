import AppKit
import GlanceCore

/// GitHub notifications into the Notifications inbox (spec 2026-10-09-notifications-design.md, "Sources → GitHub"):
/// polls `gh api notifications` every minute (or GitHub's X-Poll-Interval when larger) and on wake, posts each thread
/// updated since it was last seen, and marks a thread read on GitHub when it's read or done in Glance. Without `gh`,
/// signed out or offline it pauses and retries after 1, 2, 5, then every 10 minutes.
@MainActor
public final class GitHubNoticeSource {
  public static let shared = GitHubNoticeSource()

  /// The signed-in login (`gh api user`), read once; the user's own comments are no notices.
  public var me: String?
  /// Whether to poll at all (Studio: the Notifications feature switch). Off, a tick only reports `.off`.
  public var isEnabled: () -> Bool = { true }

  private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard
  private static let seenKey = "githubNoticeSeen"
  private static let seenLimit = 500
  private static let backoff: [TimeInterval] = [60, 120, 300, 600]

  private var hub: NotificationHub { .shared }
  /// Every gh run, in order: a private serial queue, never a global one.
  private let queue = DispatchQueue(label: "dev.glance.GitHubNoticeSource", qos: .utility)
  private var started = false
  private var polling = false
  private var failures = 0
  private var timer: Timer?
  private var wakeObserver: NSObjectProtocol?

  private init() {}

  /// Starts polling and the read-sync; only once.
  public func start() {
    guard !started else { return }
    started = true
    let settled = hub.onThreadSettled
    hub.onThreadSettled = { [weak self] notice in
      settled?(notice)
      self?.markReadOnGitHub(notice)
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollNow() }
    }
    pollNow()
  }

  /// Polls now (a poll in flight is left to finish); the next one is scheduled when it ends.
  public func pollNow() {
    guard started, !polling else { return }
    timer?.invalidate()
    guard isEnabled() else {
      hub.setStatus(.off, for: .github)
      return schedule(after: Self.backoff[0])
    }
    polling = true
    let gh = PullRequests.executable(), me = self.me, seen = Self.loadSeen()
    queue.async { [weak self] in
      let result = Self.fetch(gh: gh, me: me, seen: seen)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.finish(result) }
      }
    }
  }

  // MARK: Polling

  private struct Poll: Sendable {
    var me: String
    var interval: TimeInterval?
    var notices: [Notice]
    /// Thread id → updated_at seconds, for every thread this poll handled.
    var seen: [String: TimeInterval]
  }

  /// One poll, off the main thread: who the user is (once), the unread threads, and for each new one its latest
  /// comment.
  nonisolated private static func fetch(gh: String?, me known: String?, seen: [String: TimeInterval])
    -> Result<Poll, PullRequests.Failure> {
    var me = known ?? ""
    if known == nil {
      switch GitHubCLI.run(gh, ["api", "user", "--jq", ".login"]) {
      case .failure(let failure): return .failure(failure)
      case .success(let data):
        me = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    let response: Data
    switch GitHubCLI.run(gh, GitHubNotices.listArguments()) {
    case .failure(let failure): return .failure(failure)
    case .success(let data): response = data
    }
    let (headers, body) = GitHubNotices.splitResponse(response)
    var poll = Poll(me: me, interval: GitHubNotices.pollInterval(headers: headers), notices: [], seen: [:])
    for thread in GitHubNotices.threads(body) {
      let updated = thread.updatedAt.timeIntervalSince1970
      if let last = seen[thread.id], last >= updated { continue }
      poll.seen[thread.id] = updated
      // Only a comment URL is a comment: GitHub also points `latest_comment_url` at the PR or issue itself.
      let comment = thread.latestCommentURL.map(GitHubNotices.apiPath)
        .flatMap { $0.contains("/comments/") ? $0 : nil }
        .flatMap { try? GitHubCLI.run(gh, ["api", $0]).get() }
        .flatMap(GitHubNotices.comment)
      if let notice = GitHubNotices.notice(thread, comment: comment, me: me.isEmpty ? nil : me) {
        poll.notices.append(notice)
      }
    }
    return .success(poll)
  }

  private func finish(_ result: Result<Poll, PullRequests.Failure>) {
    polling = false
    switch result {
    case .success(let poll):
      failures = 0
      if !poll.me.isEmpty { me = poll.me }
      Self.remember(poll.seen)
      hub.setStatus(.running, for: .github)
      // Oldest first, so a thread's newest notice is posted last. A thread updated more than 10 minutes ago (the
      // first poll after launch, catching up after sleep) lands in the inbox without a nudge: its date is its
      // updated_at and NudgeRules never nudges a stale notice.
      if isEnabled() { poll.notices.sorted { $0.date < $1.date }.forEach(hub.post) }
      schedule(after: max(60, poll.interval ?? 60))
    case .failure(let failure):
      let reason: String
      switch failure {
      case .signedOut: reason = "Sign in to GitHub"
      case .notInstalled: reason = "Install the GitHub CLI"
      default: reason = "Offline"
      }
      hub.setStatus(.paused(reason), for: .github)
      schedule(after: Self.backoff[min(failures, Self.backoff.count - 1)])
      failures += 1
    }
  }

  private func schedule(after seconds: TimeInterval) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollNow() }
    }
  }

  // MARK: Read-sync

  /// A GitHub thread read or done in Glance is marked read on GitHub too; failures are ignored.
  private func markReadOnGitHub(_ notice: Notice) {
    guard notice.source == .github, let thread = notice.meta["thread"], !thread.isEmpty,
          let gh = PullRequests.executable() else { return }
    queue.async {
      _ = GitHubCLI.run(gh, GitHubNotices.markReadArguments(threadID: thread))
    }
  }

  // MARK: Seen threads

  private static func loadSeen() -> [String: TimeInterval] {
    defaults.dictionary(forKey: seenKey) as? [String: TimeInterval] ?? [:]
  }

  /// Adds `fresh` to the seen map, keeping the newest 500 threads.
  private static func remember(_ fresh: [String: TimeInterval]) {
    guard !fresh.isEmpty else { return }
    var seen = loadSeen()
    seen.merge(fresh) { max($0, $1) }
    if seen.count > seenLimit {
      let newest = seen.sorted { $0.value > $1.value }.prefix(seenLimit)
      seen = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
    defaults.set(seen, forKey: seenKey)
  }
}
