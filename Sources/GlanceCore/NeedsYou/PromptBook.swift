import Foundation

/// What a Claude Code dialog asks for, from the tool that's waiting.
public enum PromptKind: String, Equatable, Sendable {
  case permission, question, plan

  public init(tool: String) {
    switch tool {
    case "AskUserQuestion": self = .question
    case "ExitPlanMode": self = .plan
    default: self = .permission
    }
  }
}

/// A split whose Claude is waiting on the user: the waiting tool call and the dialog on screen.
public struct PendingPrompt: Equatable, Identifiable, Sendable {
  public let surface: String
  public let cwd: String
  public let call: ToolCall
  public var screen: DialogScreen
  public let created: Date

  public var id: String { surface }
  public var kind: PromptKind { PromptKind(tool: call.name) }
  public var project: String { (cwd as NSString).lastPathComponent }

  public init(surface: String, cwd: String, call: ToolCall, screen: DialogScreen, created: Date) {
    self.surface = surface
    self.cwd = cwd
    self.call = call
    self.screen = screen
    self.created = created
  }
}

/// Spec 2026-10-11-needs-input-orb-design.md §1: a prompt exists only while the transcript has an unsettled tool call
/// AND the split shows a dialog. One prompt per split.
public struct PromptBook: Equatable, Sendable {
  public struct Waiting: Equatable, Sendable {
    public let file: String
    public let cwd: String?
    public let call: ToolCall
    public let since: Date
  }

  /// A call unsettled this long is forgotten (its session died without a result).
  public static let maxWait: TimeInterval = 30 * 60

  public private(set) var waiting: [Waiting] = []
  public private(set) var prompts: [String: PendingPrompt] = [:]

  public init() {}

  public var ordered: [PendingPrompt] {
    prompts.values.sorted { ($0.created, $0.surface) < ($1.created, $1.surface) }
  }

  public mutating func tool(_ event: ToolEvent, file: String, now: Date) {
    switch event.kind {
    case .pending(let call):
      guard !waiting.contains(where: { $0.call.id == call.id }) else { return }
      waiting.append(Waiting(file: file, cwd: event.cwd, call: call, since: now))
    case .settled(let id):
      waiting.removeAll { $0.call.id == id }
      prompts = prompts.filter { $0.value.call.id != id }
    }
  }

  /// A new prompt or a finished turn in that transcript: none of its calls waits any more.
  public mutating func turn(file: String) {
    let ids = Set(waiting.filter { $0.file == file }.map(\.call.id))
    guard !ids.isEmpty else { return }
    waiting.removeAll { $0.file == file }
    prompts = prompts.filter { !ids.contains($0.value.call.id) }
  }

  /// The folders whose splits' screens need reading.
  public func folders(now: Date) -> [String] {
    var seen: [String] = []
    for wait in waiting where now.timeIntervalSince(wait.since) <= Self.maxWait {
      if let cwd = wait.cwd, !seen.contains(cwd) { seen.append(cwd) }
    }
    return seen
  }

  public mutating func expire(now: Date) {
    let old = Set(waiting.filter { now.timeIntervalSince($0.since) > Self.maxWait }.map(\.call.id))
    guard !old.isEmpty else { return }
    waiting.removeAll { old.contains($0.call.id) }
    prompts = prompts.filter { !old.contains($0.value.call.id) }
  }

  /// What a split shows now (`text` nil: the split is gone). True when its prompt changed.
  @discardableResult
  public mutating func screen(surface: String, cwd: String?, text: String?, now: Date) -> Bool {
    let before = prompts[surface]
    guard let text, let cwd, let dialog = PromptScreen.parse(text), let wait = call(for: surface, in: cwd) else {
      prompts[surface] = nil
      return before != nil
    }
    let created = before?.call.id == wait.call.id ? before?.created ?? now : now
    let prompt = PendingPrompt(surface: surface, cwd: cwd, call: wait.call, screen: dialog, created: created)
    prompts[surface] = prompt
    return before != prompt
  }

  /// The newest waiting call in this folder that no other split's prompt already holds (two sessions in one folder).
  private func call(for surface: String, in cwd: String) -> Waiting? {
    let matching = waiting.filter { wait in wait.cwd.map { FolderOwnership.isOwned($0, by: [cwd]) } ?? false }
    if let current = prompts[surface], let kept = matching.first(where: { $0.call.id == current.call.id }) { return kept }
    let held = Set(prompts.filter { $0.key != surface }.map(\.value.call.id))
    return matching.last { !held.contains($0.call.id) } ?? matching.last
  }
}
