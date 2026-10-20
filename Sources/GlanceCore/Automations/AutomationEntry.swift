import Foundation

/// One run, wherever it is named: the automation and the run's id (its log's file name without ".jsonl").
public struct AutomationRunRef: Hashable, Codable, Sendable, CustomStringConvertible {
  public var automation: String
  public var run: String

  public init(automation: String, run: String) {
    self.automation = automation
    self.run = run
  }

  /// "fix-red-ci/2026-10-09T09-00-00.120Z".
  public var description: String { "\(automation)/\(run)" }
}

/// One automation as the engine (and the A3 side bar) sees it: its manifest or why it is broken, the user's approval,
/// the switches, and its last run.
public struct AutomationEntry: Equatable, Identifiable, Sendable {
  /// The folder's name.
  public var id: String
  /// nil when automation.json doesn't read.
  public var manifest: AutomationManifest?
  /// Validation's problems (`AutomationCheck`); any problem makes it broken and disarms its triggers.
  public var problems: [AutomationProblem]
  public var readme: String
  public var approval: AutomationApprovalStatus
  public var enabled: Bool
  public var trusted: Bool
  public var lastRun: RunRecord?
  /// A watcher that gave up (5 crashes in 10 minutes): its last stderr lines. Cleared by switching it on again.
  public var brokenWatcher: String?

  public init(id: String, manifest: AutomationManifest?, problems: [AutomationProblem], readme: String = "",
              approval: AutomationApprovalStatus = .never, enabled: Bool = true, trusted: Bool = false,
              lastRun: RunRecord? = nil, brokenWatcher: String? = nil) {
    self.id = id
    self.manifest = manifest
    self.problems = problems
    self.readme = readme
    self.approval = approval
    self.enabled = enabled
    self.trusted = trusted
    self.lastRun = lastRun
    self.brokenWatcher = brokenWatcher
  }

  public var name: String { manifest?.name ?? id }
  public var isBroken: Bool { manifest == nil || !problems.isEmpty }
  /// Its triggers fire: valid, enabled and approved.
  public var armed: Bool { !isBroken && enabled && approval.isApproved }
  /// The side bar row's "Broken: <first problem>".
  public var brokenLine: String? { problems.first.map { "Broken: \($0)" } ?? (manifest == nil ? "Broken" : nil) }
  /// The last run failed: the row is red.
  public var lastRunFailed: Bool { [.failed, .expired, .interrupted].contains(lastRun?.status) }
}

/// What a trigger (or the user) started a run with: the run log's trigger line, the trigger's payload
/// (`{{trigger.…}}`), and the trigger's own inputs (string values are templates over the payload).
public struct AutomationFire: Equatable, Sendable {
  public var summary: String
  public var payload: AutomationValue?
  public var inputs: [String: AutomationValue]

  public init(summary: String, payload: AutomationValue? = nil, inputs: [String: AutomationValue] = [:]) {
    self.summary = summary
    self.payload = payload
    self.inputs = inputs
  }

  public static let manual = AutomationFire(summary: "manual")

  public static func trigger(_ trigger: AutomationTrigger, payload: AutomationValue?) -> AutomationFire {
    AutomationFire(summary: trigger.summary, payload: payload, inputs: trigger.inputs ?? [:])
  }

  /// Another automation's `automation` step.
  public static func nested(caller: String) -> AutomationFire { AutomationFire(summary: "automation \(caller)") }

  /// The run's inputs: the trigger's inputs (rendered against the payload), then the given ones over them, then
  /// `resolveInputs` (types, defaults, required).
  public func inputs(for manifest: AutomationManifest, given: [String: AutomationValue])
    -> (values: [String: AutomationValue], problems: [AutomationProblem]) {
    var merged: [String: AutomationValue] = [:]
    var problems: [AutomationProblem] = []
    let context = AutomationTemplateContext(inputs: [:], trigger: payload, runDir: "", automationDir: "")
    for (name, value) in inputs.sorted(by: { $0.key < $1.key }) {
      do throws(AutomationTemplateError) {
        merged[name] = try AutomationTemplate.render(value, context)
      } catch {
        problems.append(AutomationProblem("trigger.inputs.\(name)", error.message))
      }
    }
    merged.merge(given) { $1 }
    let resolved = manifest.resolveInputs(merged)
    return (resolved.values, problems + resolved.problems)
  }
}

/// What asking for a run got.
public enum AutomationRunStart: Equatable, Sendable {
  case started(AutomationRunRef)
  /// Another run of it is going; this one waits (1 is next).
  case queued(Int)
  /// Not started: why, in plain words ("Approve Fix red CI first", "inputs.repo: is required").
  case refused(String)
}

/// A run in progress, for the side bar's live state and `automation_runs`.
public struct AutomationLiveRun: Equatable, Sendable {
  public var ref: AutomationRunRef
  public var name: String
  public var trigger: String
  public var startedAt: Date
  /// The step running or waiting.
  public var step: String?
  public var parked: Bool
  /// The question it waits on (an ask step); `parked` is true too.
  public var question: AutomationQuestion?

  public init(ref: AutomationRunRef, name: String, trigger: String, startedAt: Date, step: String? = nil,
              parked: Bool = false, question: AutomationQuestion? = nil) {
    self.ref = ref
    self.name = name
    self.trigger = trigger
    self.startedAt = startedAt
    self.step = step
    self.parked = parked
    self.question = question
  }
}

/// A "Needs you" row (spec "The UI": parked runs, unapproved changes, broken watchers) and broken manifests.
public enum AutomationNeed: Equatable, Sendable {
  case parked(AutomationRunRef, step: String)
  /// A run waiting on the user's answer to an ask step's question.
  case question(AutomationRunRef, AutomationQuestion)
  /// Never approved (the lines say what approving allows) or changed since (the lines say what changed).
  case approval(automation: String, lines: [String])
  case brokenWatcher(automation: String, stderr: String)
  case broken(automation: String, problem: String)

  public var automation: String {
    switch self {
    case .parked(let ref, _), .question(let ref, _): ref.automation
    case .approval(let id, _), .brokenWatcher(let id, _), .broken(let id, _): id
    }
  }

  /// Parked runs first (they block work), then broken watchers, broken manifests, approvals; by automation id inside.
  public static func make(_ entries: [AutomationEntry], live: [AutomationLiveRun]) -> [AutomationNeed] {
    var needs = live.filter(\.parked).sorted { $0.ref.description < $1.ref.description }
      .map { run in
        run.question.map { AutomationNeed.question(run.ref, $0) } ?? AutomationNeed.parked(run.ref, step: run.step ?? "")
      }
    let sorted = entries.sorted { $0.id < $1.id }
    needs += sorted.compactMap { entry in entry.brokenWatcher.map { .brokenWatcher(automation: entry.id, stderr: $0) } }
    needs += sorted.compactMap { entry in
      entry.isBroken ? .broken(automation: entry.id, problem: entry.problems.first?.description ?? "doesn't read")
        : nil
    }
    for entry in sorted where !entry.isBroken && entry.enabled {
      guard let manifest = entry.manifest else { continue }
      switch entry.approval {
      case .approved: break
      case .changed(let lines): needs.append(.approval(automation: entry.id, lines: lines))
      case .never: needs.append(.approval(automation: entry.id, lines: AutomationApproval.summary(manifest)))
      }
    }
    return needs
  }
}
