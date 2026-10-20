import Foundation
import GlanceCore
import GlanceKit

/// Which Journal page the tab shows (spec 2026-10-09-journal-design.md, "The Journal tab"): Today, Insights, or a
/// day. Shared by every window, like Settings' section.
@MainActor
final class JournalNavigation: ObservableObject {
    enum Page: Hashable {
        case today, insights
        case day(JournalDay)
    }

    static let shared = JournalNavigation()

    @Published private(set) var page: Page = .today

    func show(_ page: Page) {
        self.page = page
    }
}

/// How Journal writes days, times and durations on screen.
@MainActor
enum JournalFormat {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = JournalService.shared.calendar
        formatter.timeZone = JournalService.shared.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter
    }

    private static func noon(_ day: JournalDay) -> Date {
        day.start(in: JournalService.shared.calendar).addingTimeInterval(12 * 3600)
    }

    /// "Thu 8 Oct".
    static func short(_ day: JournalDay) -> String { formatter("EEE d MMM").string(from: noon(day)) }

    /// "Thursday 8 October".
    static func long(_ day: JournalDay) -> String { formatter("EEEE d MMMM").string(from: noon(day)) }

    /// "10:05" or "10:05 AM", as the Mac shows times.
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func duration(_ minutes: Int) -> String { JournalExport.duration(minutes: minutes) }
}
