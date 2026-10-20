import Combine
import Foundation
import GlanceCore

/// What the quick-reply panel shows and does for one notice (spec 2026-10-09-notifications-design.md, "Quick-reply
/// panel"): the thread around it, the AI chips' streamed answer, and the composer's Send. Each step switches on the
/// notice's source: GitHub reads and replies through `gh`; Slack reads, thinks and replies only through `claude` with the
/// user's Slack MCP connector (each run allowed only the Slack tools its step needs, every other Slack tool denied).
/// Nothing is ever sent except by `send()`, which only the Send button calls.
@MainActor
public final class QuickReplyModel: ObservableObject {
  public enum SendResult: Equatable, Sendable {
    case sent
    case failed(String)
  }

  public let notice: Notice
  /// The conversation, oldest first.
  @Published public private(set) var thread: [QuickReply.Message] = []
  @Published public private(set) var loading = false
  /// Why the thread is only what the notice said (a muted line under it), or nil.
  @Published public private(set) var threadNote: String?
  /// "path/to/File.swift:42" for a review comment.
  @Published public private(set) var location: String?

  /// The streamed answer of the last AI chip.
  @Published public private(set) var aiText = ""
  /// The chip whose answer `aiText` is (it stays after the run ends).
  @Published public private(set) var aiAction: QuickReply.Action?
  @Published public private(set) var aiRunning: QuickReply.Action?
  /// The tool Claude is using right now ("Using slack_read_thread…"), Slack only.
  @Published public private(set) var aiTool: String?
  @Published public private(set) var aiError: String?

  @Published public var draft = ""
  @Published public private(set) var sending = false
  @Published public private(set) var sendResult: SendResult?
  /// Bumped when the composer should take the keyboard (a draft just landed in it).
  @Published public private(set) var focusRequest = 0
  /// The composer's text before the last "Ask Claude" or dictation changed it, for Undo; nil until one of those changes it.
  @Published public private(set) var undoDraft: String?
  /// "Ask Claude" is rewriting the composer's text.
  public var refining: Bool { aiRunning == .refine }

  /// fn is held to dictate into the composer: listening (with the words so far), then making them out.
  @Published public private(set) var listening = false
  @Published public private(set) var partial: String?
  @Published public private(set) var transcribing = false
  @Published public private(set) var voiceError: String?

  /// Send went through: the panel shows "Sent" and closes.
  var onSent: (() -> Void)?

  /// Every gh run, in order: a private serial queue, never a global one.
  private static let queue = DispatchQueue(label: "dev.glance.QuickReply", qos: .userInitiated)
  private var run: ClaudeOneShot.Run?
  private var loaded = false
  /// GitHub: the comment Send replies to (in its review thread), or nil for a PR/issue comment.
  private var comment: GitHubNotices.Comment?
  /// Slack: the message found in Slack (its channel, ts and thread), once the resolve run found it.
  private var slack: QuickReply.SlackThread?
  /// Slack: what resolve runs found, by notice id, for the run of the app (opening the panel again doesn't re-run).
  private static var slackFound: [String: QuickReply.SlackThread] = [:]
  private var resolveRun: ClaudeOneShot.Run?
  private var probeWatch: AnyCancellable?
  /// Slack: Send was pressed before the message was found; it goes once the resolve run ends.
  private var pendingSend: String?

  public init(notice: Notice) {
    self.notice = notice
  }

  // MARK: The thread

  /// Fetches the thread once; the panel calls it when it opens.
  public func load() {
    guard !loaded else { return }
    loaded = true
    switch notice.source {
    case .github: loadGitHub()
    case .slack: loadSlack()
    default:
      thread = [QuickReply.Message(author: notice.title, text: notice.preview, ts: nil)]
    }
  }

  // MARK: AI chips

  /// Runs a chip (a running one is stopped first). Streams into `aiText`; Draft reply ends in the composer.
  public func run(_ action: QuickReply.Action) {
    stop()
    aiAction = action
    aiRunning = action
    aiText = ""
    aiError = nil
    aiTool = nil
    let prompt = QuickReply.prompt(action, notice: notice, thread: thread, canReadSlack: canReadSource)
    let tools = aiTools
    run = ClaudeRunner.run(prompt: prompt, tools: tools, disallowed: slackDisallowed(allowing: tools),
                           model: nil) { [weak self] event in
      self?.handle(event, for: action)
    }
  }

  /// "Ask Claude" under the composer: applies `instruction` to what's in the composer (or writes it, when empty). The
  /// result replaces the composer's text once it is whole; nothing is sent.
  public func refine(_ instruction: String) {
    let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !instruction.isEmpty, !sending, sendResult != .sent else { return }
    stop()
    aiAction = .refine
    aiRunning = .refine
    aiText = ""
    aiError = nil
    aiTool = nil
    let prompt = QuickReply.refinePrompt(notice: notice, thread: thread, draft: draft, instruction: instruction,
                                         canReadSlack: canReadSource)
    let tools = aiTools
    run = ClaudeRunner.run(prompt: prompt, tools: tools, disallowed: slackDisallowed(allowing: tools),
                           model: nil) { [weak self] event in
      self?.handle(event, for: .refine)
    }
  }

  /// Puts the composer's text back as it was before Claude or dictation changed it.
  public func undo() {
    guard let undoDraft else { return }
    draft = undoDraft
    self.undoDraft = nil
    focusRequest += 1
  }

  /// Stops a running chip; what streamed so far stays.
  public func stop() {
    guard aiRunning != nil else { return }
    run?.cancel()
    run = nil
    aiRunning = nil
    aiTool = nil
    if aiText.isEmpty { aiAction = nil }
  }

  /// Whether the AI may read the source itself (Slack's read tools); GitHub's thread is all in the prompt.
  private var canReadSource: Bool {
    switch notice.source {
    case .slack: slackStatus.map { !$0.readTools.isEmpty } ?? false
    default: false
    }
  }

  /// MCP tools an AI chip may use: Slack's read tools for a Slack notice, none otherwise.
  private var aiTools: [String] {
    switch notice.source {
    case .slack: slackStatus?.readTools ?? []
    default: []
    }
  }

  private func handle(_ event: ClaudeRunner.Event, for action: QuickReply.Action) {
    guard aiRunning == action else { return }
    switch event {
    case .text(let piece):
      // A rewrite lands whole, in the composer; it isn't shown as it streams.
      if action != .refine { aiText += piece }
      aiTool = nil
    case .tool(let name):
      aiTool = name
    case .done(let answer):
      run = nil
      aiRunning = nil
      aiTool = nil
      let text = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? aiText : answer
      if action == .refine {
        let rewritten = QuickReply.draftText(text)
        if rewritten.isEmpty {
          aiError = "Claude didn't give a reply. Try again."
        } else {
          undoDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft
          draft = rewritten
          sendResult = nil
          focusRequest += 1
        }
        aiText = ""
        aiAction = nil
      } else if action == .draft {
        placeDraft(QuickReply.draftText(text))
        // The draft now lives in the composer; the answer area folds away.
        aiText = ""
        aiAction = nil
      } else {
        aiText = text.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    case .failed(let message):
      run = nil
      aiRunning = nil
      aiTool = nil
      aiError = message
    }
  }

  /// Into an empty composer as is; under what's there after a blank line.
  private func placeDraft(_ text: String) {
    guard !text.isEmpty else { return }
    let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = current.isEmpty ? text : current + "\n\n" + text
    sendResult = nil
    focusRequest += 1
  }

  // MARK: Dictation

  func voiceBegan() {
    voiceError = nil
    partial = nil
    transcribing = false
    listening = true
  }

  func voiceHeard(_ words: String) { partial = words }

  func voiceTranscribing() {
    listening = false
    partial = nil
    transcribing = true
  }

  /// The words land at the end of the composer (a space or a new line between); the user reads them before Send.
  func voiceFinished(_ words: String) {
    voiceStopped()
    let spoken = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spoken.isEmpty, !sending, sendResult != .sent else { return }
    undoDraft = draft
    let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = current.isEmpty ? spoken : current + " " + spoken
    focusRequest += 1
  }

  func voiceFailed(_ message: String) {
    voiceStopped()
    voiceError = message.isEmpty ? nil : message
  }

  private func voiceStopped() {
    listening = false
    partial = nil
    transcribing = false
  }

  // MARK: Send

  public var canSend: Bool {
    !sending && !refining && sendResult != .sent && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Sends the composer's text as a reply. Only the Send button (or ⌘↩) calls this.
  public func send() {
    guard canSend else { return }
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    sending = true
    sendResult = nil
    switch notice.source {
    case .github: sendGitHub(text)
    case .slack: sendSlack(text)
    default:
      finishSend(.failed("Replies from here aren't available for \(notice.source.title) yet"))
    }
  }

  private func finishSend(_ result: SendResult) {
    sending = false
    sendResult = result
    guard result == .sent else { return }
    let hub = NotificationHub.shared
    if let row = hub.book.rows(filter: notice.source, showDone: true).first(where: { $0.id == notice.threadKey }) {
      hub.markRead(row)
    }
    onSent?()
  }

  /// Stops anything still running (the panel closed). A send already under way finishes (or the resolve run it waits
  /// for, then the send): ending `claude` mid-post would leave it unknown whether the reply went.
  func cancel() {
    stop()
    probeWatch = nil
    if pendingSend == nil {
      resolveRun?.cancel()
      resolveRun = nil
    }
    onSent = nil
  }

  // MARK: Slack

  private static let slackSendFailure = "Couldn't send. Copy it, or open it in Chats."
  private static let slackNotConnected =
    "Claude Code doesn't have your Slack connector, so Glance can't post. Copy it, or open it in Chats."
  private static let slackChecking = "Still checking Claude Code's Slack connection. Try Send again in a moment."
  private static let slackConnecting = "Slack is still connecting in Claude Code. Try Send again in a moment."

  /// Why a Slack send can't go, in words: no connector, a check still running, or the send itself failing.
  private var slackFailure: String {
    if slackStatus != nil { return Self.slackSendFailure }
    if SlackMCPProbe.shared.checking { return Self.slackChecking }
    return SlackMCPProbe.shared.status?.pending == true ? Self.slackConnecting : Self.slackNotConnected
  }

  /// The Slack connector, when Claude Code has it.
  private var slackStatus: SlackMCP.Status? {
    guard let status = SlackMCPProbe.shared.status, status.connected else { return nil }
    return status
  }

  /// Every Slack tool but `allowed`, for `--disallowedTools` (empty for a run that isn't Slack's).
  private func slackDisallowed(allowing allowed: [String]) -> [String] {
    guard notice.source == .slack else { return [] }
    return slackStatus?.disallowed(allowing: allowed) ?? []
  }

  /// What Glance caught: this notification and the others of its thread, oldest first.
  private var capturedSlackMessages: [QuickReply.Message] {
    let others = NotificationHub.shared.book.notices.filter { $0.threadKey == notice.threadKey && $0.id != notice.id }
    return (others + [notice]).sorted { $0.date < $1.date }.map {
      QuickReply.Message(author: $0.title, text: $0.preview, ts: Self.iso($0.date))
    }
  }

  /// Shows what Glance caught, then asks Claude (haiku, the Slack read tools) to find the message and its thread.
  private func loadSlack() {
    thread = capturedSlackMessages
    // The panel may open before the connector check has ever run, or after one that found no Slack (the answer is
    // kept for the run of the app, and the user may have connected Slack since): check, and read the thread after.
    let probe = SlackMCPProbe.shared
    if probe.status?.connected != true {
      probeWatch = probe.$status.dropFirst().first { $0 != nil }.sink { [weak self] _ in
        self?.probeWatch = nil
        self?.loadedSlack()
      }
      probe.check(force: probe.status != nil)
      return
    }
    loadedSlack()
  }

  private func loadedSlack() {
    if let found = Self.slackFound[notice.id] {
      slack = found
      if !found.messages.isEmpty { thread = found.messages }
      return
    }
    resolveSlack()
  }

  private func resolveSlack() {
    guard let status = slackStatus, !status.readTools.isEmpty else { return finishResolve(nil) }
    loading = true
    resolveRun = ClaudeRunner.run(prompt: QuickReply.resolvePrompt(notice), tools: status.readTools,
                                  disallowed: status.disallowed(allowing: status.readTools),
                                  model: "haiku") { event in
      // Held until the run ends, so a Send waiting on it still goes after the panel closes.
      switch event {
      case .done(let answer): self.finishResolve(QuickReply.slackThread(from: answer))
      case .failed: self.finishResolve(nil)
      case .text, .tool: break
      }
    }
  }

  private func finishResolve(_ found: QuickReply.SlackThread?) {
    resolveRun = nil
    loading = false
    if let found {
      slack = found
      Self.slackFound[notice.id] = found
      if !found.messages.isEmpty { thread = found.messages }
      threadNote = nil
    } else {
      threadNote = slackStatus == nil
        ? "Slack isn't connected in Claude Code, so this is what the notification said."
        : "Couldn't find the thread in Slack. Summarise uses what's here."
    }
    guard let text = pendingSend else { return }
    pendingSend = nil
    if found != nil { postSlack(text) } else { finishSend(.failed(slackFailure)) }
  }

  /// Sends once the message is known (finding it first when the resolve run hasn't, or is still looking).
  private func sendSlack(_ text: String) {
    if slack != nil { return postSlack(text) }
    pendingSend = text
    // A connector check under way reads the thread when it ends, and that sends.
    if probeWatch == nil && resolveRun == nil { resolveSlack() }
  }

  /// One `claude` run (haiku) allowed only the Slack send tool: post `text` unchanged as a reply in the thread.
  private func postSlack(_ text: String) {
    guard let slack, let status = slackStatus, !status.sendTools.isEmpty else {
      return finishSend(.failed(slackFailure))
    }
    ClaudeRunner.run(prompt: QuickReply.sendPrompt(text: text, channel: slack.channel, threadTS: slack.replyTS),
                     tools: status.sendTools, disallowed: status.disallowed(allowing: status.sendTools),
                     model: "haiku") { event in
      // Held until the run ends: a reply that went is marked read even when the panel closed meanwhile.
      switch event {
      case .done(let answer):
        self.finishSend(QuickReply.sent(from: answer).ok ? .sent : .failed(Self.slackSendFailure))
      case .failed:
        self.finishSend(.failed(Self.slackSendFailure))
      case .text, .tool: break
      }
    }
  }

  // MARK: GitHub

  private struct GitHubTarget: Sendable {
    let repository: String
    let number: Int
    let isPullRequest: Bool
  }

  private var githubTarget: GitHubTarget? {
    switch notice.target {
    case .pullRequest(let repository, let number, _, _):
      GitHubTarget(repository: repository, number: number, isPullRequest: true)
    case .issue(let repository, let number):
      GitHubTarget(repository: repository, number: number, isPullRequest: false)
    default: nil
    }
  }

  /// The comment as the notice remembers it (`meta`): enough to reply in its review thread when gh can't fetch it.
  private var rememberedComment: GitHubNotices.Comment? {
    guard let id = notice.meta["comment"].flatMap(Int.init) else { return nil }
    var path: String?, line: Int?
    if case .pullRequest(_, _, let file, let row) = notice.target {
      path = file
      line = row
    }
    return GitHubNotices.Comment(id: id, author: notice.title, body: notice.preview, avatarURL: notice.avatarURL,
                                 path: path, line: line, inReplyTo: notice.meta["inReplyTo"].flatMap(Int.init),
                                 isReview: notice.meta["isReview"] == "1", createdAt: notice.date)
  }

  private struct GitHubThread: Sendable {
    var comment: GitHubNotices.Comment?
    var comments: [GitHubNotices.Comment]
    var failure: PullRequests.Failure?
  }

  private func loadGitHub() {
    let remembered = rememberedComment
    comment = remembered
    location = Self.location(remembered)
    guard let target = githubTarget else {
      thread = [QuickReply.Message(author: notice.title, text: notice.preview, ts: nil)]
      return
    }
    loading = true
    let gh = PullRequests.executable()
    Self.queue.async { [weak self] in
      let result = Self.fetchThread(gh: gh, target: target, remembered: remembered)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.finishLoad(result) }
      }
    }
  }

  /// The comment again (its body may have been edited, and the notice keeps only one line of it), then its thread.
  nonisolated private static func fetchThread(gh: String?, target: GitHubTarget, remembered: GitHubNotices.Comment?)
    -> GitHubThread {
    var comment = remembered
    var failure: PullRequests.Failure?
    if let remembered {
      let kind = remembered.isReview ? "pulls" : "issues"
      switch GitHubCLI.run(gh, ["api", "repos/\(target.repository)/\(kind)/comments/\(remembered.id)"]) {
      case .success(let data): comment = GitHubNotices.comment(data) ?? remembered
      case .failure(let error): failure = error
      }
    }
    // A review thread lives in the PR's review comments; everything else in the conversation.
    let isReview = target.isPullRequest && comment?.isReview == true
    switch GitHubCLI.run(gh, GitHubNotices.threadArguments(repository: target.repository, number: target.number,
                                                           isReview: isReview)) {
    case .success(let data):
      let comments = GitHubNotices.threadComments(data, around: comment, isReview: isReview)
      return GitHubThread(comment: comment, comments: comments, failure: nil)
    case .failure(let error):
      return GitHubThread(comment: comment, comments: [], failure: failure ?? error)
    }
  }

  private func finishLoad(_ result: GitHubThread) {
    loading = false
    comment = result.comment
    location = Self.location(result.comment)
    var comments = result.comments
    if comments.isEmpty, let comment = result.comment { comments = [comment] }
    thread = comments.map { QuickReply.Message(author: $0.author, text: $0.body, ts: $0.createdAt.map(Self.iso)) }
    if let failure = result.failure {
      threadNote = Self.message(failure) + ". Showing what the notification said."
      if thread.isEmpty { thread = [QuickReply.Message(author: notice.title, text: notice.preview, ts: nil)] }
    } else if thread.isEmpty {
      threadNote = "No comments yet."
    }
  }

  private func sendGitHub(_ text: String) {
    guard let target = githubTarget else { return finishSend(.failed("This notification has nothing to reply to")) }
    // Without a comment (a review request, say) the reply is a PR or issue comment.
    let anchor = comment ?? GitHubNotices.Comment(id: 0, author: "", body: "", avatarURL: nil, path: nil, line: nil,
                                                  inReplyTo: nil, isReview: false, createdAt: nil)
    let arguments = GitHubNotices.replyArguments(repository: target.repository, number: target.number,
                                                 comment: anchor, body: text)
    let gh = PullRequests.executable()
    Self.queue.async { [weak self] in
      let result = GitHubCLI.run(gh, arguments)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          switch result {
          case .success: self?.finishSend(.sent)
          case .failure(let failure): self?.finishSend(.failed(Self.message(failure)))
          }
        }
      }
    }
  }

  nonisolated private static func message(_ failure: PullRequests.Failure) -> String {
    switch failure {
    case .signedOut: "Sign in to GitHub first"
    case .notInstalled: "Install the GitHub CLI (gh) first"
    case .notGitHub: "This isn't a GitHub repository"
    case .failed(let reason): reason.isEmpty ? "GitHub didn't take it" : reason
    }
  }

  private static func location(_ comment: GitHubNotices.Comment?) -> String? {
    guard let comment, comment.isReview, let path = comment.path, !path.isEmpty else { return nil }
    return comment.line.map { "\(path):\($0)" } ?? path
  }

  nonisolated private static func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
