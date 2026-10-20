import Foundation

/// The New pull request page's three automation switches (spec 2026-10-09-automations-design.md, stage A5): each
/// installs and switches on one automation per repository, made from the starters (`AutomationStarters`).
public enum AutomationPRKit: String, CaseIterable, Sendable {
  case review
  case watch
  case fixCI

  /// The switch's state, from the automation's entry.
  public enum State: Equatable, Sendable {
    /// Not installed, or switched off.
    case off
    /// Installed, switched on and approved: its watcher runs.
    case on
    /// Installed and switched on, but this version isn't approved (a hand edit, or Claude changed it).
    case needsApproval
    case broken(String)
  }

  public var title: String {
    switch self {
    case .review: "Claude Code Review"
    case .watch: "Watch for CI and review comments"
    case .fixCI: "Let Claude fix red CI"
    }
  }

  /// What it does, under the title.
  public var subtitle: String {
    switch self {
    case .review: "Reviews on open and every push"
    case .watch: "A notification when checks fail or someone comments"
    case .fixCI: "Claude fixes the branch; you approve the push"
    }
  }

  var prefix: String {
    switch self {
    case .review: "pr-review-"
    case .watch: "pr-watch-"
    case .fixCI: "pr-fix-ci-"
    }
  }

  /// owner/name as GitHub allows them.
  public static func isRepository(_ text: String) -> Bool {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2 && parts.allSatisfy { part in
      !part.isEmpty && part != "." && part != ".."
        && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
  }

  /// "acme/My.App" → "acme-my-app".
  static func slug(_ repository: String) -> String {
    var slug = ""
    for character in repository.lowercased() {
      let keep = character.isASCII && (character.isLetter || character.isNumber)
      if keep { slug.append(character) } else if !slug.hasSuffix("-"), !slug.isEmpty { slug.append("-") }
    }
    while slug.hasSuffix("-") { slug.removeLast() }
    return slug
  }

  /// The automation's id for `repository` ("pr-fix-ci-acme-app"), at most 48 characters; nil when it isn't owner/name.
  public func id(repository: String) -> String? {
    guard Self.isRepository(repository) else { return nil }
    var id = String((prefix + Self.slug(repository)).prefix(48))
    while id.hasSuffix("-") { id.removeLast() }
    return id
  }

  public func name(repository: String) -> String {
    switch self {
    case .review: "Claude Code Review: \(repository)"
    case .watch: "Watch CI and reviews: \(repository)"
    case .fixCI: "Fix red CI: \(repository)"
    }
  }

  /// The package to save for `repository`; `folder` is its local clone (Fix red CI works in a worktree of it).
  public func files(repository: String, folder: String) -> [String: String]? {
    guard let id = id(repository: repository) else { return nil }
    switch self {
    case .review: return AutomationStarters.review(id: id, name: name(repository: repository), repository: repository)
    case .watch:
      return AutomationStarters.watch(id: id, name: name(repository: repository), repository: repository, only: "all")
    case .fixCI:
      return AutomationStarters.fixCI(id: id, name: name(repository: repository), repository: repository,
                                      folder: folder)
    }
  }

  public static func state(_ entry: AutomationEntry?) -> State {
    guard let entry else { return .off }
    if entry.isBroken { return .broken(entry.brokenLine ?? "Broken") }
    guard entry.enabled else { return .off }
    return entry.approval.isApproved ? .on : .needsApproval
  }

  /// The line under the title.
  public func caption(_ state: State) -> String {
    switch state {
    case .off, .on: subtitle
    case .needsApproval: "Changed since you approved it: approve it in Automations"
    case .broken(let line): line
    }
  }
}
