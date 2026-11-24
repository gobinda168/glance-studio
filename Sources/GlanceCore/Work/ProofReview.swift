import Foundation

/// Facts from outside the record that change its review: the worktree and the PR.
public struct ProofFacts: Equatable, Sendable {
  public var uncommitted: Bool
  public var prChecksFailing: Bool
  public var prMerged: Bool
  public init(uncommitted: Bool = false, prChecksFailing: Bool = false, prMerged: Bool = false) {
    self.uncommitted = uncommitted; self.prChecksFailing = prChecksFailing; self.prMerged = prMerged
  }
}

public struct ProofGap: Equatable, Sendable {
  public enum Level: Sendable { case crit, warn, info }
  public var level: Level
  public var text: String
  public init(level: Level, text: String) { self.level = level; self.text = text }
}

public enum ProofPill: Equatable, Sendable {
  case merged, needsWork, notTested, ready, inProgress
  public var label: String {
    switch self {
    case .merged: "Merged"
    case .needsWork: "Needs work"
    case .notTested: "Not tested"
    case .ready: "Ready to merge"
    case .inProgress: "In progress"
    }
  }
}

/// Gaps and the verdict pill (spec §3 "Gaps"; rules and copy from the signed-off replica's SV.gaps / SV.verdictPill).
/// Computed, never stored. A check that is still running is status, not a gap.
public enum ProofReview {
  /// The latest run of a check in an environment. Runs at the same instant resolve by array order: the later entry wins
  /// (`checks` is append-ordered), the same rule `latestRuns` uses.
  public static func latest(_ record: WorkRecord, name: String, environment: String?) -> ProofCheckRun? {
    record.checks.filter { $0.name == name && $0.environment == environment }
      .reduce(nil) { best, run in best.map { run.at >= $0.at ? run : $0 } ?? run }
  }

  /// The latest run of each check x environment, oldest first (equal times keep array order).
  public static func latestRuns(_ record: WorkRecord) -> [ProofCheckRun] {
    struct Key: Hashable { var name: String; var environment: String? }
    var winners: [Key: (index: Int, run: ProofCheckRun)] = [:]
    for (index, run) in record.checks.enumerated() {
      let key = Key(name: run.name, environment: run.environment)
      if let old = winners[key], old.run.at > run.at { continue }
      winners[key] = (index, run)
    }
    return winners.values.sorted { ($0.run.at, $0.index) < ($1.run.at, $1.index) }.map(\.run)
  }

  /// Whether `text` says tests or checks pass. Judged sentence by sentence (split at . ; ! ? and line breaks). A claim is
  /// the noun-then-pass phrase ("all tests pass") with nothing negating it: no negation or failure word inside the
  /// phrase itself ("tests no longer pass", "Tests: 3 failed, 4 passed") and none right after it ("tests pass no
  /// longer"). What follows a comma, "with" or "and" ("tests pass, no regressions", "tests pass with no errors") is
  /// about something else. "0 failed" / "0 failing" is not a failure.
  public static func claimsPass(_ text: String) -> Bool {
    text.components(separatedBy: CharacterSet(charactersIn: ".;!?\n")).contains { sentence in
      let sentence = sentence.replacingOccurrences(of: #"\b0\s+(failed|failing|failures?|errors?)\b"#, with: "",
                                                    options: [.regularExpression, .caseInsensitive])
      guard let regex = passRegex, let negated = negationRegex, let trailing = trailingNegationRegex,
            let leading = leadingNegationRegex else { return false }
      let whole = NSRange(sentence.startIndex..., in: sentence)
      return regex.matches(in: sentence, range: whole).contains { match in
        guard let range = Range(match.range, in: sentence) else { return false }
        let phrase = String(sentence[range])
        let before = String(sentence[..<range.lowerBound])
        let after = String(sentence[range.upperBound...])
        return leading.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) == nil
          && negated.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)) == nil
          && trailing.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) == nil
      }
    }
  }

  private static let passRegex = try? NSRegularExpression(
    pattern: #"\b(tests?|checks?|specs?|suites?)\b[^.\n]{0,20}\b(pass|passes|passed|passing|green)\b"#, options: .caseInsensitive)
  private static let negationRegex = try? NSRegularExpression(
    pattern: #"\b(no|not|never|cannot|without|fail\w*|broke\w*|broken|errors?|errored)\b|n['’]t\b"#, options: .caseInsensitive)
  /// "no tests pass": a negation just before the phrase.
  private static let leadingNegationRegex = try? NSRegularExpression(
    pattern: #"\b(no|not|never|without)\s+(\w+\s+)?$"#, options: .caseInsensitive)
  /// "tests pass no longer" / "pass not": a negation straight after the pass word (a comma ends the thought).
  private static let trailingNegationRegex = try? NSRegularExpression(
    pattern: #"^\s*(no longer|not|never|anymore)\b"#, options: .caseInsensitive)

  public static let uncommittedText = "Uncommitted changes"

  public static func gaps(_ record: WorkRecord, setup: ProofSetup?, facts: ProofFacts) -> [ProofGap] {
    var out: [ProofGap] = []
    // Only what Claude concluded counts as a claim (not tries or problems), and only when a setup exists: without one
    // no run is ever recorded, so the claim could never be backed.
    let claims = (record.verdict?.reasons ?? [])
      + record.notes.filter { $0.kind == .found || $0.kind == .resolved }.map(\.text)
    if setup != nil, claims.contains(where: claimsPass), !record.checks.contains(where: \.ok) {
      out.append(ProofGap(level: .crit, text: "Claude says tests pass, but no test run was seen"))
    }
    for requirement in setup?.required ?? [] {
      guard let (name, env) = ProofSetup.requirement(requirement) else { continue }
      if let run = latest(record, name: name, environment: env) {
        if !run.ok { out.append(ProofGap(level: .crit, text: "\(name) on \(env) failed on its last run")) }
      } else {
        out.append(ProofGap(level: .warn, text: "\(name) on \(env) not run yet"))
      }
    }
    if facts.prChecksFailing { out.append(ProofGap(level: .crit, text: "PR checks failing")) }
    if facts.uncommitted { out.append(ProofGap(level: .info, text: uncommittedText)) }
    let open = record.pending.filter { !$0.done }.count
    if open > 0 { out.append(ProofGap(level: .info, text: "\(open) pending \(open == 1 ? "item" : "items")")) }
    return out
  }

  public static func pill(_ record: WorkRecord, setup: ProofSetup?, facts: ProofFacts) -> ProofPill {
    if facts.prMerged { return .merged }
    let verdict = record.verdict?.verdict
    if facts.prChecksFailing { return .needsWork }
    if latestRuns(record).contains(where: { !$0.ok }) || verdict == .hold || verdict == .notReady { return .needsWork }
    if record.checks.isEmpty { return .notTested }
    // Ready needs the setup: without one (missing, invalid, a removed worktree) the required checks can't be verified.
    if verdict == .merge, setup != nil, gaps(record, setup: setup, facts: facts).isEmpty { return .ready }
    return .inProgress
  }
}
