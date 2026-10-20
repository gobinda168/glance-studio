import Foundation

/// One step, rendered and ready to run (spec "Runs"): what to start, where, with what on stdin and in the
/// environment. The run machine makes it; GlanceKit's step runners start it.
public struct AutomationStepPlan: Equatable, Sendable {
  public enum Work: Equatable, Sendable {
    /// A zsh command line, run as `sandbox-exec -p <profile> /bin/zsh -lc <line>`.
    case shell(String)
    /// `claude` with these arguments, the prompt on stdin.
    case claude(prompt: String, arguments: [String])
    /// A nested run of another automation with these inputs.
    case automation(id: String, inputs: [String: AutomationValue])
  }

  public var step: String
  public var work: Work
  /// Absolute.
  public var cwd: String
  public var stdin: String?
  public var timeout: TimeInterval
  public var outputsJSON: Bool
  public var outward: Bool
  /// GLANCE_RUN_DIR, GLANCE_AUTOMATION_DIR, GLANCE_INPUTS_FILE, GLANCE_STEPS_FILE, and GLANCE_INPUTS / GLANCE_STEPS
  /// when they are small enough to live in the environment.
  public var environment: [String: String]
  /// Files the runner writes before it launches the step: absolute path to contents (the run's `inputs.json` and
  /// `steps.json` that the `*_FILE` variables name).
  public var files: [String: String]

  public init(step: String, work: Work, cwd: String, stdin: String? = nil, timeout: TimeInterval = 300,
              outputsJSON: Bool = false, outward: Bool = false, environment: [String: String] = [:],
              files: [String: String] = [:]) {
    self.step = step
    self.work = work
    self.cwd = cwd
    self.stdin = stdin
    self.timeout = timeout
    self.outputsJSON = outputsJSON
    self.outward = outward
    self.environment = environment
    self.files = files
  }

  public static let previewLimit = 600

  /// What an approval card shows: the command line (or, for Claude, the tools it may use and its model, then the
  /// prompt; or the automation and its inputs), then stdin; at most 600 characters.
  public var preview: String {
    var text: String
    switch work {
    case .shell(let line): text = line
    case .claude(let prompt, let arguments):
      func value(after flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
      }
      let allowed = value(after: "--allowedTools").flatMap { $0.isEmpty ? nil : $0 } ?? "none"
      text = "Tools: \(allowed)\n"
      if let model = value(after: "--model") { text += "Model: \(model)\n" }
      text += "\n" + prompt
    case .automation(let id, let inputs): text = "\(id) \(AutomationValue.object(inputs).json)"
    }
    if let stdin, !stdin.isEmpty { text += "\n\nstdin:\n" + stdin }
    return text.count > Self.previewLimit ? String(text.prefix(Self.previewLimit)) + "…" : text
  }
}

/// The commands steps and watchers run.
public enum AutomationStepCommand {
  /// The zsh command line for a package script: the interpreter its `#!` line names, else by extension (python3,
  /// node, ruby; zsh for the rest), then the quoted path. A script doesn't need its executable bit.
  public static func scriptLine(path: String, firstLine: String?) -> String {
    let quoted = AutomationTemplate.shellQuoted(path)
    if let firstLine, firstLine.hasPrefix("#!") {
      let interpreter = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
      if !interpreter.isEmpty { return "\(interpreter) \(quoted)" }
    }
    switch (path as NSString).pathExtension.lowercased() {
    case "py": return "python3 \(quoted)"
    case "js", "mjs": return "node \(quoted)"
    case "rb": return "ruby \(quoted)"
    default: return "/bin/zsh \(quoted)"
    }
  }

  public static let sandboxExec = "/usr/bin/sandbox-exec"

  /// The argv (executable first) for a zsh line under the automation's sandbox profile.
  public static func sandboxed(_ line: String, profile: String) -> [String] {
    [sandboxExec, "-p", profile, "/bin/zsh", "-lc", line]
  }

  /// A Claude step's arguments (spec "Runs", *Claude steps*): headless, streaming, nothing kept, hooks off; `--tools`
  /// only the built-in tools its `tools` name; `--allowedTools` its `tools` + `mcp`; no MCP servers at all unless it
  /// names MCP tools; its model. Entries containing a comma are dropped.
  public static func claudeArguments(tools: [String], mcp: [String], model: String?) -> [String] {
    var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                     "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#,
                     "--tools", builtInTools(tools).joined(separator: ",")]
    let tools = tools.filter { !$0.contains(",") }
    let mcp = mcp.filter { !$0.contains(",") }
    let allowed = tools + mcp
    if !allowed.isEmpty { arguments += ["--allowedTools", allowed.joined(separator: ",")] }
    if mcp.isEmpty { arguments.append("--strict-mcp-config") }
    if let model, !model.isEmpty { arguments += ["--model", model] }
    return arguments
  }

  /// "Bash(git:*)" → "Bash"; MCP names are left out; each once, in order. An entry with a comma is dropped (it
  /// would become two tools in the comma-joined flag).
  public static func builtInTools(_ tools: [String]) -> [String] {
    var names: [String] = []
    for tool in tools where !tool.hasPrefix("mcp__") && !tool.contains(",") {
      let name = tool.firstIndex(of: "(").map { String(tool[..<$0]) } ?? tool
      if !name.isEmpty, !names.contains(name) { names.append(name) }
    }
    return names
  }
}

/// A step's captured output, at most 1 MB (spec "Runs": "truncated with a note").
public struct AutomationOutputCap: Sendable {
  public static let limit = 1_000_000
  public static let note = "\n[output truncated at 1 MB]\n"

  public private(set) var bytes = 0
  public private(set) var truncated = false

  public init() {}

  /// The part of `chunk` to keep: all of it, the start of it and the note (once), or nil once the cap is reached.
  public mutating func accept(_ chunk: String) -> String? {
    guard !truncated else { return nil }
    let size = chunk.utf8.count
    if bytes + size <= Self.limit {
      bytes += size
      return chunk
    }
    var kept = ""
    var room = Self.limit - bytes
    for character in chunk {
      let width = character.utf8.count
      guard width <= room else { break }
      kept.append(character)
      room -= width
    }
    bytes = Self.limit
    truncated = true
    return kept + Self.note
  }
}

/// What a finished step reports to the run.
public struct AutomationStepResult: Equatable, Sendable {
  public enum Status: Equatable, Sendable { case ok, failed, cancelled, timedOut }

  public var status: Status
  /// The step's result: stdout (trailing newlines dropped), Claude's answer, the callee's final output; or why it
  /// failed.
  public var text: String
  /// A nested automation's final JSON.
  public var json: AutomationValue?
  public var durationMs: Int
  public var costUSD: Double?

  public init(status: Status, text: String, json: AutomationValue? = nil, durationMs: Int = 0,
              costUSD: Double? = nil) {
    self.status = status
    self.text = text
    self.json = json
    self.durationMs = durationMs
    self.costUSD = costUSD
  }

  /// A script or command that exited. `stdout` is the result; a failure's text adds the end of stderr and the exit
  /// status. Cancel and timeout win over the exit status (the process was killed). A sandbox-exec error keeps the
  /// profile in the text (spec "Errors": "run log keeps the profile").
  public static func script(stdout: String, stderr: String, exitStatus: Int32, cancelled: Bool, timedOut: Bool,
                            timeout: TimeInterval, profile: String, durationMs: Int) -> AutomationStepResult {
    let output = trimmed(stdout)
    if cancelled { return AutomationStepResult(status: .cancelled, text: output, durationMs: durationMs) }
    if timedOut {
      return AutomationStepResult(status: .timedOut, text: output + (output.isEmpty ? "" : "\n")
                                    + "Timed out after \(Int(timeout)) seconds.", durationMs: durationMs)
    }
    guard exitStatus != 0 else { return AutomationStepResult(status: .ok, text: output, durationMs: durationMs) }
    var parts = [output, lastLines(trimmed(stderr), count: 20)].filter { !$0.isEmpty }
    parts.append("Exited with status \(exitStatus).")
    if stderr.contains("sandbox-exec:") { parts.append("Sandbox profile:\n" + profile) }
    return AutomationStepResult(status: .failed, text: parts.joined(separator: "\n"), durationMs: durationMs)
  }

  /// Without trailing line breaks ("\n", "\r\n").
  public static func trimmed(_ text: String) -> String {
    var text = text
    while let last = text.last, last.isNewline { text.removeLast() }
    return text
  }

  /// The last `count` lines (a failure card shows 20).
  public static func lastLines(_ text: String, count: Int) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
  }
}
