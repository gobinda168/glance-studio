import Foundation

/// A command that failed: what ran, how it ended, the last lines it printed, and where (spec "S4", "Fixes after a
/// failure").
public struct Failure: Equatable, Sendable {
  public let command: String
  public let exitCode: Int
  public let output: String
  public let folder: String

  public init(command: String, exitCode: Int, output: String, folder: String) {
    self.command = command
    self.exitCode = exitCode
    self.output = output
    self.folder = folder
  }
}

/// What the rules may look at around a failure.
public struct CorrectionContext {
  /// Commands, aliases, functions and builtins the shell has.
  public var names: Set<String>
  /// Whether a path exists / is a folder (relative to the failure's folder, or absolute).
  public var exists: (String) -> Bool
  public var isDirectory: (String) -> Bool
  /// A folder's entries (relative to the failure's folder, or absolute; "." for the folder itself), folders ending in
  /// `/`; nil when it can't be read.
  public var list: (String) -> [String]?
  /// The package.json scripts in the folder.
  public var scripts: [String]
  /// The repository's local branches.
  public var branches: [String]
  /// Commands that worked before, the ones from this folder or repository first (`CommandIndex.worked`).
  public var history: [PastCommand] = []

  public init(names: Set<String>, exists: @escaping (String) -> Bool, isDirectory: @escaping (String) -> Bool,
              list: @escaping (String) -> [String]?, scripts: [String], branches: [String],
              history: [PastCommand] = []) {
    self.names = names
    self.exists = exists
    self.isDirectory = isDirectory
    self.list = list
    self.scripts = scripts
    self.branches = branches
    self.history = history
  }
}

/// Fixes for failed commands without a model: rules in the manner of thefuck (https://github.com/nvbn/thefuck, MIT),
/// each one a pattern in the command and its output and the command it means. The first rule with an answer wins; an
/// answer that would make the command more destructive is dropped.
public enum Corrections {
  typealias Rule = @Sendable (Failure, CorrectionContext) -> String?

  /// ⌃C, a broken pipe and ⌃Z aren't failures to fix.
  public static let notFailures: Set<Int> = [0, 130, 141, 148]

  static let rules: [Rule] = [
    cdDotDot, pythonThree, gitNoUpstream, gitBranchExists, gitPushRejected, gitUnknownBranch, didYouMean,
    similarArgument, packageScript, scriptPermission, cdMissing, mkdirParents, catDirectory, missingFile,
    sudoPermission, knownCommand, noCommand,
  ]

  public static func fix(_ failure: Failure, _ context: CorrectionContext) -> String? {
    guard !notFailures.contains(failure.exitCode) else { return nil }
    for rule in rules {
      guard let fixed = rule(failure, context)?.trimmingCharacters(in: .whitespaces), !fixed.isEmpty,
            fixed != failure.command else { continue }
      return isSafe(original: failure.command, fix: fixed) ? fixed : nil
    }
    return nil
  }

  /// A fix may not add `--force`, `-f`, `-D`, `--hard`, a recursive flag, `--no-verify`, or `rm`.
  public static func isSafe(original: String, fix: String) -> Bool {
    let before = Set(words(original)), after = words(fix)
    let added = after.filter { !before.contains($0) }
    let risky: Set<String> = ["--force", "-f", "-D", "--hard", "-rf", "-fr", "-r", "-R", "--force-with-lease",
                              "--no-verify", "--recursive"]
    if added.contains(where: risky.contains) { return false }
    if after.contains("rm") && (!before.contains("rm") || (after.first == "sudo" && before.first != "sudo")) {
      return false
    }
    return true
  }

  // MARK: - Rules

  static func cdDotDot(_ f: Failure, _ c: CorrectionContext) -> String? {
    f.command.hasPrefix("cd..") ? "cd .." + f.command.dropFirst(4) : nil
  }

  static func pythonThree(_ f: Failure, _ c: CorrectionContext) -> String? {
    guard let missing = commandNotFound(f.output), ["python", "pip"].contains(missing),
          c.names.contains(missing + "3") else { return nil }
    return replacingFirstWord(f.command, with: missing + "3")
  }

  static func gitNoUpstream(_ f: Failure, _ c: CorrectionContext) -> String? {
    guard f.command.hasPrefix("git push"), f.output.contains("has no upstream branch") else { return nil }
    return capture(#"(?m)^\s*(git push --set-upstream \S+ \S+)\s*$"#, in: f.output)
  }

  static func gitBranchExists(_ f: Failure, _ c: CorrectionContext) -> String? {
    guard let name = capture(#"(?i)a branch named '([^']+)' already exists"#, in: f.output) else { return nil }
    if f.command.hasPrefix("git checkout -b \(name)") { return "git checkout \(name)" }
    if f.command.hasPrefix("git switch -c \(name)") { return "git switch \(name)" }
    return nil
  }

  static func gitPushRejected(_ f: Failure, _ c: CorrectionContext) -> String? {
    guard f.command.hasPrefix("git push"), f.output.contains("Updates were rejected because") else { return nil }
    return "git pull && \(f.command)"
  }

  static func gitUnknownBranch(_ f: Failure, _ c: CorrectionContext) -> String? {
    let parts = words(f.command)
    guard parts.count == 3, parts[0] == "git", ["checkout", "switch"].contains(parts[1]), !parts[2].hasPrefix("-"),
          f.output.contains("did not match any file(s) known to git") || f.output.contains("invalid reference")
    else { return nil }
    let name = parts[2]
    if let branch = closest(name, in: c.branches) { return "git \(parts[1]) \(branch)" }
    // A new branch, unless it looks like a file.
    guard !name.contains("."), !c.exists(name) else { return nil }
    return parts[1] == "checkout" ? "git checkout -b \(name)" : "git switch -c \(name)"
  }

  /// git, gh, npm, cargo, kubectl, brew: "'x' is not a … command … The most similar command is y", "unknown command
  /// "x" … Did you mean this? y", "no such command: `x` … Did you mean `y`?".
  static func didYouMean(_ f: Failure, _ c: CorrectionContext) -> String? {
    let unknown = capture(#"'([^']+)' is not a [\w-]+ command"#, in: f.output)
      ?? capture(#"(?i)unknown command:? "([^"]+)""#, in: f.output)
      ?? capture(#"no such command: `([^`]+)`"#, in: f.output)
    guard let unknown else { return nil }
    let suggestion = capture(#"most similar commands? (?:is|are)\s*\n\s*(\S+)"#, in: f.output)
      ?? capture(#"Did you mean this\?\s*\n\s*([^\n#]+)"#, in: f.output)
      ?? capture(#"Did you mean [`'"]?([^`'"?\s]+)[`'"]?\?"#, in: f.output)
    guard let line = suggestion?.trimmingCharacters(in: .whitespaces), let replacement = words(line).last,
          replacement != unknown else { return nil }
    return replacingWord(unknown, with: replacement, in: f.command)
  }

  /// clap's "unexpected argument '--verbos' found … a similar argument exists: '--verbose'".
  static func similarArgument(_ f: Failure, _ c: CorrectionContext) -> String? {
    guard let wrong = capture(#"unexpected argument '([^']+)' found"#, in: f.output),
          let right = capture(#"similar argument exists: '([^']+)'"#, in: f.output) else { return nil }
    return replacingWord(wrong, with: right, in: f.command)
  }

  /// A package.json script that doesn't exist: the one the tool suggests (pnpm's `Did you mean "pnpm dev:web"?`, yarn's
  /// `Did you mean "dev:web"?`, npm's "Did you mean this? … npm run dev:web"), else the closest one.
  static func packageScript(_ f: Failure, _ c: CorrectionContext) -> String? {
    let parts = words(f.command)
    guard parts.count >= 2, ["npm", "pnpm", "yarn", "bun"].contains(parts[0]) else { return nil }
    let missing = f.output.contains("Missing script") || f.output.range(of: #"Command "[^"]+" not found"#,
                                                                        options: .regularExpression) != nil
    guard missing else { return nil }
    let index = parts[1] == "run" && parts.count >= 3 ? 2 : 1
    let suggested = capture(#"Did you mean "([^"]+)"\?"#, in: f.output)
      ?? capture(#"Did you mean (?:this|one of these)\?\s*\n(?:npm (?:error|ERR!))?\s*([^\n#]+)"#, in: f.output)
    guard let script = suggested.flatMap({ words($0).last }) ?? closest(parts[index], in: c.scripts) else { return nil }
    var fixed = parts
    fixed[index] = script
    return fixed.joined(separator: " ")
  }

  static func scriptPermission(_ f: Failure, _ c: CorrectionContext) -> String? {
    guard let first = words(f.command).first, first.contains("/"),
          f.output.contains("permission denied: \(first)") else { return nil }
    return "chmod +x \(first) && \(f.command)"
  }

  static func cdMissing(_ f: Failure, _ c: CorrectionContext) -> String? {
    let parts = words(f.command)
    guard parts.count == 2, parts[0] == "cd", f.output.lowercased().contains("no such file or directory") else {
      return nil
    }
    let target = parts[1]
    let parent = (target as NSString).deletingLastPathComponent
    let base = (target as NSString).lastPathComponent
    let folders = (c.list(parent.isEmpty ? "." : parent) ?? []).filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }
    if let near = closest(base, in: folders) {
      return "cd " + (parent.isEmpty ? near : (parent as NSString).appendingPathComponent(near))
    }
    return "mkdir -p \(target) && cd \(target)"
  }

  static func mkdirParents(_ f: Failure, _ c: CorrectionContext) -> String? {
    let parts = words(f.command)
    guard parts.first == "mkdir", !parts.contains("-p"), f.output.contains("No such file or directory") else {
      return nil
    }
    return "mkdir -p " + parts.dropFirst().joined(separator: " ")
  }

  static func catDirectory(_ f: Failure, _ c: CorrectionContext) -> String? {
    guard f.command.hasPrefix("cat "), f.output.contains("Is a directory") else { return nil }
    return "ls" + f.command.dropFirst(3)
  }

  /// A file argument that doesn't exist: the closest file in its folder.
  static func missingFile(_ f: Failure, _ c: CorrectionContext) -> String? {
    let path = capture(#"(?m)^[\w.-]+: ([^:\n]+): No such file or directory"#, in: f.output)
      ?? capture(#"pathspec '([^']+)' did not match any files"#, in: f.output)
    guard let path, words(f.command).contains(path) else { return nil }
    let parent = (path as NSString).deletingLastPathComponent
    let base = (path as NSString).lastPathComponent
    let files = (c.list(parent.isEmpty ? "." : parent) ?? []).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    guard let near = closest(base, in: files) else { return nil }
    return replacingWord(path, with: parent.isEmpty ? near : (parent as NSString).appendingPathComponent(near),
                         in: f.command)
  }

  static func sudoPermission(_ f: Failure, _ c: CorrectionContext) -> String? {
    let output = f.output.lowercased()
    guard output.contains("permission denied") || output.contains("operation not permitted")
            || output.contains("eacces") || output.contains("must be run as root") || output.contains("superuser"),
          !output.contains("publickey"), let first = words(f.command).first,
          !["sudo", "rm", "brew", "git", "ssh", "scp", "sftp", "rsync"].contains(first) else { return nil }
    return "sudo \(f.command)"
  }

  /// A line that is a typo of one that worked before (`gti status`, `pnmp run dev`, `cd ~/dev/webb`): the nearest by edit
  /// distance, then the one from this folder or repository, then the most used. Only when it is nearly the same line,
  /// and its paths exist.
  static func knownCommand(_ f: Failure, _ c: CorrectionContext) -> String? {
    let line = f.command
    guard !line.contains("\n"), line.count >= 3, looksMistyped(f) else { return nil }
    let limit = line.count <= 6 ? 1 : line.count <= 16 ? 2 : 3
    var best: (past: PastCommand, distance: Int)?
    for past in c.history where past.command != line && abs(past.command.count - line.count) <= limit {
      let d = distance(line, past.command)
      guard d <= limit, c.names.contains(first(past.command)), pathsExist(past.command, c) else { continue }
      // History is ordered best first, so a later command only wins by being nearer.
      if best == nil || d < best!.distance { best = (past, d) }
    }
    return best?.past.command
  }

  /// The failure reads like a typo, not like a command that ran and failed.
  private static func looksMistyped(_ f: Failure) -> Bool {
    if f.exitCode == 127 { return true }
    let output = f.output.lowercased()
    return ["command not found", "no such file or directory", "not a git command", "unknown command",
            "unknown option", "unrecognized", "invalid choice", "did not match any"].contains(where: output.contains)
  }

  private static func first(_ command: String) -> String { words(command).first ?? "" }

  private static func pathsExist(_ command: String, _ c: CorrectionContext) -> Bool {
    let parts = words(command)
    for (position, word) in parts.enumerated() {
      let isTarget = position == 1 && ["cd", "pushd"].contains(parts[0]) && !word.hasPrefix("-")
      if (isTarget || GhostSuggester.isPathLike(word)) && !c.exists(word) { return false }
    }
    return true
  }

  /// "command not found": the closest command the shell has.
  static func noCommand(_ f: Failure, _ c: CorrectionContext) -> String? {
    guard let missing = commandNotFound(f.output), let near = closest(missing, in: Array(c.names)) else { return nil }
    return replacingFirstWord(f.command, with: near)
  }

  // MARK: - Helpers

  static func commandNotFound(_ output: String) -> String? {
    capture(#"command not found: (\S+)"#, in: output) ?? capture(#"(?m)^(?:\S+: )?(\S+): command not found"#, in: output)
  }

  static func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  static func replacingFirstWord(_ command: String, with word: String) -> String {
    guard let first = words(command).first, let range = command.range(of: first) else { return word }
    return command.replacingCharacters(in: range, with: word)
  }

  /// `word` replaced as a whole word (its first occurrence) in `command`.
  static func replacingWord(_ word: String, with replacement: String, in command: String) -> String? {
    let pattern = "(?<=^|\\s)" + NSRegularExpression.escapedPattern(for: word) + "(?=$|\\s)"
    guard let range = command.range(of: pattern, options: .regularExpression) else { return nil }
    return command.replacingCharacters(in: range, with: replacement)
  }

  static func capture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
  }

  /// The candidate nearest `word` by edit distance (a swap counts as one), within 1 for short words, 2 up to eight
  /// characters, 3 beyond; ties go to the same first letter, then the shorter, then alphabetical.
  static func closest(_ word: String, in candidates: [String]) -> String? {
    let limit = word.count <= 4 ? 1 : word.count <= 8 ? 2 : 3
    var best: (String, Int)?
    for candidate in candidates where candidate != word && abs(candidate.count - word.count) <= limit {
      let d = distance(word, candidate)
      guard d <= limit else { continue }
      if let current = best {
        let better = d < current.1 || (d == current.1 && rank(candidate, word) < rank(current.0, word))
        if better { best = (candidate, d) }
      } else {
        best = (candidate, d)
      }
    }
    return best?.0
  }

  private static func rank(_ candidate: String, _ word: String) -> (Int, Int, String) {
    (candidate.first == word.first ? 0 : 1, candidate.count, candidate)
  }

  /// Edit distance with adjacent swaps (optimal string alignment).
  static func distance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0...a.count { d[i][0] = i }
    for j in 0...b.count { d[0][j] = j }
    for i in 1...a.count {
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
        if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
      }
    }
    return d[a.count][b.count]
  }
}
