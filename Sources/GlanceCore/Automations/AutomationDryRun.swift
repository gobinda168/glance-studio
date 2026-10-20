import Foundation

/// The pipeline walked without running anything (`glance automation check`): every template rendered in order with
/// sample inputs, each step's output a stand-in — "<claude:fix>" for a Claude step, "<run:log>" for a script or
/// command, "<automation:digest>" for a nested automation; an ask step answers with its first choice (or
/// "<ask:propose>"). Outward steps are marked, never run.
public struct AutomationDryRun: Equatable, Sendable {
  public struct Step: Equatable, Sendable {
    public var id: String
    /// Its `if` rendered falsy.
    public var skipped: Bool
    public var outward: Bool
    /// The rendered command line (values shell-quoted), for `zsh -n`; nil unless it's a command step.
    public var command: String?
    /// What would run: the command line, the script's path, the rendered prompt, or "<id> <inputs JSON>".
    public var detail: String
    public var cwd: String?
    public var stdin: String?
  }

  public var steps: [Step]
  /// Templates that didn't render.
  public var problems: [AutomationProblem]
}

extension AutomationManifest {
  public static let dryRunDirectory = "/tmp/glance-dry-run"

  /// `prompts`: prompt files' text by package path. `inputs` should come from `sampleInputs` (or `resolveInputs`).
  public func dryRun(inputs: [String: AutomationValue], prompts: [String: String],
                     automationDirectory: String) -> AutomationDryRun {
    var context = AutomationTemplateContext(inputs: inputs, runDir: Self.dryRunDirectory,
                                            automationDir: automationDirectory, dryRun: true)
    var steps: [AutomationDryRun.Step] = []
    var problems: [AutomationProblem] = []
    func render(_ template: String?, at location: String, quoting: AutomationTemplate.Quoting = .none) -> String? {
      guard let template else { return nil }
      do throws(AutomationTemplateError) {
        return try AutomationTemplate.render(template, context, quoting: quoting)
      } catch {
        problems.append(AutomationProblem(location, error.message))
        return nil
      }
    }
    for (index, step) in self.steps.enumerated() {
      let path = "steps[\(index)]"
      guard let kind = step.kind else { continue }
      if let condition = render(step.condition, at: "\(path).if"), !AutomationTemplate.isTruthy(condition) {
        steps.append(AutomationDryRun.Step(id: step.id, skipped: true, outward: step.isOutward, command: nil,
                                           detail: "skipped: `if` rendered \"\(condition)\"", cwd: nil, stdin: nil))
        continue
      }
      var planned = AutomationDryRun.Step(id: step.id, skipped: false, outward: step.isOutward, command: nil,
                                          detail: "", cwd: render(step.cwd, at: "\(path).cwd"),
                                          stdin: render(step.stdin, at: "\(path).stdin"))
      let stand: String
      switch kind {
      case .command(let line):
        planned.command = render(line, at: "\(path).run", quoting: .shell)
        planned.detail = planned.command ?? line
        stand = "<run:\(step.id)>"
      case .script(let file):
        planned.detail = file
        stand = "<run:\(step.id)>"
      case .claude(let file):
        planned.detail = prompts[file].flatMap { render($0, at: file) } ?? file
        stand = "<claude:\(step.id)>"
      case .automation(let callee):
        var rendered: [String: AutomationValue] = [:]
        for (key, value) in step.inputs ?? [:] {
          do throws(AutomationTemplateError) {
            rendered[key] = try AutomationTemplate.render(value, context)
          } catch {
            problems.append(AutomationProblem("\(path).inputs.\(key)", error.message))
          }
        }
        planned.detail = "\(callee) \(AutomationValue.object(rendered).json)"
        stand = "<automation:\(step.id)>"
      case .ask(let ask):
        var answer = AutomationAnswer(answer: "<ask:\(step.id)>", via: .click)
        do throws(AutomationTemplateError) {
          let question = try ask.render(step: step.id, context)
          planned.detail = "ask: \(question.question)"
            + (question.choices.isEmpty ? "" : " [\(question.choices.joined(separator: " | "))]")
          if let first = AutomationAnswer.choice(0, of: question, via: .click) { answer = first }
        } catch {
          // Only a real run knows what an earlier step or the trigger said: choices built from a placeholder
          // can't be judged here.
          let judged: Bool = if case .invalid = error { !ask.readsRunData } else { true }
          if judged { problems.append(AutomationProblem("\(path).ask", error.message)) }
          planned.detail = "ask: \(ask.question)"
        }
        steps.append(planned)
        context.steps[step.id] = AutomationStepOutput(text: answer.answer, json: answer.json)
        continue
      }
      steps.append(planned)
      context.steps[step.id] = AutomationStepOutput(text: stand)
    }
    return AutomationDryRun(steps: steps, problems: problems)
  }
}
