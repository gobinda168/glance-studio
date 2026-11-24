import Foundation

/// Claude Code's permission modes. Bypass is one a session can be in but the composer never offers.
public enum PermissionMode: String, Equatable, Sendable {
  case manual, acceptEdits, plan, auto, bypass

  public static let menu: [PermissionMode] = [.manual, .acceptEdits, .plan, .auto]

  public var title: String {
    switch self {
    case .manual: "Manual"
    case .acceptEdits: "Accept edits"
    case .plan: "Plan"
    case .auto: "Auto"
    case .bypass: "Bypass permissions"
    }
  }

  /// What the composer's chip says: Auto is an effort too, so the mode says it's a mode.
  public var chip: String {
    switch self {
    case .auto, .plan: "\(title) mode"
    default: title
    }
  }

  public var summary: String {
    switch self {
    case .manual: "Asks before edits and commands"
    case .acceptEdits: "Edits freely, asks before commands"
    case .plan: "Reads and plans, changes nothing"
    case .auto: "Runs what its safety checks allow"
    case .bypass: "Runs everything without asking"
    }
  }

  /// A transcript's `permissionMode`; nil for one this version doesn't know.
  public init?(transcript: String) {
    switch transcript {
    case "default", "manual": self = .manual
    case "acceptEdits": self = .acceptEdits
    case "plan": self = .plan
    case "auto": self = .auto
    case "bypassPermissions": self = .bypass
    default: return nil
    }
  }
}

/// What a session's transcript says it runs with. Lags the terminal (the footer is live), and is all there is for the model.
public struct SessionSettings: Equatable, Sendable {
  /// A model id from a reply, or the display name a `/model` printed.
  public var model: String?
  public var effort: String?
  public var permissionMode: PermissionMode?

  public init(model: String? = nil, effort: String? = nil, permissionMode: PermissionMode? = nil) {
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
  }

  /// A `/model` or `/effort` command's output, when it says what was set.
  mutating func commandFinished(_ name: String, output: String) {
    switch name {
    case "/model": if let set = Self.first(#"^Set model to `?([^`]+?)`?(?: and |$)"#, in: output) { model = set }
    case "/effort": if let set = Self.first(#"^Set effort level to (\w+)"#, in: output) { effort = set }
    default: break
    }
  }

  private static func first(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
  }
}

/// The line Claude Code keeps under its prompt, read from the terminal's screen: the mode and effort as they are now.
public struct SessionFooter: Equatable, Sendable {
  public var mode: PermissionMode?
  public var effort: String?
  /// The model can't run in auto mode, so Shift+Tab skips it.
  public var autoUnavailable: Bool

  public init(mode: PermissionMode?, effort: String?, autoUnavailable: Bool = false) {
    self.mode = mode
    self.effort = effort
    self.autoUnavailable = autoUnavailable
  }

  /// How far up from the bottom of the screen the footer can be; above that it's scrollback.
  private static let linesSearched = 8
  private static let modeLine = try? NSRegularExpression(
    pattern: #"^\s*[⏸⏵]\S*\s+(manual mode|accept edits|plan mode|auto mode|bypass permissions) on\b"#)
  private static let effortMark = try? NSRegularExpression(pattern: #"\b(low|medium|high|xhigh|max) · /effort\b"#)

  /// Nil when the screen shows no footer: a dialog is up, or the user scrolled back.
  public static func parse(screen: String) -> SessionFooter? {
    let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let bottom = lines.reversed().drop { $0.allSatisfy(\.isWhitespace) }.prefix(linesSearched)
    for line in bottom {
      guard let mode = capture(modeLine, in: line).flatMap(mode(named:)) else { continue }
      return SessionFooter(mode: mode, effort: bottom.lazy.compactMap { capture(effortMark, in: $0) }.first,
                           autoUnavailable: bottom.contains { $0.contains("auto mode unavailable") })
    }
    return nil
  }

  private static func mode(named name: String) -> PermissionMode? {
    switch name {
    case "manual mode": .manual
    case "accept edits": .acceptEdits
    case "plan mode": .plan
    case "auto mode": .auto
    case "bypass permissions": .bypass
    default: nil
    }
  }

  private static func capture(_ regex: NSRegularExpression?, in line: String) -> String? {
    guard let match = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let range = Range(match.range(at: 1), in: line) else { return nil }
    return String(line[range])
  }
}

/// A running session has no command for its permission mode, only Shift+Tab cycling. So each press is checked against the
/// footer, and it stops rather than guess: a chip must never claim a mode Claude isn't in.
public enum ModeSwitch {
  public enum Step: Equatable, Sendable { case done, press, failed }

  /// More than any cycle has modes: it stops at the start mode first, unless the keys aren't landing.
  public static let maxPresses = 6

  public static func next(target: PermissionMode, start: PermissionMode?, seen: PermissionMode?, presses: Int) -> Step {
    guard let seen else { return .failed }
    if seen == target { return .done }
    // Back where it began: the target isn't in this session's cycle, and another press would leave it somewhere else.
    if presses > 0, seen == start { return .failed }
    return presses >= maxPresses ? .failed : .press
  }
}

/// What the composer's menus offer: `/model` and `/effort` take these without opening Claude Code's picker. Models are by
/// family, as Claude Code's aliases are, so the menu doesn't go stale when a version does.
public enum SessionPicks {
  public struct Model: Equatable, Sendable {
    public let title: String
    public let alias: String
    public var command: String { "/model \(alias)" }
  }

  public struct Effort: Equatable, Sendable {
    public let title: String
    public let level: String
    public let summary: String?
    public var command: String { "/effort \(level)" }
  }

  public static let models = [Model(title: "Opus", alias: "opus"), Model(title: "Sonnet", alias: "sonnet"),
                              Model(title: "Haiku", alias: "haiku"), Model(title: "Fable", alias: "fable")]

  public static let efforts = [Effort(title: "Auto", level: "auto", summary: "Claude Code's default"),
                               Effort(title: "Low", level: "low", summary: "Fastest"),
                               Effort(title: "Medium", level: "medium", summary: nil),
                               Effort(title: "High", level: "high", summary: nil),
                               Effort(title: "Extra high", level: "xhigh", summary: nil),
                               Effort(title: "Max", level: "max", summary: "Most thorough")]

  /// The alias of a model id ("claude-opus-5-5") or display name ("Opus 5.5").
  public static func family(of model: String) -> String? {
    let name = model.lowercased()
    return models.first { name.contains($0.alias) }?.alias
  }
}

extension TimelineRow.Kind {
  /// Whether this row is the queued text arriving: a prompt by its text, a slash command by its name.
  public func takes(queued text: String) -> Bool {
    let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch self {
    case .user(let body, _): return body.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
    case .command(let name, _): return wanted == name || wanted.hasPrefix(name + " ")
    default: return false
    }
  }
}
