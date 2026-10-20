import Darwin
import Foundation
import GlanceCore

/// One headless `claude -p` run that streams (spec 2026-10-09-notifications-design.md, "Quick-reply panel"): the AI
/// chips' answers as they come, the tools Claude uses, then the final answer. Runs in `ClaudeOneShot.scratchFolder`
/// with no built-in tools; `tools` names the MCP connector tools it may use (the Slack read tools, or only the send
/// tool on Send). Hooks are off and nothing is kept.
@MainActor
public final class ClaudeRunner {
  public enum Event: Equatable, Sendable {
    /// A piece of the answer, as it streams.
    case text(String)
    /// A tool Claude is using ("Using slack_read_thread…").
    case tool(String)
    /// The run's final answer: the last turn's text (the result), or everything streamed when the result has none.
    case done(String)
    case failed(String)
  }

  private init() {}

  /// `tools`: MCP tool names allowed (empty: no tools at all). `disallowed`: tools denied outright, even when the
  /// user's settings pre-allow them (a Slack run denies every Slack tool its step doesn't need). `model`: "haiku" for
  /// mechanical steps, nil for default. Events arrive on the main thread; after `cancel()` none do.
  @discardableResult
  public static func run(prompt: String, tools: [String], disallowed: [String] = [], model: String?,
                         timeout: TimeInterval = 120,
                         onEvent: @escaping @MainActor (Event) -> Void) -> ClaudeOneShot.Run {
    run(arguments: arguments(tools: tools, disallowed: disallowed, model: model), prompt: prompt, folder: nil,
        timeout: timeout, onEvent: onEvent)
  }

  /// The same stream with the caller's own arguments (an automation's Claude step: its tools, MCP and model) in
  /// `folder` (`ClaudeOneShot.scratchFolder` when nil). `onCost` gets the result's `total_cost_usd` just before
  /// `.done`.
  @discardableResult
  public static func run(arguments: [String], prompt: String, folder: String?, timeout: TimeInterval,
                         onEvent: @escaping @MainActor (Event) -> Void,
                         onCost: (@MainActor (Double) -> Void)? = nil) -> ClaudeOneShot.Run {
    let run = ClaudeOneShot.Run()
    ClaudeLocator.locate { found in
      guard !run.cancelled else { return }
      guard let found else {
        onEvent(.failed("Claude Code isn't installed or isn't on PATH."))
        return
      }
      RunnerStream(run: run, folder: folder ?? ClaudeOneShot.scratchFolder, onEvent: onEvent, onCost: onCost)
        .start(found, arguments: arguments, prompt: prompt, timeout: timeout)
    }
    return run
  }

  /// No built-in tools; MCP connectors load only when some of their tools are allowed (`--strict-mcp-config` would
  /// drop them, and without tools it makes the start faster).
  static func arguments(tools: [String], disallowed: [String] = [], model: String?) -> [String] {
    ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--no-session-persistence",
     "--settings", #"{"disableAllHooks":true}"#, "--tools", ""]
      + (tools.isEmpty ? ["--strict-mcp-config"] : ["--allowedTools", tools.joined(separator: ",")])
      + (disallowed.isEmpty ? [] : ["--disallowedTools", disallowed.joined(separator: ",")])
      + (model.map { ["--model", $0] } ?? [])
  }
}

/// One run's process and its stream: stdout read line by line on a private serial queue, every line handled on main.
@MainActor
private final class RunnerStream {
  private let run: ClaudeOneShot.Run
  private let folder: String
  private let onEvent: @MainActor (ClaudeRunner.Event) -> Void
  private let onCost: (@MainActor (Double) -> Void)?
  private var parser: InlineAsk.Parser
  private var fullText = ""
  private var finished = false

  init(run: ClaudeOneShot.Run, folder: String, onEvent: @escaping @MainActor (ClaudeRunner.Event) -> Void,
       onCost: (@MainActor (Double) -> Void)?) {
    self.run = run
    self.folder = folder
    self.onEvent = onEvent
    self.onCost = onCost
    parser = InlineAsk.Parser(folder: folder)
  }

  func start(_ found: ClaudeLocator.Found, arguments: [String], prompt: String, timeout: TimeInterval) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: found.executable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: folder)
    var environment = ProcessInfo.processInfo.environment
    if let path = found.path { environment["PATH"] = path }
    environment["CLAUDECODE"] = nil
    process.environment = environment
    let stdin = Pipe(), stdout = Pipe()
    // A write after Claude exits must fail, not kill the app with SIGPIPE.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      finish(.failed("Couldn't start Claude Code: \(error.localizedDescription)"))
      return
    }
    run.process = process
    LiveProcesses.add(process)
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [self] in
      MainActor.assumeIsolated {
        guard process.isRunning, !run.cancelled, !finished else { return }
        run.timedOut = true
        process.terminate()
        finish(.failed("Claude took too long."))
      }
    }
    let input = Data(prompt.utf8)
    let queue = DispatchQueue(label: "dev.glance.ClaudeRunner", qos: .userInitiated)
    queue.async { [self] in
      try? stdin.fileHandleForWriting.write(contentsOf: input)
      try? stdin.fileHandleForWriting.close()
      let reader = stdout.fileHandleForReading
      var lines = JSONLines()
      while true {
        let data = reader.availableData
        if data.isEmpty { break }
        let complete = lines.append(data)
        guard !complete.isEmpty else { continue }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.received(complete) } }
      }
      process.waitUntilExit()
      DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(process) } }
    }
  }

  private func received(_ lines: [String]) {
    for line in lines {
      guard !finished, !run.cancelled else { return }
      for event in parser.feed(line) {
        switch event {
        case .text(let piece):
          fullText += piece
          emit(.text(piece))
        case .tool(let label):
          emit(.tool(Self.shortLabel(label)))
        case .done:
          if let cost = Self.cost(line), !finished, !run.cancelled { onCost?(cost) }
          finish(.done(Self.resultText(line) ?? fullText))
        case .failed(let message):
          finish(.failed(message))
        }
      }
    }
  }

  private func ended(_ process: Process) {
    LiveProcesses.remove(process)
    finish(.failed(run.timedOut ? "Claude took too long." : "Claude stopped unexpectedly."))
  }

  private func emit(_ event: ClaudeRunner.Event) {
    guard !finished, !run.cancelled else { return }
    onEvent(event)
  }

  /// The first `done` or `failed` ends the run; anything after it is dropped.
  private func finish(_ event: ClaudeRunner.Event) {
    guard !finished else { return }
    emit(event)
    finished = true
  }

  /// The `result` line's final answer, when it has one.
  private static func resultText(_ line: String) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let text = object["result"] as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return text
  }

  /// The `result` line's `total_cost_usd`.
  private static func cost(_ line: String) -> Double? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
    return (object["total_cost_usd"] as? NSNumber)?.doubleValue
  }

  /// "Using mcp__claude_ai_Slack__slack_read_thread…" → "Using slack_read_thread…".
  private static func shortLabel(_ label: String) -> String {
    guard label.hasPrefix("Using mcp__"), let last = label.range(of: "__", options: .backwards) else { return label }
    return "Using " + label[last.upperBound...]
  }
}
