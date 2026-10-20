import Foundation
import GlanceCore

/// One run (spec "Runs"): `AutomationRunMachine`'s effects carried out — the log file, the step runners, parking (at an
/// outward step or on an ask step's question) with its 24-hour expiry, cancel. The engine owns it and hears about parks and the end.
@MainActor
final class AutomationRunSession {
  static let parkLimit: TimeInterval = 24 * 3600

  let ref: AutomationRunRef
  let name: String
  let fire: AutomationFire
  let startedAt = Date()
  /// A nested run (another automation's `automation` step): it doesn't queue and doesn't post its own failure card.
  let isNested: Bool
  private var machine: AutomationRunMachine
  private let profile: String
  private let log: FileHandle?
  private weak var engine: AutomationEngine?
  /// The step's runner. It holds itself only weakly in its own callbacks, so the session keeps it until `done`.
  private var runner: AutomationStepRunner?
  private var nested: AutomationRunSession?
  private var cap = AutomationOutputCap()
  /// The Claude step going, when this is an agent's: its answer may remember things and message other agents.
  private var claudeStep: String?
  private var expiry: DispatchWorkItem?
  /// The current step's output, the last 64 KB (a failure card shows its last lines).
  private(set) var stepOutput = ""
  /// Why the failed step failed: the text of its failing `step.end` (output and reason such as "Timed out after 2
  /// seconds."), for the failure card and for a caller's nested step.
  private(set) var failureText: String?
  /// Hears the end: the engine, and a nested run's caller.
  var onEnd: ((AutomationRunSession) -> Void)?

  init(ref: AutomationRunRef, name: String, setup: AutomationRunMachine.Setup, log: URL, profile: String,
       isNested: Bool, engine: AutomationEngine) {
    self.ref = ref
    self.name = name
    fire = setup.fire
    self.isNested = isNested
    machine = AutomationRunMachine(setup)
    self.profile = profile
    self.log = try? FileHandle(forWritingTo: log)
    self.engine = engine
  }

  var status: RunRecord.Status { machine.status }
  var currentStep: String? { machine.current }
  var parkedPlan: AutomationStepPlan? { machine.parkedPlan }
  var question: AutomationQuestion? { machine.question }
  var lastOutput: AutomationStepOutput? { machine.lastOutput }
  var failedStep: String? { machine.failedStep }

  func start() { apply(machine.start()) }

  /// Stops it: a parked run ends now; a running step is killed first and reports back as cancelled.
  func cancel() {
    apply(machine.cancel())
    guard !machine.isFinished else { return }
    runner?.cancel()
    nested?.cancel()
  }

  /// The user's answer at a parked step.
  func decide(_ decision: RunRecord.Decision) {
    expiry?.cancel()
    expiry = nil
    apply(machine.resume(decision))
  }

  /// The user's answer to the question the run waits on.
  func answer(_ answer: AutomationAnswer) {
    expiry?.cancel()
    expiry = nil
    apply(machine.answer(answer))
  }

  /// A park (outward step or question) ends on its own after 24 hours, by the wall clock: a Mac asleep for the night
  /// still expires the run in the morning.
  private func startExpiry() {
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.apply(self.machine.expire())
      }
    }
    expiry = work
    DispatchQueue.main.asyncAfter(wallDeadline: .now() + Self.parkLimit, execute: work)
  }

  private func apply(_ effects: [AutomationRunMachine.Effect]) {
    for effect in effects {
      switch effect {
      case .log(let event):
        write(event)
      case .start(let plan):
        begin(plan)
      case .park(let plan):
        startExpiry()
        engine?.parked(self, plan)
      case .ask(let question):
        startExpiry()
        engine?.asked(self, question)
      case .trust:
        engine?.setTrusted(ref.automation, true)
      case .end:
        expiry?.cancel()
        expiry = nil
        try? log?.close()
        runner = nil
        nested = nil
        onEnd?(self)
      }
    }
  }

  private func write(_ event: RunLogEvent) {
    if case .stepEnd(_, let status, let text, _, _, _) = event, status == .failed { failureText = text }
    let line = RunLog.line(RunLogLine(at: Date(), event: event)) + "\n"
    try? log?.write(contentsOf: Data(line.utf8))
    engine?.logged(ref, event)
  }

  private func begin(_ plan: AutomationStepPlan) {
    cap = AutomationOutputCap()
    stepOutput = ""
    claudeStep = nil
    let step = plan.step
    switch plan.work {
    case .shell(let line):
      let script = ScriptStepRunner(plan: plan, line: line, profile: profile,
                                    onOutput: { [weak self] chunk in self?.output(step, chunk) },
                                    onDone: { [weak self] result in self?.done(step, result) })
      runner = script
      script.start()
    case .claude(let prompt, let arguments):
      let claude = ClaudeStepRunner(plan: plan, onOutput: { [weak self] chunk in self?.output(step, chunk) },
                                    onTool: { [weak self] name in self?.write(.stepTool(step: step, name: name)) },
                                    onDone: { [weak self] result in self?.done(step, result) })
      runner = claude
      // An agent's Claude steps start with its memory and the other agents it can message.
      var prompt = prompt
      if let preface = engine?.agentPreface(for: ref.automation) {
        prompt = preface + "\n\n---\n\n" + prompt
        claudeStep = step
      }
      claude.start(prompt: prompt, arguments: arguments)
    case .automation(let callee, let inputs):
      // The callee's own steps write their own files; this step has no process, so none of `plan.files` is needed.
      nested = engine?.startNested(callee, inputs: inputs, caller: self) { [weak self] result in
        self?.nested = nil
        self?.done(step, result)
      }
    }
  }

  private func output(_ step: String, _ chunk: String) {
    guard let kept = cap.accept(chunk) else { return }
    write(.stepOutput(step: step, chunk: kept))
    stepOutput += kept
    if stepOutput.utf8.count > 65_536 { stepOutput = String(stepOutput.suffix(32_768)) }
  }

  private func done(_ step: String, _ result: AutomationStepResult) {
    runner = nil
    if claudeStep == step, result.status == .ok { engine?.agentSaid(self, result.text) }
    claudeStep = nil
    apply(machine.finished(step, result))
  }
}
