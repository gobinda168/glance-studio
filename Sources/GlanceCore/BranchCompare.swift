import Foundation

/// A branch against its base, for the New pull request page (spec 2026-10-07-pr-manager-design.md, "New pull request";
/// "GitHub": local git). It answers:
/// - the branches;
/// - how far the branch is ahead and behind;
/// - its commits and files;
/// - whether it merges cleanly;
/// - whether GitHub has it.
///
/// The fork runs git; this builds the arguments and reads the answers.
public enum BranchCompare {
  public struct Commit: Equatable, Sendable {
    public let hash: String
    public let subject: String

    public init(hash: String, subject: String) {
      self.hash = hash
      self.subject = subject
    }
  }

  public struct FileStat: Equatable, Sendable {
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let binary: Bool

    public init(path: String, additions: Int, deletions: Int, binary: Bool = false) {
      self.path = path
      self.additions = additions
      self.deletions = deletions
      self.binary = binary
    }
  }

  /// Whether the branch merges into its base: cleanly, with conflicts in these files, or unknown (git couldn't say).
  public enum Merge: Equatable, Sendable {
    case clean
    case conflicts([String])
    case unknown
  }

  /// The branch on GitHub: as it is here; with commits still to push (and some only GitHub has); or not there yet.
  public enum Pushed: Equatable, Sendable {
    case current
    case ahead(Int, behind: Int)
    case notPushed
  }

  // MARK: git's arguments (run with -C and the project's folder)

  /// The base as the pull request will merge into it: GitHub's copy.
  public static func baseRef(_ base: String) -> String { "origin/\(base)" }

  public static func fetchArguments(base: String) -> [String] { ["fetch", "--quiet", "origin", base] }

  public static func localBranchesArguments() -> [String] { ["branch", "--format=%(refname:short)"] }

  public static func remoteBranchesArguments() -> [String] { ["branch", "-r", "--format=%(refname:short)"] }

  /// Left: commits only the base has (behind); right: only the branch (ahead).
  public static func countArguments(base: String, head: String) -> [String] {
    ["rev-list", "--left-right", "--count", "\(baseRef(base))...\(head)"]
  }

  /// The branch's commits, newest first: short hash and subject.
  public static func logArguments(base: String, head: String) -> [String] {
    ["log", "--format=%h%x1f%s", "\(baseRef(base))..\(head)"]
  }

  public static func numstatArguments(base: String, head: String) -> [String] {
    ["diff", "--numstat", "--no-renames", "-z", "\(baseRef(base))...\(head)"]
  }

  /// The prefixes are spelled out: `PullRequestDiff.parse` reads a/ and b/, whatever diff.noprefix says.
  public static func diffArguments(base: String, head: String) -> [String] {
    ["diff", "--no-color", "--no-ext-diff", "--no-renames", "--src-prefix=a/", "--dst-prefix=b/",
     "\(baseRef(base))...\(head)"]
  }

  public static func mergeTreeArguments(base: String, head: String) -> [String] {
    ["merge-tree", "--write-tree", "--name-only", "--no-messages", baseRef(base), head]
  }

  /// Left: commits only GitHub's copy has; right: commits still to push. It fails when GitHub has no copy.
  public static func upstreamArguments(branch: String) -> [String] {
    ["rev-list", "--left-right", "--count", "origin/\(branch)...\(branch)"]
  }

  public static func headArguments(branch: String) -> [String] { ["rev-parse", branch] }

  /// Pushes the branch, with GitHub's copy as its upstream.
  public static func pushArguments(branch: String) -> [String] { ["push", "--set-upstream", "origin", branch] }

  // MARK: git's answers

  /// `git branch --format=%(refname:short)`, sorted. With `remote`, GitHub's branches (origin/…, its HEAD left out).
  public static func branches(_ output: String, remote: Bool) -> [String] {
    var names: Set<String> = []
    for raw in output.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if remote {
        guard line.hasPrefix("origin/"), line != "origin/HEAD" else { continue }
        names.insert(String(line.dropFirst("origin/".count)))
      } else if !line.isEmpty, !line.hasPrefix("(") {
        names.insert(line)
      }
    }
    return names.sorted()
  }

  /// `git rev-list --left-right --count A...B`: commits only in A, only in B.
  public static func counts(_ output: String) -> (left: Int, right: Int)? {
    let numbers = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
  }

  /// `git log --format=%h%x1f%s`, newest first.
  public static func commits(_ output: String) -> [Commit] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
      let parts = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
      return parts.count == 2 ? Commit(hash: String(parts[0]), subject: String(parts[1])) : nil
    }
  }

  /// `git diff --numstat -z`: "12\t3\tpath\0"; a binary file has "-" for both counts.
  public static func fileStats(_ output: String) -> [FileStat] {
    output.split(separator: "\0").compactMap { record in
      let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3 else { return nil }
      return FileStat(path: String(parts[2]), additions: Int(parts[0]) ?? 0, deletions: Int(parts[1]) ?? 0,
                      binary: parts[0] == "-")
    }
  }

  /// `git merge-tree --write-tree --name-only --no-messages`: exit 0 merges cleanly; exit 1 lists the conflicted files
  /// after the merged tree's id.
  public static func merge(status: Int32, output: String) -> Merge {
    switch status {
    case 0: return .clean
    case 1: return .conflicts(Array(output.components(separatedBy: "\n").dropFirst().prefix { !$0.isEmpty }))
    default: return .unknown
    }
  }

  /// The branch against GitHub's copy (`upstreamArguments`): not pushed when git found no copy.
  public static func pushed(status: Int32, output: String) -> Pushed {
    guard status == 0, let counts = counts(output) else { return .notPushed }
    return counts.left == 0 && counts.right == 0 ? .current : .ahead(counts.right, behind: counts.left)
  }

  /// Every file's additions and deletions, summed.
  public static func totals(_ files: [FileStat]) -> (additions: Int, deletions: Int) {
    (files.reduce(0) { $0 + $1.additions }, files.reduce(0) { $0 + $1.deletions })
  }

  /// "6 commits · 19 files" (the compare bar draws its +N −N apart).
  public static func countsLine(commits: Int, files: Int) -> String {
    "\(commits) \(commits == 1 ? "commit" : "commits") · \(files) \(files == 1 ? "file" : "files")"
  }

  /// "6 commits ahead of main, 0 behind" (the side bar's This branch).
  public static func aheadLine(ahead: Int, behind: Int, base: String) -> String {
    "\(ahead) \(ahead == 1 ? "commit" : "commits") ahead of \(base), \(behind) behind"
  }

  // MARK: Pre-flight and Create

  /// A line the branch adds that looks like a key (spec: "Rules → Secrets").
  public struct Secret: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let kind: String
  }

  /// Checked in order: an Anthropic key is an "sk-" key too.
  static let secretShapes: [(kind: String, pattern: String)] = [
    ("GitHub token", #"\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})"#),
    ("AWS access key", #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
    ("Slack token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
    ("Stripe key", #"\b[rs]k_live_[A-Za-z0-9]{20,}"#),
    ("Anthropic key", #"\bsk-ant-[A-Za-z0-9_-]{20,}"#),
    ("OpenAI key", #"\bsk-(proj-)?[A-Za-z0-9_-]{20,}"#),
    ("Private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
  ]

  /// The added lines shaped like a GitHub, AWS, Slack, Stripe, Anthropic or OpenAI key, or a private key's header.
  public static func secrets(in files: [PullRequestDiff.File]) -> [Secret] {
    var found: [Secret] = []
    for file in files {
      for line in file.hunks.flatMap(\.lines) where line.kind == .added {
        guard let number = line.new,
              let shape = secretShapes.first(where: { line.text.range(of: $0.pattern, options: .regularExpression) != nil })
        else { continue }
        found.append(Secret(path: file.path, line: number, kind: shape.kind))
      }
    }
    return found
  }

  /// The project's test command (spec: "Rules → Test command"):
  /// - `swift test` (Package.swift);
  /// - `npm test` (a package.json test script that isn't npm's placeholder);
  /// - `cargo test`;
  /// - `go test ./...`;
  /// - `make test` (a Makefile with a test target).
  ///
  /// Nil without one. `read` gives one of the project's top files, or nil.
  public static func testCommand(_ read: (String) -> String?) -> String? {
    if read("Package.swift") != nil { return "swift test" }
    if let json = read("package.json"),
       let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
       let script = (object["scripts"] as? [String: Any])?["test"] as? String, !script.contains("no test specified") {
      return "npm test"
    }
    if read("Cargo.toml") != nil { return "cargo test" }
    if read("go.mod") != nil { return "go test ./..." }
    if let make = read("Makefile"), make.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("test:") }) {
      return "make test"
    }
    return nil
  }

  /// `gh pr create`: the description goes to stdin; reviewers and labels are comma-joined; the viewer assigns
  /// themselves.
  public static func createArguments(repository: String, base: String, head: String, title: String, draft: Bool,
                                     reviewers: [String], labels: [String]) -> [String] {
    var arguments = ["pr", "create", "--repo", repository, "--base", base, "--head", head, "--title", title,
                     "--body-file", "-", "--assignee", "@me"]
    if draft { arguments.append("--draft") }
    if !reviewers.isEmpty { arguments += ["--reviewer", reviewers.joined(separator: ",")] }
    if !labels.isEmpty { arguments += ["--label", labels.joined(separator: ",")] }
    return arguments
  }

  /// The new pull request's number, from the URL `gh pr create` prints.
  public static func createdNumber(_ output: String) -> Int? {
    for line in output.split(whereSeparator: \.isNewline).reversed() {
      if let range = line.range(of: #"/pull/[0-9]+"#, options: .regularExpression) {
        return Int(line[range].dropFirst("/pull/".count))
      }
    }
    return nil
  }

  /// git's line about what it refused: a push's "! [rejected] …" first.
  public static func failure(_ stderr: String) -> String { FixPatch.failureLine(stderr) }

  /// What the title starts as without Claude's draft: the one commit's subject.
  public static func defaultTitle(_ commits: [Commit]) -> String { commits.count == 1 ? commits[0].subject : "" }
}
