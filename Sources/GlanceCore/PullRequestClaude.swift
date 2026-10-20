import Foundation

/// What the PR manager asks Claude about a pull request (spec 2026-10-07-pr-manager-design.md, "Claude"): the read at
/// the top of its page, and Ask Claude's questions answered on the page (spec 2026-10-12-pr-sidebar-tabs-design.md,
/// "Ask Claude"), each one read-only `claude -p`.
public enum PullRequestClaude {
  public struct Failure: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case notInstalled, failed }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
      self.kind = kind
      self.message = message
    }

    public static let notInstalled = Failure(kind: .notInstalled, message: "Claude Code isn't installed or isn't on PATH.")
  }

  public static let readRules = """
    You write the note at the top of a pull request's page in a code review app: Claude's read of the pull request. \
    Write two short paragraphs of plain prose, under 120 words in all. The first says what the pull request does and \
    how. The second starts with "Worth a look:" and names the one thing a reviewer should check most carefully, with \
    the file or function in backticks. No headings, lists, links or greetings. You may read the project's files.
    """

  /// Read-only Claude Code with no hooks or MCP, its answer as one JSON result.
  public static func readArguments() -> [String] {
    ["-p", "--output-format", "json", "--no-session-persistence",
     "--tools", "Read", "Grep", "Glob",
     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config",
     "--append-system-prompt", readRules]
  }

  /// The pull request's title, branches, description, commits and diff; a diff over `limit` characters is cut, and
  /// the prompt says by how much.
  public static func readPrompt(_ page: PullRequestPage.Page, repository: String, diff: String, limit: Int = 60_000) -> String {
    let commits = page.commits.map { "- \($0.shortOid) \($0.headline)" }.joined(separator: "\n")
    let length = diff.count
    let shown = length > limit ? String(diff.prefix(limit)) : diff
    var prompt = """
      Pull request #\(page.number) in \(repository): \(page.title)
      \(page.head) → \(page.base) · \(page.commits.count) commits · +\(page.additions) −\(page.deletions) in \
      \(page.changedFiles) files

      Description:
      \(page.body.isEmpty ? "(none)" : page.body)

      Commits:
      \(commits.isEmpty ? "(none)" : commits)

      Diff:
      \(shown)
      """
    if length > limit {
      prompt += "\n[The diff goes on for \(length - limit) more characters: read the files for the rest.]"
    }
    return prompt
  }

  /// What `result` says when Claude Code printed no answer.
  public static let noAnswer = "Claude Code gave no answer."

  /// `result`, or when Claude Code printed none, the last line it wrote to stderr: why it stopped (not signed in, a
  /// flag it doesn't know, `node` missing).
  public static func result(_ data: Data, errors: Data) -> Result<String, Failure> {
    let parsed = result(data)
    guard case .failure(let failure) = parsed, failure.message == noAnswer,
          let line = String(decoding: errors, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) else { return parsed }
    return .failure(Failure(kind: .failed, message: "Claude Code stopped: \(line)"))
  }

  /// `claude -p --output-format json`: the result's text, or why there is none. Some versions print other lines
  /// first, so the last result line wins.
  public static func result(_ data: Data) -> Result<String, Failure> {
    let text = String(decoding: data, as: UTF8.self)
    let candidates = [text] + text.split(whereSeparator: \.isNewline).reversed().map(String.init)
    for candidate in candidates {
      guard let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any],
            object["type"] as? String == "result" else { continue }
      let answer = (object["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if object["is_error"] as? Bool == true {
        return .failure(Failure(kind: .failed, message: answer.isEmpty ? "Claude Code failed." : answer))
      }
      return answer.isEmpty ? .failure(Failure(kind: .failed, message: noAnswer)) : .success(answer)
    }
    return .failure(Failure(kind: .failed, message: noAnswer))
  }

  // MARK: Ask Claude

  public static let askRules = """
    You answer a question about a pull request in a code review app; the answer shows on the pull request's page. \
    Answer it directly and briefly in Markdown: a few sentences, or a short list when that reads better, with files \
    and functions in backticks. Say so when the diff and the project's files don't tell you. You may read the \
    project's files; change nothing.
    """

  /// Read-only Claude Code with no hooks or MCP, its answer as one JSON result.
  public static func askArguments() -> [String] {
    ["-p", "--output-format", "json", "--no-session-persistence",
     "--tools", "Read", "Grep", "Glob",
     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config",
     "--append-system-prompt", askRules]
  }

  /// What Ask Claude asks with an empty box.
  public static let generalQuestion = "What should I know before merging it?"

  /// A question asked on a pull request's page, and Claude's answer.
  public struct Exchange: Equatable, Sendable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
      self.question = question
      self.answer = answer
    }
  }

  /// Ask Claude about this PR: the pull request as the read gets it (`readPrompt`), what was asked and answered on its
  /// page before (so a follow-up makes sense), and the question, or the general one.
  public static func askPrompt(_ page: PullRequestPage.Page, repository: String, diff: String, earlier: [Exchange] = [],
                               question: String) -> String {
    let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
    var prompt = readPrompt(page, repository: repository, diff: diff)
    if !earlier.isEmpty {
      prompt += "\n\nAsked and answered before:\n"
        + earlier.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
    }
    return prompt + "\n\nQuestion: " + (asked.isEmpty ? generalQuestion : asked)
  }

  /// Fix with Claude: the threads to fix in the project's working tree, each with where it is, who wrote it and what
  /// was said; then the rules: change the files only, with no commit, push, reply or resolve (Glance shows the change
  /// for the user to accept or reject).
  public static func fixPrompt(_ threads: [ReviewThreads.Thread], number: Int, title: String,
                               repository: String) -> String {
    let what = threads.count == 1 ? "this review comment" : "these \(threads.count) review comments"
    var lines = ["Fix \(what) on pull request #\(number) in \(repository), \"\(title)\", in this working tree."]
    for (index, thread) in threads.enumerated() {
      lines.append("")
      lines.append("\(index + 1). \(fixPlace(thread)), from \(thread.comments.first?.author ?? "a reviewer"):")
      for (position, comment) in thread.comments.enumerated() {
        if position > 0 { lines.append("   \(comment.author) replied:") }
        lines += comment.body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
          .map { "   " + $0 }
      }
    }
    lines += ["", "Change the files in this working tree only. Don't commit, push, reply on GitHub or resolve "
      + "anything: Glance shows the user your changes to accept or reject. If a comment needs no change, say so and "
      + "leave the files alone."]
    return lines.joined(separator: "\n")
  }

  /// "scripts/release.sh, line 123", "docs/testing.md, lines 12–14", "README.md (the whole file)".
  static func fixPlace(_ thread: ReviewThreads.Thread) -> String {
    if thread.isFileLevel { return "\(thread.path) (the whole file)" }
    guard let line = thread.line ?? thread.originalLine else { return thread.path }
    if let start = thread.startLine, start != line { return "\(thread.path), lines \(start)–\(line)" }
    return "\(thread.path), line \(line)"
  }

  // MARK: Reply drafts

  /// A reply draft's rules (spec: "reply drafts for threads waiting on the user").
  public static let draftRules = """
    You draft a reply in a code review app, for the user to edit and send as their own. Write only the reply's text: \
    one to three short sentences of plain prose, in the first person, answering the last comment directly and \
    specifically. If it asks for a change, say whether and how you'll make it. No greetings, sign-offs, headings, \
    lists or quotes of the comment. You may read the project's files; change nothing.
    """

  /// Read-only Claude Code with no hooks or MCP, its draft as one JSON result.
  public static func draftArguments() -> [String] {
    ["-p", "--output-format", "json", "--no-session-persistence",
     "--tools", "Read", "Grep", "Glob",
     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config",
     "--append-system-prompt", draftRules]
  }

  /// A reply draft for `viewer`: the pull request, where the thread is, the code it was written on (its diff hunk, when
  /// there is one), and what each person said, in order. With `notes` (what the user typed in the reply box before
  /// Write with Claude), the reply is written from them.
  public static func draftPrompt(_ thread: ReviewThreads.Thread, number: Int, title: String, repository: String,
                                 viewer: String, hunk: String?, notes: String? = nil) -> String {
    var lines = ["Draft \(viewer)'s reply to this review thread on pull request #\(number) in \(repository), "
      + "\"\(title)\". It's on \(fixPlace(thread))."]
    if let hunk = hunk?.trimmingCharacters(in: .whitespacesAndNewlines), !hunk.isEmpty {
      lines += ["", "The code it was written on:", "```diff", hunk, "```"]
    }
    for comment in thread.comments {
      lines += ["", "\(comment.author) wrote:"]
      lines += comment.body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        .map { "   " + $0 }
    }
    if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
      lines += ["", "\(viewer)'s notes for the reply. Write the reply from them: keep what they say and decide, in "
        + "their words where you can, and add only what makes it clear:"]
      lines += notes.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { "   " + $0 }
    }
    return lines.joined(separator: "\n")
  }

  /// The diff hunk a review comment was written on, from the REST API (`commentID` is its REST id, the GraphQL
  /// `databaseId`).
  public static func hunkArguments(repository: String, commentID: Int) -> [String] {
    ["api", "repos/\(repository)/pulls/comments/\(commentID)", "--jq", ".diff_hunk"]
  }

  // MARK: The pull request draft

  /// The rules for Claude's draft of a new pull request (spec: "the PR draft").
  public static let prDraftRules = """
    You draft a pull request in a code review app: its title and its description, from the branch's commits and \
    diff. Answer in exactly this shape: a first line "TITLE: " and the title (under 72 characters, imperative, no \
    trailing period); a blank line; then the description in GitHub Markdown. When a pull request template is given, \
    fill in its sections; otherwise use "## What" (the changes, as short bullets) and "## How to test". No greetings \
    and nothing about yourself. You may read the project's files; change nothing.
    """

  /// Read-only Claude Code with no hooks or MCP, its draft as one JSON result.
  public static func prDraftArguments() -> [String] {
    ["-p", "--output-format", "json", "--no-session-persistence",
     "--tools", "Read", "Grep", "Glob",
     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config",
     "--append-system-prompt", prDraftRules]
  }

  /// The branch to describe: where it merges, its commits as git lists them (newest first), the repository's template
  /// when there is one, and the diff, cut at `limit` characters (the prompt says by how much).
  public static func prDraftPrompt(branch: String, base: String, repository: String, commits: [String], diff: String,
                                   template: String?, limit: Int = 60_000) -> String {
    var lines = ["Draft the pull request for \(branch) → \(base) in \(repository).", "", "Commits (newest first):"]
    lines += commits.isEmpty ? ["(none)"] : commits.map { "- \($0)" }
    if let template = template?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty {
      lines += ["", "The repository's pull request template:", template]
    }
    lines += ["", "Diff:", diff.count > limit ? String(diff.prefix(limit)) : diff]
    if diff.count > limit {
      lines.append("[The diff goes on for \(diff.count - limit) more characters: read the files for the rest.]")
    }
    return lines.joined(separator: "\n")
  }

  /// Claude's draft: "TITLE: …", a blank line, then the description (anything before the TITLE line goes). Without the
  /// TITLE line, the title is empty and the description is the whole answer.
  public static func prDraft(_ answer: String) -> (title: String, body: String) {
    var lines = answer.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("title:") })
    else { return ("", answer.trimmingCharacters(in: .whitespacesAndNewlines)) }
    let title = lines[index].trimmingCharacters(in: .whitespaces).dropFirst("title:".count)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*").union(.whitespaces))
    lines.removeSubrange(...index)
    return (title, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Where GitHub looks for a pull request template, in its order.
  public static let templatePaths = [
    ".github/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE.md", "pull_request_template.md",
    "PULL_REQUEST_TEMPLATE.md", "docs/pull_request_template.md", "docs/PULL_REQUEST_TEMPLATE.md",
  ]

  /// The project's pull request template, if it has one. `read` gives one of the project's files, or nil.
  public static func template(_ read: (String) -> String?) -> String? {
    for path in templatePaths {
      if let text = read(path) { return text }
    }
    return nil
  }

  /// The note under a drafted description (board 3).
  public static func draftNote(commits: Int) -> String {
    "Drafted by Claude from \(commits) \(commits == 1 ? "commit" : "commits") and the diff. Edit anything; Claude "
      + "won't overwrite your changes."
  }
}
