import Foundation

/// What Glance says out loud with a nudge (Settings → Meetings, "Say it out loud"): "Hey Gobinda, Sprint planning starts
/// in 2 minutes." Slack's nudges will add their own lines here.
public enum NudgeSpeech {
  public static func meeting(name: String?, title: String, start: Date, now: Date) -> String {
    let greeting = name.map { "Hey \($0), " } ?? "Hey, "
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let titled = !trimmed.isEmpty && trimmed != "Untitled meeting"
    let seconds = start.timeIntervalSince(now)
    if seconds >= 30 {
      let minutes = Int((seconds / 60).rounded(.up))
      let span = minutes == 1 ? "1 minute" : "\(minutes) minutes"
      return greeting + (titled ? "\(trimmed) starts in \(span)." : "you have a meeting in \(span).")
    }
    if seconds > -60 { return greeting + (titled ? "\(trimmed) is starting now." : "your meeting is starting now.") }
    return greeting + (titled ? "\(trimmed) has started." : "your meeting has started.")
  }
}
