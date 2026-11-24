import Foundation

public struct ProofCheckMatch: Equatable, Sendable {
  public var name: String
  public var environment: String?
  /// Whether the Bash call's exit code is this check's own result. True only when every connector after the matched
  /// command is `&&` and no pipe touches it: exit 0 then means the check passed, non-zero means it failed only when it
  /// is the last command. Otherwise (`; echo done`, `| tail`, `|| true`) the exit code may belong to something else and
  /// the caller falls back on the parsed counts.
  public var exitIsReliable: Bool
  /// Whether the matched command is the last one on the command line. A non-zero exit means this check failed only
  /// then: `pnpm test && pnpm build` exits non-zero when the build fails too.
  public var isLastSegment: Bool
  public init(name: String, environment: String?, exitIsReliable: Bool, isLastSegment: Bool) {
    self.name = name; self.environment = environment; self.exitIsReliable = exitIsReliable
    self.isLastSegment = isLastSegment
  }
}

/// Matching Bash commands against a setup's checks and URLs against its environments (spec §3).
public enum ProofMatcher {
  /// The first check whose `match` finds one of the command's simple commands (a command line is split on unquoted
  /// `&&`, `||`, `;`, `|` and newlines; quoted text, heredoc bodies and leading `NAME=value`, `env`, `time` are not
  /// matched against), and the environment it ran against: `env`, or the URL named by `envFrom` read from that command
  /// alone and classified through the environments (an unclassified URL falls back to `env`, else nil).
  public static func check(for command: String, in setup: ProofSetup) -> ProofCheckMatch? {
    guard !setup.checks.isEmpty else { return nil }
    let segments = segments(of: command)
    let subjects = segments.map { commandWords($0.plain) }
    for check in setup.checks {
      guard let regex = try? NSRegularExpression(pattern: check.match) else { continue }
      for (index, subject) in subjects.enumerated()
      where regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil {
        var environment = check.env
        if let name = check.envFrom, let value = value(of: name, in: segments[index].raw),
           let classified = self.environment(forURL: value, in: setup) {
          environment = classified
        }
        let pipedInto = index > 0 && segments[index - 1].connector == .pipe
        let reliable = !pipedInto && segments[index...].allSatisfy { $0.connector == nil || $0.connector == .and }
        return ProofCheckMatch(name: check.name, environment: environment, exitIsReliable: reliable,
                               isLastSegment: index == segments.count - 1)
      }
    }
    return nil
  }

  private enum Connector { case and, or, semicolon, pipe, newline }

  /// One simple command: as written (`raw`), with quoted contents removed and escapes resolved (`plain`), and the
  /// connector that follows it (nil for the last).
  private struct Segment {
    var raw = ""
    var plain = ""
    var connector: Connector?
  }

  /// Splits a command line on unquoted `&&`, `||`, `;`, `|` and newlines, respecting single quotes, double quotes and
  /// backslash escapes, and dropping heredoc bodies (`<<EOF`, `<<-EOF`, `<<'EOF'`, `<<"EOF"`). Empty pieces are dropped.
  private static func segments(of command: String) -> [Segment] {
    let chars = Array(command)
    var all: [Segment] = []
    var current = Segment()
    var heredocs: [(delimiter: String, stripTabs: Bool)] = []
    var i = 0

    func close(_ connector: Connector?) {
      current.connector = connector
      all.append(current)
      current = Segment()
    }

    while i < chars.count {
      let c = chars[i]
      switch c {
      case "\\":
        if i + 1 < chars.count {
          current.raw += String(chars[i...i + 1])
          current.plain += chars[i + 1] == "\n" ? " " : String(chars[i + 1])
          i += 2
        } else { current.raw.append(c); i += 1 }
      case "'", "\"":
        var j = i + 1
        while j < chars.count, chars[j] != c {
          j += (c == "\"" && chars[j] == "\\") ? 2 : 1
        }
        let end = min(j, chars.count - 1)
        current.raw += String(chars[i...end])
        current.plain += "\(c)\(c)"
        i = end + 1
      case "&" where i + 1 < chars.count && chars[i + 1] == "&":
        close(.and); i += 2
      case "|" where i + 1 < chars.count && chars[i + 1] == "|":
        close(.or); i += 2
      case "|": close(.pipe); i += 1
      case ";": close(.semicolon); i += 1
      case "\n":
        close(.newline); i += 1
        for heredoc in heredocs {
          while i < chars.count {
            var end = i
            while end < chars.count, chars[end] != "\n" { end += 1 }
            var line = String(chars[i..<end])
            if line.hasSuffix("\r") { line.removeLast() }
            if heredoc.stripTabs { line = String(line.drop(while: { $0 == "\t" })) }
            i = min(end + 1, chars.count)
            if line == heredoc.delimiter { break }
          }
        }
        heredocs = []
      case "<" where i + 1 < chars.count && chars[i + 1] == "<":
        if i + 2 < chars.count, chars[i + 2] == "<" {
          current.raw += "<<<"; current.plain += "<<<"; i += 3
          continue
        }
        var j = i + 2
        let stripTabs = j < chars.count && chars[j] == "-"
        if stripTabs { j += 1 }
        while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
        var delimiter = ""
        if j < chars.count, chars[j] == "'" || chars[j] == "\"" {
          let quote = chars[j]
          j += 1
          while j < chars.count, chars[j] != quote { delimiter.append(chars[j]); j += 1 }
          j = min(j + 1, chars.count)
        } else {
          while j < chars.count, !chars[j].isWhitespace, !";&|<>()".contains(chars[j]) { delimiter.append(chars[j]); j += 1 }
        }
        if !delimiter.isEmpty { heredocs.append((delimiter, stripTabs)) }
        let operatorText = String(chars[i..<j])
        current.raw += operatorText; current.plain += operatorText
        i = j
      default:
        current.raw.append(c); current.plain.append(c); i += 1
      }
    }
    close(nil)

    var kept = all.filter { !$0.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if !kept.isEmpty { kept[kept.count - 1].connector = nil }
    return kept
  }

  /// The command proper: leading `NAME=value` assignments, `env` and `time` dropped.
  private static func commandWords(_ plain: String) -> String {
    var rest = Substring(plain)
    while true {
      rest = rest.drop(while: \.isWhitespace)
      let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
      let token = rest[..<end]
      guard token == "env" || token == "time" || token.firstMatch(of: /^[A-Za-z_][A-Za-z0-9_]*=/) != nil else { break }
      rest = rest[end...]
    }
    return String(rest)
  }

  private static let quotes = CharacterSet(charactersIn: "'\"")

  /// `NAME=value` anywhere in the command, or a flag spelled from the name (`--base-url=value`, `--base_url value`;
  /// case-insensitive, `-` and `_` alike). Quotes around the value (`BASE_URL="http://…"`) are dropped.
  static func value(of name: String, in command: String) -> String? {
    let words = command.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: quotes) }
    let flag = "--" + name.lowercased().replacingOccurrences(of: "_", with: "-")
    func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "_", with: "-") }
    func unquoted(_ s: String) -> String { s.trimmingCharacters(in: quotes) }
    for (i, word) in words.enumerated() {
      if word.hasPrefix(name + "=") { return unquoted(String(word.dropFirst(name.count + 1))) }
      if norm(word).hasPrefix(flag + "=") { return unquoted(String(word.dropFirst(flag.count + 1))) }
      if norm(word) == flag, words.indices.contains(i + 1) { return words[i + 1] }
    }
    return nil
  }

  /// The environment whose `match` globs fit the URL's `host:port` (a pattern with a colon) or host (one without).
  public static func environment(forURL url: String, in setup: ProofSetup) -> String? {
    guard let components = URLComponents(string: url), let host = components.host?.lowercased() else { return nil }
    let port = components.port.map(String.init) ?? (components.scheme == "https" ? "443" : "80")
    for env in setup.environments {
      for pattern in env.match {
        let subject = pattern.contains(":") ? host + ":" + port : host
        if glob(pattern.lowercased(), matches: subject) { return env.name }
      }
    }
    return nil
  }

  /// `*` matches any run of characters; everything else is literal.
  static func glob(_ pattern: String, matches text: String) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
    return text.range(of: "^" + escaped + "$", options: .regularExpression) != nil
  }

  /// Passed and failed counts from the summary a common runner prints in the last 64 KB of output (jest, vitest,
  /// playwright, pytest, XCTest, swift-testing). Runner-specific summary lines win over any other line with
  /// "N passed" (jest's `Snapshots: 3 passed` must not hide `Tests: 2 failed, 40 passed`). Optional: the exit code is
  /// the truth.
  public static func counts(in output: String) -> (passed: Int?, failed: Int?) {
    // Bytes, not Characters: walking a megabyte of grapheme clusters is far slower than the hook budget allows.
    let lines = String(decoding: output.utf8.suffix(65_536), as: UTF8.self).split(separator: "\n").map(String.init)
    for line in lines.reversed() {
      if let found = summaryCounts(line) { return found }
    }
    if let found = playwrightCounts(lines) { return found }
    for line in lines.suffix(80).reversed() {
      let found = passedFailed(line)
      if found.passed != nil || found.failed != nil { return found }
    }
    return (nil, nil)
  }

  private static func passedFailed(_ line: String) -> (passed: Int?, failed: Int?) {
    (line.firstMatch(of: /(\d+) passed/).flatMap { Int($0.1) }, line.firstMatch(of: /(\d+) failed/).flatMap { Int($0.1) })
  }

  /// The runners whose summary is one unmistakable line.
  private static func summaryCounts(_ line: String) -> (passed: Int?, failed: Int?)? {
    // Cheap substring checks first: this runs on every line of up to 64 KB and regexes are slow.
    if line.contains("Executed "), let m = line.firstMatch(of: /Executed (\d+) tests?, with (\d+) failures?/) {
      let total = Int(m.1) ?? 0, failed = Int(m.2) ?? 0
      return (total - failed, failed)
    }
    if line.contains("Test run with"), let m = line.firstMatch(of: /Test run with (\d+) tests?.* passed/) { return (Int(m.1), nil) }
    let text = line.trimmingCharacters(in: .whitespaces)
    guard text.hasPrefix("Tests:") || text.hasPrefix("Tests ") || text.hasPrefix("=") else { return nil }
    let found = passedFailed(text)
    return found.passed != nil || found.failed != nil ? found : nil
  }

  /// Playwright prints `  1 failed` and `  12 passed (3.1s)` on separate lines.
  private static func playwrightCounts(_ lines: [String]) -> (passed: Int?, failed: Int?)? {
    guard let passedLine = lines.lastIndex(where: { $0.contains(" passed (") && $0.firstMatch(of: /^\s*\d+ passed \(/) != nil }),
          let passed = lines[passedLine].firstMatch(of: /(\d+) passed/).flatMap({ Int($0.1) }) else { return nil }
    let failed = lines.last { $0.hasSuffix(" failed") && $0.firstMatch(of: /^\s*\d+ failed\s*$/) != nil }
      .flatMap { $0.firstMatch(of: /(\d+) failed/) }.flatMap { Int($0.1) }
    return (passed, failed)
  }

  /// "Exit code N" on the first line of a failed Bash call's error. Nil for any other failure (interrupted, timed out,
  /// refused): the exit code is then unknown and nothing may be guessed from it.
  public static func exitCode(fromError error: String) -> Int? {
    let first = error.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    return first.firstMatch(of: /^Exit code (\d+)/).flatMap { Int($0.1) }
  }

  /// Whether a matched check call passed or failed, or nil when Glance did not see enough to say (spec §3: "Seen by
  /// Glance" never claims what was not seen). `exitCode` is nil when the hook could not tell.
  /// - A reliable exit (`ProofCheckMatch.exitIsReliable`) of 0 passed; a reliable non-zero exit failed when the check
  ///   is the last command on the line.
  /// - Otherwise (a pipe, `; echo done`, `|| true`, a later `&&` command that may have failed instead) the runner's
  ///   own summary decides: failures failed, passes with no failures passed.
  /// - Otherwise nothing.
  public static func result(of match: ProofCheckMatch, exitCode: Int?,
                            counts: (passed: Int?, failed: Int?)) -> ProofResult? {
    if match.exitIsReliable, let exitCode {
      if exitCode == 0 { return .passed }
      if match.isLastSegment { return .failed }
    }
    if let failed = counts.failed, failed > 0 { return .failed }
    if let passed = counts.passed, passed > 0 { return .passed }
    return nil
  }

  /// The environment a URL belongs to in the setup found from `cwd`; nil without a setup or a matching environment.
  public static func environment(forURL url: String, cwd: String) -> String? {
    ProofSetupFile.load(cwd: cwd).setup.flatMap { environment(forURL: url, in: $0) }
  }

  public static func tail(_ text: String, lines: Int) -> String {
    text.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
      .suffix(lines).joined(separator: "\n")
  }
}
