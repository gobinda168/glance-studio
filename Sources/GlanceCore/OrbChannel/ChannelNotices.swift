import Foundation

/// The orb channel's Notifications items (spec "Cards and the queue"): plain nudges, and answered asks and nudges.
public enum ChannelNotices {
  public static func message(id: String, label: String, surface: String?, cwd: String?, title: String, body: String?,
                             date: Date) -> Notice {
    Notice(id: id, source: .claude, kind: .claudeMessage, title: title, place: label, preview: body ?? "",
           date: date, threadKey: id, target: .terminal(surface: surface, cwd: cwd))
  }

  public static func answered(id: String, label: String, surface: String?, cwd: String?, question: String,
                              said: String, date: Date) -> Notice {
    Notice(id: id, source: .claude, kind: .claudeMessage, title: question, place: label,
           preview: "You answered: \(said)", date: date, threadKey: id, target: .terminal(surface: surface, cwd: cwd),
           state: .read)
  }

  public static func said(_ answer: ChannelBook.Answer) -> String {
    switch answer {
    case .action(let text), .choice(let text), .text(let text): text
    case .allow: "Allow"
    case .deny: "Deny"
    case .dismissed: "Dismissed"
    }
  }
}

extension ChannelBook {
  /// The orb's channel mode (spec "The orb"): listening over everything; then waiting, error, working; then speaking;
  /// then done. nil leaves the orb to the panel (and the meeting glow, which `OrbAttention` puts above all but
  /// listening).
  public static func orbMode(state: ChannelOrbState?, listening: Bool, speaking: Bool) -> String? {
    if listening { return "listening" }
    if let state, state != .done { return state.rawValue }
    if speaking { return "speaking" }
    return state?.rawValue
  }
}
