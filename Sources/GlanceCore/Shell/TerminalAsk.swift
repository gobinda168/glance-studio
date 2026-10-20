import Foundation

/// Claude in the terminal, on demand only (spec "S5: Claude on demand"): what an ask is, the short context Claude
/// gets (the folder, the system, the branch, this tab's last commands, the project's scripts; a failure's command and
/// output, all through `SecretFilter`; never file contents, the environment or other tabs), and the answer it gives.
public enum TerminalAsk {
  public enum Kind: Equatable, Sendable {
    /// `# what you want`.
    case request(String)
    /// The last command failed: why, and the fixed command.
    case failure
    /// What this line does, and a better one if it has a problem.
    case explain(String)
  }

  /// What ⌘I (or Tab/⏎ on a `#` line) asks, given the line and whether the last command failed. Nil on an empty line
  /// after a success: Studio puts `# ` on the line to type a request.
  public static func kind(line: String, lastFailed: Bool) -> Kind? {
    let text = line.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("#") {
      let request = text.dropFirst().trimmingCharacters(in: .whitespaces)
      return request.isEmpty ? nil : .request(request)
    }
    if text.isEmpty { return lastFailed ? .failure : nil }
    return .explain(text)
  }

  public struct Context: Sendable {
    /// The folder as shown (`~` for home).
    public var folder: String
    /// macOS and zsh versions.
    public var system: String
    public var branch: String?
    /// The repository's uncommitted files: changed (staged or not) and untracked. Nil when not known.
    public var changes: (changed: Int, untracked: Int)?
    /// This tab's last commands, oldest first, with their exit codes.
    public var recent: [(command: String, exit: Int?)]
    public var scripts: [String]
    public var makeTargets: [String]
    public var failure: Failure?

    public init(folder: String, system: String, branch: String?, recent: [(command: String, exit: Int?)],
                scripts: [String], makeTargets: [String], failure: Failure?,
                changes: (changed: Int, untracked: Int)? = nil) {
      self.folder = folder
      self.system = system
      self.branch = branch
      self.changes = changes
      self.recent = recent
      self.scripts = scripts
      self.makeTargets = makeTargets
      self.failure = failure
    }
  }

  /// Claude Code's system prompt for these asks (it replaces Claude Code's own; no tools are given).
  public static let systemPrompt = """
    You help someone at a macOS terminal (zsh). Reply with one JSON object and nothing else, no code fence: \
    {"explanation": "<one to three short sentences>", "commands": [{"command": "<one zsh command line>", \
    "note": "<a few words>"}]}. Give one to three commands, the most likely first, or none when nothing should be run. \
    Every command must work as typed on macOS with what the context shows; never invent files, scripts or flags. \
    Prefer safe commands: no sudo, rm -rf, --force or anything destructive unless the request asks for exactly that.
    """

  /// Claude's fastest and cheapest model (Claude Code's `haiku` alias, always the latest Haiku), through the user's own
  /// Claude Code: no tools, no MCP, no hooks, nothing saved, one JSON result.
  public static func arguments() -> [String] {
    ["-p", "--model", "haiku", "--output-format", "json", "--no-session-persistence", "--tools", "",
     "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#, "--system-prompt", systemPrompt]
  }

  public static func prompt(_ kind: Kind, _ context: Context) -> String {
    var lines: [String] = []
    switch kind {
    case .request(let text):
      lines.append("Request: \(text)")
    case .failure:
      lines.append("The last command failed. Say why in plain words, and give the corrected command.")
    case .explain(let line):
      lines.append("Say what this command line does, and if it has a problem, give a corrected one:\n\(line)")
    }
    lines.append("")
    lines.append("Folder: \(context.folder)")
    lines.append("System: \(context.system)")
    if let branch = context.branch {
      switch context.changes {
      case nil: lines.append("Git branch: \(branch)")
      case (0, 0)?: lines.append("Git branch: \(branch) (no uncommitted changes)")
      case let (changed, untracked)?:
        lines.append("Git branch: \(branch) (\(changed) \(changed == 1 ? "file" : "files") changed, \(untracked) untracked)")
      }
    }
    if !context.scripts.isEmpty { lines.append("package.json scripts: \(context.scripts.joined(separator: ", "))") }
    if !context.makeTargets.isEmpty { lines.append("Makefile targets: \(context.makeTargets.joined(separator: ", "))") }
    if !context.recent.isEmpty {
      lines.append("Recent commands in this tab, oldest first:")
      for run in context.recent.suffix(8) {
        lines.append("  \(run.command)" + (run.exit.map { "  [exit \($0)]" } ?? ""))
      }
    }
    if case .failure = kind, let failure = context.failure {
      lines.append("Failed command: \(failure.command)  [exit \(failure.exitCode)]")
      lines.append(failure.output.isEmpty ? "It printed nothing." : "Its last lines of output:\n\(failure.output)")
    }
    return SecretFilter.redact(lines.joined(separator: "\n"))
  }

  public struct Answer: Equatable, Sendable {
    public struct Command: Equatable, Sendable, Identifiable {
      public let command: String
      public let note: String
      /// Worth a second look before running (`rm -rf`, `--force`, `sudo`…).
      public let risky: Bool
      public var id: String { command }
    }

    public let explanation: String
    public let commands: [Command]
  }

  /// The answer in Claude's reply: its JSON object (a code fence around it, or words before it, are fine); a reply
  /// without one is the explanation alone.
  public static func answer(_ text: String) -> Answer {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"), open < close,
       let object = try? JSONSerialization.jsonObject(with: Data(trimmed[open...close].utf8)) as? [String: Any] {
      let explanation = (object["explanation"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let commands = (object["commands"] as? [[String: Any]] ?? []).compactMap { item -> Answer.Command? in
        guard let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return nil }
        return Answer.Command(command: command, note: (item["note"] as? String) ?? "", risky: isRisky(command))
      }
      return Answer(explanation: explanation, commands: Array(commands.prefix(3)))
    }
    return Answer(explanation: trimmed, commands: [])
  }

  /// How many of `git status`'s files are changed (staged or not) and how many untracked.
  public static func changeCounts(_ changes: [GitChanges.Change]) -> (changed: Int, untracked: Int) {
    let untracked = changes.filter { $0.status == .untracked }.count
    return (changes.count - untracked, untracked)
  }

  /// A repository's counts from git's default listing (an untracked folder counts once: git doesn't walk into it, so
  /// a dotfiles repo in home stays quick), without the optional index lock, so the user's own git commands never find
  /// it taken. Nil outside a repository, or when git takes over `timeout` (it is stopped then).
  public static func changeCounts(root: String, timeout: TimeInterval) -> (changed: Int, untracked: Int)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=normal"]
    process.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0"]) { $1 }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer.cancel()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
    return changeCounts(GitChanges.parse(String(decoding: data, as: UTF8.self)))
  }

  /// Commands to check before running (spec "S5", "The answer panel").
  public static func isRisky(_ command: String) -> Bool {
    let patterns = [
      #"\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)"#, #"\bgit\s+reset\s+.*--hard"#, #"\bgit\s+push\b.*(\s-f\b|--force)"#,
      #"\bgit\s+clean\s+-[a-zA-Z]*f"#, #"\b(chmod|chown)\s+-R"#, #"(^|[;&|]\s*)sudo\b"#, #"\bdd\s+if="#, #"\bmkfs"#,
      #"\bkill\s+-9\b"#, #"\bkillall\b"#, #"\bdocker\s+system\s+prune"#, #"(?i)\bdrop\s+(table|database)\b"#,
      #">\s*/dev/(disk|sd)"#,
    ]
    return patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
  }

  /// A Makefile's targets (not patterns, special targets or variables).
  public static func makeTargets(_ makefile: String) -> [String] {
    var targets: [String] = []
    for line in makefile.split(separator: "\n") {
      guard let first = line.first, first != "\t", first != "#", first != ".",
            let colon = line.firstIndex(of: ":"), !line[line.index(after: colon)...].hasPrefix("=") else { continue }
      for name in line[..<colon].split(separator: " ") where !name.contains("%") && !name.contains("$")
        && !name.contains("=") && !targets.contains(String(name)) {
        targets.append(String(name))
      }
    }
    return targets
  }
}
