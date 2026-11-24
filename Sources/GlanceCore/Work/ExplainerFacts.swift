import Foundation

/// What Glance saw in a turn, from the transcript and the proof record, never from Claude's page: what you can trust if
/// a page simplifies (spec 2026-11-03-explainer-mode-design.md §7).
public struct ExplainerFacts: Equatable, Sendable {
  public struct Check: Equatable, Sendable {
    public let name: String
    public let passed: Bool
  }

  public var files = 0
  public var added = 0
  public var removed = 0
  public var commands = 0
  public var failedCommands = 0
  public var checks: [Check] = []

  public var isEmpty: Bool { files == 0 && commands == 0 && checks.isEmpty }

  public init(turn: ReplyTurn, checks runs: [ProofCheckRun]) {
    var paths = Set<String>(), ids = Set<String>()
    for row in turn.rows {
      guard case .tool(_, let kind, let result, _) = row.kind else { continue }
      ids.insert(row.id)
      switch kind {
      case .edit(let path, let diff):
        paths.insert(path)
        let counts = TimelineLayout.counts(diff)
        added += counts.added
        removed += counts.removed
      case .write(let path, let lines):
        paths.insert(path)
        added += lines
      case .bash:
        commands += 1
        if let result, result.isError || (result.exitCode ?? 0) != 0 { failedCommands += 1 }
      default: break
      }
    }
    files = paths.count
    checks = runs.filter { ids.contains($0.id) }.map { Check(name: $0.name, passed: $0.ok) }
  }
}
