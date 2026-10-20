import Foundation

/// The setup steps of the first launch, in order. Each one lights its quarter of the dial when done.
public enum OnboardingStep: Int, CaseIterable, Sendable {
  case claude, permissions, voice, accounts

  /// The dial's quarter, clockwise from twelve o'clock.
  public var quarter: Int { rawValue }

  /// The orb's colour while the step shows: Claude Code is looked for (thinking), permissions read the Mac (reading),
  /// the voice speaks and accounts are calm (coral).
  public func mood(checking: Bool) -> FirstLightScene.Mood {
    switch self {
    case .claude: checking ? .thinking : .calm
    case .permissions: .reading
    case .voice, .accounts: .calm
    }
  }
}

/// Where the first launch is (spec 2026-10-10-first-light-onboarding-design.md): the intro, a step, or the finish.
public struct OnboardingFlow: Equatable, Sendable {
  /// Bump to show a new onboarding to everyone once more.
  public static let version = 1

  public enum Phase: Equatable, Sendable {
    case intro
    case step(OnboardingStep)
    case finish
  }

  public private(set) var phase = Phase.intro
  public private(set) var done: Set<OnboardingStep> = []

  public init() {}

  /// Onboarding shows when the one the user last finished (or skipped) is older than this one.
  public static func isPending(completedVersion: Int) -> Bool {
    completedVersion < version
  }

  public mutating func begin() {
    phase = .step(.claude)
  }

  /// To the next step, or the finish after the last.
  public mutating func next() {
    switch phase {
    case .intro: begin()
    case .step(let step):
      phase = OnboardingStep(rawValue: step.rawValue + 1).map(Phase.step) ?? .finish
    case .finish: break
    }
  }

  public mutating func back() {
    switch phase {
    case .intro: break
    case .step(let step):
      phase = OnboardingStep(rawValue: step.rawValue - 1).map(Phase.step) ?? .intro
    case .finish: phase = .step(.accounts)
    }
  }

  /// Marks a step finished or not: a grant revoked in System Settings while the step shows puts it back.
  public mutating func setDone(_ step: OnboardingStep, _ isDone: Bool) {
    if isDone { done.insert(step) } else { done.remove(step) }
  }

  public var step: OnboardingStep? {
    if case .step(let step) = phase { step } else { nil }
  }

  /// "1 of 4" style position for the step that shows.
  public var position: (index: Int, count: Int)? {
    step.map { ($0.rawValue + 1, OnboardingStep.allCases.count) }
  }

  public var litQuarters: [Bool] {
    OnboardingStep.allCases.map { done.contains($0) }
  }

  /// What the orb says on the Voice step, by first name when the Mac account has one.
  public static func greeting(name: String?) -> String {
    let hello = name.map { "Hi \($0)." } ?? "Hi."
    return "\(hello) I'm Glance. When Claude finishes a reply, I'll read it to you, and draw what it explains."
  }
}

/// Whether Claude Code is signed in, from `~/.claude.json`: its `oauthAccount` holds the claude.ai account once
/// `claude` has been logged in. Returns the account's email, "" when signed in without one, nil when not signed in.
public enum ClaudeAccount {
  public static func signedIn(claudeJSON data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let account = object["oauthAccount"] as? [String: Any], !account.isEmpty else { return nil }
    return account["emailAddress"] as? String ?? ""
  }

  /// `claude --version` prints "2.1.4 (Claude Code)"; the number alone.
  public static func version(fromOutput output: String) -> String? {
    let first = output.split(whereSeparator: \.isWhitespace).first.map(String.init)
    guard let first, first.first?.isNumber == true else { return nil }
    return first
  }
}
