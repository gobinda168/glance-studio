import Foundation
import GlanceCore
import GlanceKit

/// Which Meetings page the tab shows (spec 2026-10-09-meeting-notes-design.md): the start page, the meeting being
/// recorded, or a saved meeting. Shared by every window, like Journal's page.
@MainActor
final class MeetingsNavigation: ObservableObject {
    enum Page: Hashable {
        case start
        case meeting(String)
    }

    static let shared = MeetingsNavigation()

    @Published private(set) var page: Page = .start

    func show(_ page: Page) {
        self.page = page
    }
}

/// How Meetings writes days, times and lengths.
enum MeetingsFormat {
    /// "Today", "Yesterday", or "Thu 8 Oct".
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "10:05" or "10:05 AM", as the Mac shows times.
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "42 min", "1 h 05 min", "40 s".
    static func length(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// "12:04" while recording: minutes and seconds (hours from 60 min).
    static func clock(_ seconds: TimeInterval) -> String { MeetingTranscript.clock(seconds) }

    /// "Thursday 9 October · 10:05".
    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide)) + " · " + time(date)
    }
}
