import Foundation
import GlanceCore

/// A step under way; the run session cancels it.
@MainActor
protocol AutomationStepRunner: AnyObject {
  func cancel()
}

/// Decodes a byte stream as UTF-8 piece by piece, holding back a character that a chunk boundary split.
struct AutomationUTF8Chunks {
  private var pending: [UInt8] = []

  mutating func decode(_ data: Data) -> String {
    let bytes = pending + data
    var cut = bytes.count
    // A lead byte near the end that wants more bytes than are there: keep it for the next chunk.
    for back in 1...min(3, max(bytes.count, 1)) where back <= bytes.count {
      let byte = bytes[bytes.count - back]
      if byte & 0xC0 == 0x80 { continue }
      let need = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
      if need > back { cut = bytes.count - back }
      break
    }
    pending = Array(bytes[cut...])
    return String(decoding: bytes[..<cut], as: UTF8.self)
  }

  /// Whatever is left when the stream ends (an incomplete character becomes U+FFFD).
  mutating func flush() -> String {
    defer { pending = [] }
    return String(decoding: pending, as: UTF8.self)
  }
}

extension AutomationStepRunner {
  /// Writes the plan's files (the run's `inputs.json` and `steps.json`) before the step starts.
  static func writeFiles(of plan: AutomationStepPlan) throws {
    for (path, contents) in plan.files {
      let url = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url, options: .atomic)
    }
  }
}

/// A script or command step (spec "Runs", *Script steps*): `sandbox-exec -p <profile> /bin/zsh -lc <line>` in the
/// step's cwd with the GLANCE_* environment, in its own process group. stdout is the result; stdout and stderr both
/// stream to the log. A timeout or cancel kills the group.
@MainActor
final class ScriptStepRunner: AutomationStepRunner {
  private let plan: AutomationStepPlan
  private let profile: String
  private let onOutput: @MainActor (String) -> Void
  private let onDone: @MainActor (AutomationStepResult) -> Void
  private var process: AutomationProcess?
  private var stdout = ""
  private var stderr = ""
  private var stdoutCap = AutomationOutputCap()
  private var stderrCap = AutomationOutputCap()
  private var stdoutChunks = AutomationUTF8Chunks()
  private var stderrChunks = AutomationUTF8Chunks()
  private var cancelled = false
  private var timedOut = false
  private var finished = false
  private let started = Date()

  init(plan: AutomationStepPlan, line: String, profile: String, onOutput: @escaping @MainActor (String) -> Void,
       onDone: @escaping @MainActor (AutomationStepResult) -> Void) {
    self.plan = plan
    self.profile = profile
    self.onOutput = onOutput
    self.onDone = onDone
    var environment = ProcessInfo.processInfo.environment.merging(plan.environment) { $1 }
    environment["CLAUDECODE"] = nil
    process = AutomationProcess(arguments: AutomationStepCommand.sandboxed(line, profile: profile),
                                environment: environment, directory: plan.cwd)
  }

  /// A dropped runner mustn't leave its process running.
  deinit {
    if let process, !process.hasExited { process.terminateGroup() }
  }

  func start() {
    guard let process else { return }
    do {
      try Self.writeFiles(of: plan)
    } catch {
      return finishSoon(AutomationStepResult(status: .failed, text: "Couldn't write the step's input files: \(error)"))
    }
    guard FileManager.default.fileExists(atPath: plan.cwd) else {
      return finishSoon(AutomationStepResult(status: .failed, text: "The step's folder doesn't exist: \(plan.cwd)"))
    }
    do {
      try process.start(stdin: plan.stdin.map { Data($0.utf8) }, output: { [weak self] data, isError in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data, isError: isError) } }
      }, exit: { [weak self] status in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(status) } }
      })
    } catch {
      return finishSoon(AutomationStepResult(status: .failed, text: "\(error)"))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + plan.timeout) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.finished else { return }
        self.timedOut = true
        self.process?.terminateGroup()
      }
    }
  }

  func cancel() {
    guard !finished else { return }
    cancelled = true
    process?.terminateGroup()
  }

  private func received(_ data: Data, isError: Bool) {
    guard !finished else { return }
    keep(isError ? stderrChunks.decode(data) : stdoutChunks.decode(data), isError: isError)
  }

  /// Both streams go to the log; each is capped on its own (AutomationOutputCap, split on character boundaries).
  private func keep(_ text: String, isError: Bool) {
    guard !text.isEmpty else { return }
    let kept = isError ? stderrCap.accept(text) : stdoutCap.accept(text)
    guard let kept else { return }
    if isError { stderr += kept } else { stdout += kept }
    onOutput(kept)
  }

  private func exited(_ status: Int32) {
    guard !finished else { return }
    keep(stdoutChunks.flush(), isError: false)
    keep(stderrChunks.flush(), isError: true)
    finished = true
    let result = AutomationStepResult.script(
      stdout: stdout, stderr: stderr,
      exitStatus: status, cancelled: cancelled, timedOut: timedOut, timeout: plan.timeout, profile: profile,
      durationMs: Int(Date().timeIntervalSince(started) * 1000))
    onDone(result)
  }

  /// Results are always reported after `start` returns, so the run never re-enters itself.
  private func finishSoon(_ result: AutomationStepResult) {
    finished = true
    DispatchQueue.main.async { MainActor.assumeIsolated { self.onDone(result) } }
  }
}

/// A Claude step (spec "Runs", *Claude steps*): `ClaudeRunner` with the step's arguments in its cwd; streamed text is
/// output, tool uses are `step.tool` lines, the result's cost is kept. `GLANCE_CLAUDE_STUB=1` in the environment
/// skips Claude and answers "<claude:step-id>" (the CLI's checks use it).
@MainActor
final class ClaudeStepRunner: AutomationStepRunner {
  static var isStubbed: Bool { ProcessInfo.processInfo.environment["GLANCE_CLAUDE_STUB"] == "1" }

  private let plan: AutomationStepPlan
  private let onOutput: @MainActor (String) -> Void
  private let onTool: @MainActor (String) -> Void
  private let onDone: @MainActor (AutomationStepResult) -> Void
  private var run: ClaudeOneShot.Run?
  private var cost: Double?
  private var cap = AutomationOutputCap()
  private var finished = false
  private let started = Date()

  init(plan: AutomationStepPlan, onOutput: @escaping @MainActor (String) -> Void,
       onTool: @escaping @MainActor (String) -> Void, onDone: @escaping @MainActor (AutomationStepResult) -> Void) {
    self.plan = plan
    self.onOutput = onOutput
    self.onTool = onTool
    self.onDone = onDone
  }

  func start(prompt: String, arguments: [String]) {
    do {
      try Self.writeFiles(of: plan)
    } catch {
      let failure = AutomationStepResult(status: .failed, text: "Couldn't write the step's input files: \(error)")
      DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(failure) } }
      return
    }
    if Self.isStubbed {
      let answer = "<claude:\(plan.step)>"
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard !self.finished else { return }
          self.onOutput(answer)
          self.finish(AutomationStepResult(status: .ok, text: answer))
        }
      }
      return
    }
    run = ClaudeRunner.run(arguments: arguments, prompt: prompt, folder: plan.cwd, timeout: plan.timeout,
                           onEvent: { [weak self] event in self?.handle(event) },
                           onCost: { [weak self] cost in self?.cost = cost })
  }

  func cancel() {
    guard !finished else { return }
    run?.cancel()
    // Reported after `cancel` returns, like every other result.
    DispatchQueue.main.async {
      MainActor.assumeIsolated { self.finish(AutomationStepResult(status: .cancelled, text: "")) }
    }
  }

  private func handle(_ event: ClaudeRunner.Event) {
    switch event {
    case .text(let piece): if let kept = cap.accept(piece) { onOutput(kept) }
    case .tool(let label): onTool(label)
    case .done(let text):
      // The answer is the step's captured output, capped like a script's.
      var answer = AutomationOutputCap()
      finish(AutomationStepResult(status: .ok, text: answer.accept(text) ?? text))
    case .failed(let message):
      finish(AutomationStepResult(status: run?.timedOut == true ? .timedOut : .failed, text: message))
    }
  }

  private func finish(_ result: AutomationStepResult) {
    guard !finished else { return }
    finished = true
    var result = result
    result.durationMs = Int(Date().timeIntervalSince(started) * 1000)
    result.costUSD = cost
    onDone(result)
  }
}
