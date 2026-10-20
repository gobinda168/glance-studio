import Foundation

/// Automations' cards in the Notifications inbox (spec "Approvals" and "Failures"): a run parked at an outward step,
/// a failed run, a run that couldn't start, a watcher that gave up. Every card about one run shares its thread.
public enum AutomationNotices {
  /// The buttons, by id (`NotificationHub.onAction` hands the id back).
  public enum Action: String, CaseIterable, Sendable {
    case approve
    case skip
    case trust
    case openRun = "open-run"
    case askClaude = "ask-claude"
    case enable

    public var title: String {
      switch self {
      case .approve: "Approve"
      case .skip: "Skip"
      case .trust: "Trust this automation"
      case .openRun: "Open run"
      case .askClaude: "Ask Claude to fix"
      case .enable: "Turn back on"
      }
    }

    var button: Notice.Action { Notice.Action(id: rawValue, title: title) }
  }

  public static func threadKey(_ ref: AutomationRunRef) -> String { "automations:\(ref)" }

  /// The run a card is about (its meta); nil for a card that isn't about one run.
  public static func ref(_ notice: Notice) -> AutomationRunRef? {
    guard notice.source == .automations, let automation = notice.meta["automation"],
          let run = notice.meta["run"] else { return nil }
    return AutomationRunRef(automation: automation, run: run)
  }

  /// "Fix red CI — wants to run comment", the rendered command and stdin (first 600 characters in `meta["detail"]`;
  /// the inbox row shows one line), Approve / Skip / Trust this automation.
  public static func parked(name: String, ref: AutomationRunRef, plan: AutomationStepPlan, date: Date) -> Notice {
    Notice(id: "automations:park:\(ref):\(plan.step)", source: .automations, kind: .automationApproval, title: name,
           place: "wants to run \(plan.step)", preview: plan.preview, date: date, threadKey: threadKey(ref),
           target: .none,
           meta: ["automation": ref.automation, "run": ref.run, "step": plan.step, "detail": plan.preview],
           actions: [Action.approve.button, Action.skip.button, Action.trust.button])
  }

  /// An agent's ask step is waiting on the user: the question (and what it says about it), Open run, where it is
  /// answered by a click or by typing.
  public static func asked(name: String, ref: AutomationRunRef, question: AutomationQuestion, date: Date) -> Notice {
    let detail = [question.question, question.body].compactMap { $0 }.joined(separator: "\n\n")
    return Notice(id: "automations:ask:\(ref):\(question.step)", source: .automations, kind: .automationApproval,
                  title: name, place: "is asking you", preview: question.question, date: date,
                  threadKey: threadKey(ref), target: .none,
                  meta: ["automation": ref.automation, "run": ref.run, "step": question.step, "detail": detail],
                  actions: [Action.openRun.button])
  }

  /// A run that ended failed (or expired waiting): the step and its last 20 output lines, Open run / Ask Claude to fix.
  public static func failed(name: String, ref: AutomationRunRef, step: String?, output: String,
                            status: RunRecord.Status, date: Date) -> Notice {
    let place: String
    switch status {
    case .expired: place = "expired waiting for approval" + (step.map { " at \($0)" } ?? "")
    case .interrupted: place = "stopped when Studio quit"
    default: place = "failed" + (step.map { " at \($0)" } ?? "")
    }
    let lines = AutomationStepResult.lastLines(AutomationStepResult.trimmed(output), count: 20)
    return Notice(id: "automations:failed:\(ref)", source: .automations, kind: .automationFailed, title: name,
                  place: place, preview: lines.isEmpty ? place : lines, date: date, threadKey: threadKey(ref),
                  target: .none,
                  meta: ["automation": ref.automation, "run": ref.run, "step": step ?? "", "detail": lines],
                  actions: [Action.openRun.button, Action.askClaude.button])
  }

  /// A trigger fired but the run couldn't start (its inputs didn't resolve): no run, so no log; this card says why.
  public static func couldNotStart(name: String, automation: String, trigger: String, problems: [AutomationProblem],
                                   date: Date) -> Notice {
    let text = problems.map(\.description).joined(separator: "\n")
    return Notice(id: "automations:start:\(automation):\(date.timeIntervalSince1970)", source: .automations,
                  kind: .automationFailed, title: name, place: "couldn't start from \(trigger)", preview: text,
                  date: date, threadKey: "automations:\(automation):start", target: .none,
                  meta: ["automation": automation, "detail": text])
  }

  /// A watcher crashed 5 times in 10 minutes: its last stderr lines, Turn back on.
  public static func watcherBroken(name: String, automation: String, stderr: String, date: Date) -> Notice {
    let lines = AutomationStepResult.lastLines(AutomationStepResult.trimmed(stderr), count: 20)
    return Notice(id: "automations:watcher:\(automation):\(date.timeIntervalSince1970)", source: .automations,
                  kind: .automationFailed, title: name, place: "its watcher stopped after 5 crashes in 10 minutes",
                  preview: lines.isEmpty ? "The watcher printed nothing on stderr." : lines, date: date,
                  threadKey: "automations:\(automation):watcher", target: .none,
                  meta: ["automation": automation, "detail": lines], actions: [Action.enable.button])
  }
}
