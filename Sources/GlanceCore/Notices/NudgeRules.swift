import Foundation

/// What nudges (spec 2026-10-09-notifications-design.md, "Nudge rules"): a switch per kind, VIPs who always nudge,
/// Do not disturb, quiet during meetings, and the arrival sound.
public struct NotificationPrefs: Codable, Equatable, Sendable {
  /// Only the kinds the user changed are stored; the rest follow `defaultNudge`.
  public var nudge: [Notice.Kind: Bool]
  /// People (`riya`, `@riya`) and channels (`#infra`), any case.
  public var vips: [String]
  public var doNotDisturb: Bool
  public var quietInMeetings: Bool
  public var sound: Bool

  public static let defaults = NotificationPrefs(nudge: [:], vips: [], doNotDisturb: false, quietInMeetings: true,
                                                 sound: true)

  public static func defaultNudge(_ kind: Notice.Kind) -> Bool {
    switch kind {
    case .slackDM, .slackMention, .slackThread, .githubReviewRequested, .githubMention, .githubComment,
      .githubAssigned, .githubCIFailed, .claudeNeedsInput, .ticketSuggestion, .ticketMoved, .ticketFailed,
      .automationApproval, .automationFailed, .claudeMessage: true
    case .slackChannel, .githubStateChanged, .githubOther, .meetingStarting, .claudeFinished, .terminalAlert,
      .ticketsMorning, .ticketsCheckIn: false
    }
  }

  public init(nudge: [Notice.Kind: Bool], vips: [String], doNotDisturb: Bool, quietInMeetings: Bool, sound: Bool) {
    self.nudge = nudge
    self.vips = vips
    self.doNotDisturb = doNotDisturb
    self.quietInMeetings = quietInMeetings
    self.sound = sound
  }

  public func nudges(_ kind: Notice.Kind) -> Bool { nudge[kind] ?? Self.defaultNudge(kind) }

  public mutating func set(_ kind: Notice.Kind, _ on: Bool) { nudge[kind] = on }
}

public enum NudgeRules {
  /// Older than this, a notice only lands in the inbox (catching up after sleep, a first poll).
  public static let staleAfter: TimeInterval = 600

  public static func shouldNudge(_ notice: Notice, prefs: NotificationPrefs, now: Date, inMeeting: Bool) -> Bool {
    // The meeting pill and Tickets' own card are the nudges for these.
    guard notice.kind != .meetingStarting, notice.kind != .ticketsMorning, notice.kind != .ticketsCheckIn,
          !prefs.doNotDisturb, !(prefs.quietInMeetings && inMeeting),
          now.timeIntervalSince(notice.date) <= staleAfter, notice.state != .done else { return false }
    return prefs.nudges(notice.kind) || isVIP(notice, vips: prefs.vips)
  }

  public static func isVIP(_ notice: Notice, vips: [String]) -> Bool {
    let wanted = Set(vips.map(normal))
    guard !wanted.isEmpty else { return false }
    let names = notice.people.map(normal) + [notice.place].compactMap { $0 }.map(normal)
    return names.contains(where: wanted.contains)
  }

  /// `@Riya ` → `riya`; `#Infra` stays `#infra`.
  private static func normal(_ name: String) -> String {
    var name = name.trimmingCharacters(in: .whitespaces).lowercased()
    if name.hasPrefix("@") { name.removeFirst() }
    return name
  }
}

/// A `String` raw value makes this automatic; it makes `[Notice.Kind: Bool]` encode as `{"slackDM":true}`.
extension Notice.Kind: CodingKeyRepresentable {}
