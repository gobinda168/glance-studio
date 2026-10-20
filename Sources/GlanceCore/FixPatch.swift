import Foundation

/// A fix to review threads, made in the project's working tree by Claude or by applying a suggestion (spec
/// 2026-10-07-pr-manager-design.md, "Claude → Fixes").
/// - Snapshots are trees written from a temporary copy of git's index, so nothing is staged or committed until the user
///   accepts.
/// - Accept commits only the files the fix changed, then pushes.
/// - Reject puts back exactly what the fix changed.
public enum FixPatch {
  /// A file a fix changed between two snapshots.
  public struct Change: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case added, modified, deleted }

    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
      self.path = path
      self.kind = kind
    }
  }

  public static let git = "/usr/bin/git"

  // MARK: git's arguments (run with -C and the project's folder)

  static func indexPathArguments() -> [String] { ["rev-parse", "--git-path", "index"] }

  /// With GIT_INDEX_FILE on a temporary copy of the index: every file, tracked or new (ignored ones aside).
  static func addAllArguments() -> [String] { ["add", "-A"] }

  static func writeTreeArguments() -> [String] { ["write-tree"] }

  static func changesArguments(from: String, to: String) -> [String] {
    ["diff-tree", "-r", "--no-renames", "--name-status", "-z", from, to]
  }

  /// The prefixes are spelled out: `PullRequestDiff.parse` reads a/ and b/, whatever diff.noprefix says.
  static func patchArguments(from: String, to: String) -> [String] {
    ["diff", "--no-color", "--no-ext-diff", "--no-renames", "--src-prefix=a/", "--dst-prefix=b/", from, to]
  }

  /// Stages exactly these paths, new and deleted files too.
  static func addArguments(_ paths: [String]) -> [String] { ["add", "-A", "--"] + paths }

  /// Which of these paths HEAD has (a deleted file only needs committing if it was).
  static func trackedArguments(_ paths: [String]) -> [String] {
    ["ls-tree", "-r", "--name-only", "-z", "HEAD", "--"] + paths
  }

  /// Commits these paths' working-tree content and nothing else, whatever else is staged.
  static func commitArguments(message: String, paths: [String]) -> [String] {
    ["commit", "--only", "-m", message, "--"] + paths
  }

  static func shortHeadArguments() -> [String] { ["rev-parse", "--short", "HEAD"] }

  static func pushArguments() -> [String] { ["push"] }

  /// Puts these paths back in the working tree from `source`, leaving the index alone.
  static func restoreArguments(source: String, paths: [String]) -> [String] {
    ["restore", "--source=\(source)", "--worktree", "--"] + paths
  }

  // MARK: Reading git

  /// `git diff-tree --name-status -z` ("M\0path\0A\0path\0"). A type change counts as modified.
  static func parseChanges(_ output: String) -> [Change] {
    let fields = output.split(separator: "\0").map(String.init)
    var changes: [Change] = []
    var index = 0
    while index + 1 < fields.count {
      let status = fields[index], path = fields[index + 1]
      index += 2
      switch status.first {
      case "A": changes.append(Change(path: path, kind: .added))
      case "D": changes.append(Change(path: path, kind: .deleted))
      default: changes.append(Change(path: path, kind: .modified))
      }
    }
    return changes
  }

  /// `-z` names ("a\0b\0").
  static func names(_ output: String) -> [String] {
    output.split(separator: "\0").map(String.init)
  }

  /// The files both lists changed: the fix also changed a file holding the user's own uncommitted edits.
  static func overlap(user: [Change], claude: [Change]) -> [String] {
    Set(user.map(\.path)).intersection(claude.map(\.path)).sorted()
  }

  /// git's line about what it refused. A push's own "! [rejected] … (fetch first)" comes first, then a fatal: or
  /// error: line, then the first line. A push's stderr starts with "To github.com:…", which says nothing.
  static func failureLine(_ stderr: String) -> String {
    let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return lines.first { $0.hasPrefix("! ") } ?? lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
      ?? lines.first ?? "git failed"
  }

  // MARK: Messages

  /// The commit for Claude's fix of `threads`: what it addresses, one line per thread, and Claude as co-author.
  public static func commitMessage(_ threads: [ReviewThreads.Thread]) -> String {
    let subject = threads.count == 1 ? "Address review: " + headline(threads[0])
      : "Address \(threads.count) review comments"
    let lines = threads.map { "- \(place($0)) (\($0.comments.first?.author ?? "a reviewer")): \(headline($0))" }
    return subject + "\n\n" + lines.joined(separator: "\n") + "\n\nCo-Authored-By: Claude <noreply@anthropic.com>"
  }

  /// The commit for an applied suggestion.
  public static func suggestionMessage(_ thread: ReviewThreads.Thread) -> String {
    "Apply suggestion from \(thread.comments.first?.author ?? "a reviewer") on \(place(thread))"
  }

  /// The reply under each fixed thread.
  public static func reply(sha: String) -> String { "Fixed in \(sha)." }

  /// A thread's first words: its first comment's first line without Markdown's **, at most 60 characters.
  static func headline(_ thread: ReviewThreads.Thread) -> String {
    let body = (thread.comments.first?.body ?? "").replacingOccurrences(of: "\r\n", with: "\n")
    let first = body.split(separator: "\n")
      .map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    return first.count > 60 ? String(first.prefix(59)) + "…" : first
  }

  /// "scripts/release.sh:123", or the path alone for a comment on the file.
  static func place(_ thread: ReviewThreads.Thread) -> String {
    (thread.line ?? thread.originalLine).map { "\(thread.path):\($0)" } ?? thread.path
  }

  // MARK: The working tree (blocking: call off the main thread)

  /// A fix's changes between its two snapshots.
  public struct Fix: Equatable, Sendable {
    /// The trees before and after the fix.
    public let before: String
    public let after: String
    public let changes: [Change]
    /// The changes as a diff, for Fix ready.
    public let patch: [PullRequestDiff.File]
    /// Files the fix changed that already held the user's own uncommitted edits: committing takes those too.
    public let overlap: [String]
  }

  /// A snapshot of the working tree, tracked and untracked files alike (ignored ones aside), as a tree id. It's written
  /// from a temporary copy of git's index, so the index, the files and every branch stay as they were.
  public static func snapshot(root: String) -> Result<String, PullRequests.Failure> {
    let index: String
    switch run(indexPathArguments(), root) {
    case .failure(let failure):
      return .failure(failure)
    case .success(let output):
      let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
      index = path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
    }
    let temporary = (NSTemporaryDirectory() as NSString).appendingPathComponent("glance-fix-\(UUID().uuidString).index")
    defer { try? FileManager.default.removeItem(atPath: temporary) }
    if FileManager.default.fileExists(atPath: index) {
      do {
        try FileManager.default.copyItem(atPath: index, toPath: temporary)
      } catch {
        return .failure(.failed("Couldn't copy git's index."))
      }
    }
    let environment = ["GIT_INDEX_FILE": temporary]
    if case .failure(let failure) = run(addAllArguments(), root, environment: environment) { return .failure(failure) }
    return run(writeTreeArguments(), root, environment: environment)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  /// What changed in the working tree since the snapshot `before`, or nil when nothing did. The user's own uncommitted
  /// edits (HEAD to `before`) aren't in it; files both touched are its overlap.
  public static func collect(root: String, before: String) -> Result<Fix?, PullRequests.Failure> {
    let after: String
    switch snapshot(root: root) {
    case .failure(let failure): return .failure(failure)
    case .success(let tree): after = tree
    }
    if after == before { return .success(nil) }
    let changes: [Change]
    switch run(changesArguments(from: before, to: after), root) {
    case .failure(let failure): return .failure(failure)
    case .success(let output): changes = parseChanges(output)
    }
    if changes.isEmpty { return .success(nil) }
    let patch = (try? run(patchArguments(from: before, to: after), root).get()).map(PullRequestDiff.parse) ?? []
    let user = (try? run(changesArguments(from: "HEAD", to: before), root).get()).map(parseChanges) ?? []
    return .success(Fix(before: before, after: after, changes: changes, patch: patch,
                        overlap: overlap(user: user, claude: changes)))
  }

  /// Commits exactly the fix's files, whatever else is staged, and gives the commit's short id.
  public static func commit(_ fix: Fix, message: String, root: String) -> Result<String, PullRequests.Failure> {
    let present = fix.changes.filter { $0.kind != .deleted }.map(\.path)
    let deleted = fix.changes.filter { $0.kind == .deleted }.map(\.path)
    if !present.isEmpty, case .failure(let failure) = run(addArguments(present), root) { return .failure(failure) }
    var tracked: [String] = []
    if !deleted.isEmpty {
      switch run(trackedArguments(deleted), root) {
      case .failure(let failure): return .failure(failure)
      case .success(let output): tracked = names(output)
      }
    }
    let paths = present + tracked
    guard !paths.isEmpty else { return .failure(.failed("Nothing to commit.")) }
    if case .failure(let failure) = run(commitArguments(message: message, paths: paths), root) {
      return .failure(failure)
    }
    return run(shortHeadArguments(), root).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  /// Pushes the branch to its upstream. git never asks on a terminal: credentials come from the user's helper or
  /// agent, else the push fails.
  public static func push(root: String) -> Result<Void, PullRequests.Failure> {
    run(pushArguments(), root, environment: ["GIT_TERMINAL_PROMPT": "0"]).map { _ in () }
  }

  /// Puts back what the fix changed: its new files go, the rest come back from `before`. Files changed again since
  /// the fix was ready are kept, and come back as the result.
  public static func revert(_ fix: Fix, root: String) -> Result<[String], PullRequests.Failure> {
    let now: String
    switch snapshot(root: root) {
    case .failure(let failure): return .failure(failure)
    case .success(let tree): now = tree
    }
    var since: Set<String> = []
    if now != fix.after {
      switch run(changesArguments(from: fix.after, to: now), root) {
      case .failure(let failure): return .failure(failure)
      case .success(let output): since = Set(parseChanges(output).map(\.path))
      }
    }
    let undo = fix.changes.filter { !since.contains($0.path) }
    for change in undo where change.kind == .added {
      try? FileManager.default.removeItem(atPath: (root as NSString).appendingPathComponent(change.path))
    }
    let restore = undo.filter { $0.kind != .added }.map(\.path)
    if !restore.isEmpty, case .failure(let failure) = run(restoreArguments(source: fix.before, paths: restore), root) {
      return .failure(failure)
    }
    return .success(fix.changes.filter { since.contains($0.path) }.map(\.path))
  }

  /// git in `root`: its output, or its line about what it refused.
  static func run(_ arguments: [String], _ root: String, environment: [String: String] = [:])
    -> Result<String, PullRequests.Failure> {
    guard let result = GitHubCLI.execute(git, ["-C", root] + arguments, environment: environment) else {
      return .failure(.failed("Couldn't run git."))
    }
    guard result.status == 0 else {
      return .failure(.failed(failureLine(String(decoding: result.error, as: UTF8.self))))
    }
    return .success(String(decoding: result.output, as: UTF8.self))
  }

  // MARK: Suggestions and Claude's progress

  /// `text` with lines `start`...`end` (from 1) replaced by `suggestion`, when they still read `original` (the lines
  /// the review was written on). The file's line endings stay. Nil when those lines changed since, or aren't there.
  public static func applying(_ suggestion: [String], to text: String, start: Int, end: Int,
                              original: [String]) -> String? {
    guard start >= 1, end >= start, !original.isEmpty else { return nil }
    let crlf = text.contains("\r\n")
    var lines = text.components(separatedBy: "\n")
    func bare(_ line: String) -> String { line.hasSuffix("\r") ? String(line.dropLast()) : line }
    guard end <= lines.count, lines[(start - 1)...(end - 1)].map(bare) == original else { return nil }
    lines.replaceSubrange((start - 1)...(end - 1), with: suggestion.map { crlf ? $0 + "\r" : $0 })
    return lines.joined(separator: "\n")
  }

  /// What Claude is doing, from the end of its transcript (newest tool first):
  /// - "Editing scripts/release.sh";
  /// - "Running swift test";
  /// - "Reading Package.swift";
  /// - "Searching the project";
  /// - "Working" for any other tool.
  ///
  /// Paths inside `root` show from it. Nil before Claude uses a tool.
  public static func activity(transcript tail: String, root: String) -> String? {
    func relative(_ path: String) -> String {
      path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }
    for line in tail.split(whereSeparator: \.isNewline).reversed() {
      guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            entry["type"] as? String == "assistant",
            let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]],
            let tool = content.last(where: { $0["type"] as? String == "tool_use" }) else { continue }
      let input = tool["input"] as? [String: Any] ?? [:]
      switch tool["name"] as? String ?? "" {
      case "Edit", "MultiEdit", "Write", "NotebookEdit":
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String
        return path.map { "Editing \(relative($0))" } ?? "Editing"
      case "Read":
        return (input["file_path"] as? String).map { "Reading \(relative($0))" } ?? "Reading"
      case "Bash":
        let command = (input["command"] as? String ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if command.isEmpty { return "Running a command" }
        return "Running " + (command.count > 40 ? String(command.prefix(39)) + "…" : command)
      case "Grep", "Glob":
        return "Searching the project"
      default:
        return "Working"
      }
    }
    return nil
  }
}
