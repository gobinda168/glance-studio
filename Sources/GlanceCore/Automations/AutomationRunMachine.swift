import Foundation

/// One run's steps in order, without doing any of them (spec "Runs" and "Approvals"): it renders each step, skips the
/// ones whose `if` is falsy, parks at an outward step unless trusted, and says what to log, what to start and when the
/// run ends. GlanceKit's `AutomationRunSession` does what the effects say and reports back.
public struct AutomationRunMachine: Sendable {
  public enum Effect: Equatable, Sendable {
    /// Append to the run's log.
    case log(RunLogEvent)
    /// Start this step; report with `finished`.
    case start(AutomationStepPlan)
    /// Wait for the user at this outward step; answer with `resume`.
    case park(AutomationStepPlan)
    /// Ask the user this (an ask step); answer with `answer`. The run is parked until then.
    case ask(AutomationQuestion)
    /// The user chose "Trust this automation": record it.
    case trust
    case end(RunRecord.Status)
  }

  public struct Setup: Equatable, Sendable {
    public var manifest: AutomationManifest
    /// Resolved (`AutomationFire.inputs(for:given:)`).
    public var inputs: [String: AutomationValue]
    public var fire: AutomationFire
    public var runDirectory: String
    public var automationDirectory: String
    /// Expands "~" in a step's cwd.
    public var home: String
    /// The package files its steps read: prompts, and each script's text (for its #! line).
    public var texts: [String: String]
    public var trusted: Bool

    public init(manifest: AutomationManifest, inputs: [String: AutomationValue], fire: AutomationFire,
                runDirectory: String, automationDirectory: String, home: String, texts: [String: String],
                trusted: Bool) {
      self.manifest = manifest
      self.inputs = inputs
      self.fire = fire
      self.runDirectory = runDirectory
      self.automationDirectory = automationDirectory
      self.home = home
      self.texts = texts
      self.trusted = trusted
    }
  }

  struct PlanFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  public let setup: Setup
  public private(set) var status: RunRecord.Status = .running
  /// The step running or parked.
  public private(set) var current: String?
  public private(set) var outputs: [String: AutomationStepOutput] = [:]
  /// The last step that finished ok: what a nested run hands its caller.
  public private(set) var lastOutput: AutomationStepOutput?
  public private(set) var failedStep: String?
  public private(set) var trusted: Bool
  var next = 0
  var started = false
  var active: AutomationStepPlan?
  var pending: AutomationStepPlan?
  var asking: AutomationQuestion?
  var cancelRequested = false

  public init(_ setup: Setup) {
    self.setup = setup
    trusted = setup.trusted
  }

  public var isFinished: Bool { status != .running && status != .parked }
  /// The outward step it waits at.
  public var parkedPlan: AutomationStepPlan? { pending }
  /// The question it waits on.
  public var question: AutomationQuestion? { asking }

  public mutating func start() -> [Effect] {
    guard !started else { return [] }
    started = true
    let manifest = setup.manifest
    return [.log(.runStart(trigger: setup.fire.summary, payload: setup.fire.payload, inputs: setup.inputs,
                           version: manifest.version))] + advance()
  }

  /// The step started by `.start` ended.
  public mutating func finished(_ step: String, _ result: AutomationStepResult) -> [Effect] {
    guard status == .running, current == step, let plan = active else { return [] }
    active = nil
    current = nil
    switch result.status {
    case .ok:
      var json = result.json
      if plan.outputsJSON, json == nil {
        let text = AutomationStepResult.trimmed(result.text).trimmingCharacters(in: .whitespaces)
        guard let parsed = AutomationValue.decode(Data(text.utf8)) else {
          let shown = text.count > 200 ? String(text.prefix(200)) + "…" : text
          return failed(step, "Expected JSON (\"outputs\": \"json\"), got: \(shown)", result)
        }
        json = parsed
      }
      let output = AutomationStepOutput(text: result.text, json: json)
      outputs[step] = output
      lastOutput = output
      let effects: [Effect] = [.log(.stepEnd(step: step, status: .ok, text: result.text, json: json,
                                             durationMs: result.durationMs, costUSD: result.costUSD))]
      return effects + (cancelRequested ? end(.cancelled) : advance())
    case .failed, .timedOut:
      return failed(step, result.text, result)
    case .cancelled:
      return [.log(.stepEnd(step: step, status: .cancelled, text: result.text, json: nil,
                            durationMs: result.durationMs, costUSD: result.costUSD))] + end(.cancelled)
    }
  }

  /// The user's answer at a parked outward step.
  public mutating func resume(_ decision: RunRecord.Decision) -> [Effect] {
    guard status == .parked, let plan = pending else { return [] }
    pending = nil
    status = .running
    var effects: [Effect] = [.log(.runResume(step: plan.step, decision: decision))]
    switch decision {
    case .approve:
      break
    case .trust:
      trusted = true
      effects.append(.trust)
    case .skip:
      current = nil
      effects.append(.log(.stepEnd(step: plan.step, status: .skipped, text: "skipped by you", json: nil,
                                   durationMs: 0, costUSD: nil)))
      return effects + advance()
    }
    active = plan
    return effects + [.log(.stepStart(step: plan.step)), .start(plan)]
  }

  /// The user's answer to the question it waits on: the answer is the ask step's output, and the run goes on.
  public mutating func answer(_ answer: AutomationAnswer) -> [Effect] {
    guard status == .parked, let question = asking else { return [] }
    asking = nil
    status = .running
    current = nil
    let output = AutomationStepOutput(text: answer.answer, json: answer.json)
    outputs[question.step] = output
    lastOutput = output
    return [.log(.runAnswer(step: question.step, answer: answer)),
            .log(.stepEnd(step: question.step, status: .ok, text: answer.answer, json: answer.json, durationMs: 0,
                          costUSD: nil))] + advance()
  }

  /// Cancel: a parked run ends at once; a running step must be stopped first (its `finished` then reports
  /// `.cancelled`, or an ok that ends the run as cancelled).
  public mutating func cancel() -> [Effect] {
    switch status {
    case .parked:
      pending = nil
      asking = nil
      return end(.cancelled)
    case .running:
      guard started, active != nil else { return end(.cancelled) }
      cancelRequested = true
      return []
    default:
      return []
    }
  }

  /// A parked run nobody answered for 24 hours.
  public mutating func expire() -> [Effect] {
    guard status == .parked else { return [] }
    pending = nil
    asking = nil
    return end(.expired)
  }

  // MARK: Walking the steps

  mutating func advance() -> [Effect] {
    var effects: [Effect] = []
    let steps = setup.manifest.steps
    while next < steps.count {
      let index = next
      let step = steps[index]
      next += 1
      if let condition = step.condition {
        let rendered: String
        do throws(PlanFailure) {
          rendered = try render(condition, at: "steps[\(index)].if")
        } catch {
          return effects + failedToPlan(step.id, error.message)
        }
        if !AutomationTemplate.isTruthy(rendered) {
          effects.append(.log(.stepEnd(step: step.id, status: .skipped, text: "skipped: `if` rendered \"\(rendered)\"",
                                       json: nil, durationMs: 0, costUSD: nil)))
          continue
        }
      }
      if let ask = step.ask {
        let question: AutomationQuestion
        do throws(AutomationTemplateError) {
          question = try ask.render(step: step.id, context)
        } catch {
          return effects + failedToPlan(step.id, "steps[\(index)].ask: \(error.message)")
        }
        current = step.id
        status = .parked
        asking = question
        return effects + [.log(.stepStart(step: step.id)), .log(.runAsk(question)), .ask(question)]
      }
      let plan: AutomationStepPlan
      do throws(PlanFailure) {
        plan = try self.plan(step, index: index)
      } catch {
        return effects + failedToPlan(step.id, error.message)
      }
      current = step.id
      if plan.outward, !trusted {
        status = .parked
        pending = plan
        return effects + [.log(.runPark(step: step.id)), .park(plan)]
      }
      active = plan
      return effects + [.log(.stepStart(step: step.id)), .start(plan)]
    }
    return effects + end(.ok)
  }

  func plan(_ step: AutomationStep, index: Int) throws(PlanFailure) -> AutomationStepPlan {
    let path = "steps[\(index)]"
    guard let kind = step.kind else { throw PlanFailure("\(path): needs one of run, claude, automation or ask") }
    let cwd = absolute(try render(step.cwd ?? "{{run.dir}}", at: "\(path).cwd"))
    var stdin: String?
    if let template = step.stdin { stdin = try render(template, at: "\(path).stdin") }
    let work: AutomationStepPlan.Work
    switch kind {
    case .command(let line):
      work = .shell(try render(line, at: "\(path).run", quoting: .shell))
    case .script(let file):
      work = .shell(AutomationStepCommand.scriptLine(path: setup.automationDirectory + "/" + file,
                                                     firstLine: Self.firstLine(setup.texts[file])))
    case .claude(let file):
      guard let text = setup.texts[file] else { throw PlanFailure("\(file): couldn't be read") }
      work = .claude(prompt: try render(text, at: file),
                     arguments: AutomationStepCommand.claudeArguments(tools: step.tools ?? [], mcp: step.mcp ?? [],
                                                                      model: step.model))
    case .automation(let callee):
      var inputs: [String: AutomationValue] = [:]
      for (key, value) in step.inputs ?? [:] {
        do throws(AutomationTemplateError) {
          inputs[key] = try AutomationTemplate.render(value, context)
        } catch {
          throw PlanFailure("\(path).inputs.\(key): \(error.message)")
        }
      }
      work = .automation(id: callee, inputs: inputs)
    case .ask:
      throw PlanFailure("\(path): an ask step asks; it doesn't run")
    }
    let (variables, files) = environment
    return AutomationStepPlan(step: step.id, work: work, cwd: cwd, stdin: stdin, timeout: step.timeoutSeconds,
                              outputsJSON: step.outputsJSON, outward: step.isOutward, environment: variables,
                              files: files)
  }

  var context: AutomationTemplateContext {
    AutomationTemplateContext(inputs: setup.inputs, trigger: setup.fire.payload, steps: outputs,
                              runDir: setup.runDirectory, automationDir: setup.automationDirectory)
  }

  func render(_ template: String, at location: String,
              quoting: AutomationTemplate.Quoting = .none) throws(PlanFailure) -> String {
    do throws(AutomationTemplateError) {
      return try AutomationTemplate.render(template, context, quoting: quoting)
    } catch {
      throw PlanFailure("\(location): \(error.message)")
    }
  }

  /// "~/x" → home + "/x"; a relative path is inside the run directory.
  func absolute(_ path: String) -> String {
    if path == "~" { return setup.home }
    if path.hasPrefix("~/") { return setup.home + path.dropFirst() }
    if path.hasPrefix("/") { return path }
    return path.isEmpty ? setup.runDirectory : setup.runDirectory + "/" + path
  }

  /// A script's first line, without its line break (LF or CRLF); nil for an empty file. A blank first line is
  /// blank, not the next line.
  static func firstLine(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    var bytes = Array(text.utf8.prefix { $0 != UInt8(ascii: "\n") })
    if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// The largest inputs or steps JSON that goes in the environment; macOS caps arguments plus environment near
  /// 1 MB, and a step's output alone can be that big.
  public static let inlineLimit = 64 * 1024

  /// What scripts get (spec "Templating"): the run's folders; `GLANCE_INPUTS_FILE` and `GLANCE_STEPS_FILE`, always,
  /// naming `inputs.json` and `steps.json` in the run directory (the runner writes `files` before it starts the
  /// step); and `GLANCE_INPUTS` / `GLANCE_STEPS` as well when each is at most `inlineLimit` bytes.
  var environment: (variables: [String: String], files: [String: String]) {
    var steps: [String: AutomationValue] = [:]
    for (id, output) in outputs {
      var fields: [String: AutomationValue] = ["text": .string(output.text)]
      if let json = output.json { fields["json"] = json }
      steps[id] = .object(fields)
    }
    let inputsJSON = AutomationValue.object(setup.inputs).json
    let stepsJSON = AutomationValue.object(steps).json
    let inputsFile = setup.runDirectory + "/inputs.json"
    let stepsFile = setup.runDirectory + "/steps.json"
    var variables = ["GLANCE_RUN_DIR": setup.runDirectory, "GLANCE_AUTOMATION_DIR": setup.automationDirectory,
                     "GLANCE_INPUTS_FILE": inputsFile, "GLANCE_STEPS_FILE": stepsFile]
    if inputsJSON.utf8.count <= Self.inlineLimit { variables["GLANCE_INPUTS"] = inputsJSON }
    if stepsJSON.utf8.count <= Self.inlineLimit { variables["GLANCE_STEPS"] = stepsJSON }
    return (variables, [inputsFile: inputsJSON, stepsFile: stepsJSON])
  }

  /// A step that failed; if the user had asked to cancel, the run ends cancelled all the same.
  mutating func failed(_ step: String, _ text: String, _ result: AutomationStepResult) -> [Effect] {
    if !cancelRequested { failedStep = step }
    return [.log(.stepEnd(step: step, status: .failed, text: text, json: nil, durationMs: result.durationMs,
                          costUSD: result.costUSD))] + end(cancelRequested ? .cancelled : .failed)
  }

  /// A template that didn't render: the step starts and fails at once, so the log shows where.
  mutating func failedToPlan(_ step: String, _ message: String) -> [Effect] {
    failedStep = step
    return [.log(.stepStart(step: step)),
            .log(.stepEnd(step: step, status: .failed, text: message, json: nil, durationMs: 0, costUSD: nil))]
      + end(.failed)
  }

  mutating func end(_ final: RunRecord.Status) -> [Effect] {
    status = final
    current = nil
    active = nil
    pending = nil
    asking = nil
    return [.log(.runEnd(status: final)), .end(final)]
  }
}

extension RunLogEvent {
  /// One line for `glance automation run|serve`: "step.end fix ok $0.0420: Pushed a fix." (line breaks shown as ⏎,
  /// texts cut at 200 characters).
  public var summary: String {
    func flat(_ text: String) -> String {
      let line = text.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎")
      return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
    switch self {
    case .runStart(let trigger, _, let inputs, let version):
      return "run.start v\(version) \(trigger) \(AutomationValue.object(inputs).json)"
    case .stepStart(let step):
      return "step.start \(step)"
    case .stepOutput(let step, let chunk):
      return "step.output \(step): \(flat(chunk))"
    case .stepTool(let step, let name):
      return "step.tool \(step): \(name)"
    case .stepEnd(let step, let status, let text, _, _, let cost):
      let price = cost.map { String(format: " $%.4f", $0) } ?? ""
      return "step.end \(step) \(status.rawValue)\(price)" + (text.isEmpty ? "" : ": \(flat(text))")
    case .runPark(let step):
      return "run.park \(step)"
    case .runResume(let step, let decision):
      return "run.resume \(step) \(decision.rawValue)"
    case .runAsk(let question):
      let choices = question.choices.isEmpty ? "" : " [\(question.choices.joined(separator: " | "))]"
      return "run.ask \(question.step): \(flat(question.question))\(choices)"
    case .runAnswer(let step, let answer):
      return "run.answer \(step) \(answer.via.rawValue): \(flat(answer.answer))"
    case .runEnd(let status):
      return "run.end \(status.rawValue)"
    }
  }
}
