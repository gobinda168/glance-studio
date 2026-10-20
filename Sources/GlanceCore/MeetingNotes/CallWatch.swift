import Foundation

/// The apps whose use of the mic means a call (spec 2026-10-09-meeting-notes-design.md, "Calls that start without the
/// nudge"): matched by bundle identifier prefix, so a browser's helper processes count as the browser.
public enum CallApps {
  static let known: [(prefix: String, name: String)] = [
    ("us.zoom.xos", "Zoom"),
    ("com.microsoft.teams", "Microsoft Teams"),
    ("com.tinyspeck.slackmacgap", "Slack"),
    ("com.apple.FaceTime", "FaceTime"),
    ("com.cisco.webexmeetingsapp", "Webex"),
    ("Cisco-Systems.Spark", "Webex"),
    ("com.hnc.Discord", "Discord"),
    ("com.google.Chrome", "Google Chrome"),
    ("com.brave.Browser", "Brave"),
    ("com.microsoft.edgemac", "Microsoft Edge"),
    ("company.thebrowser.Browser", "Arc"),
    ("org.mozilla.firefox", "Firefox"),
    ("com.apple.Safari", "Safari"),
    // Safari's (and other WebKit apps') capture runs in WebKit's GPU process.
    ("com.apple.WebKit.GPU", "a browser"),
  ]

  /// The app's name when it's one that holds calls, else nil.
  public static func name(for bundleID: String) -> String? {
    known.first { bundleID.hasPrefix($0.prefix) }?.name
  }
}

/// When to offer recording a call that Glance didn't start: an app from `CallApps` has used the mic for `delay`, Glance
/// isn't recording, and the meeting nudge isn't already showing. Once per call: a call ends when its app stops using
/// the mic. Fed every couple of seconds with the apps using the mic now.
public struct CallWatch: Sendable {
  public enum Decision: Equatable, Sendable {
    case none
    /// Show the pill for this app's call, which began at `since`.
    case offer(app: String, since: Date)
    /// Take the pill away: its call ended, or recording started.
    case withdraw
  }

  public let delay: TimeInterval
  /// Each call app using the mic, by name, and since when.
  private var calls: [String: Date] = [:]
  /// Calls already offered (shown, dismissed or recorded), by app name, until they end.
  private var offered: Set<String> = []
  /// The call the pill shows now.
  public private(set) var showing: String?

  public init(delay: TimeInterval = 5) {
    self.delay = delay
  }

  /// `using`: the bundle IDs of the processes using the mic now, Glance's own left out.
  public mutating func update(using: Set<String>, now: Date, recording: Bool, meetingNudgeShowing: Bool) -> Decision {
    let names = Set(using.compactMap(CallApps.name(for:)))
    for name in calls.keys where !names.contains(name) {
      calls[name] = nil
      offered.remove(name)
    }
    for name in names where calls[name] == nil { calls[name] = now }
    if let shown = showing, recording || calls[shown] == nil {
      showing = nil
      return .withdraw
    }
    guard showing == nil, !recording, !meetingNudgeShowing else { return .none }
    let due = calls.filter { !offered.contains($0.key) && now.timeIntervalSince($0.value) >= delay }
    guard let (name, since) = due.min(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { return .none }
    offered.insert(name)
    showing = name
    return .offer(app: name, since: since)
  }

  /// The pill was closed or its Record pressed: it stays away for the rest of this call.
  public mutating func dismiss() {
    showing = nil
  }
}

/// Today's meetings for the Meetings tab (spec "Today's meetings"): under way or still to come today, not all-day, not
/// declined, on a ticked calendar; the one under way first, then by start.
public enum TodayMeetings {
  public static func list(_ events: [MeetingEvent], now: Date, calendar: Calendar, calendarsOff: Set<String>)
    -> [MeetingEvent] {
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    return events
      .filter { !$0.isAllDay && !$0.declined && !calendarsOff.contains($0.calendarID) }
      .filter { $0.end > now && $0.start < endOfDay }
      .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
  }

  /// Under way now.
  public static func isLive(_ event: MeetingEvent, now: Date) -> Bool {
    event.start <= now && now < event.end
  }
}
