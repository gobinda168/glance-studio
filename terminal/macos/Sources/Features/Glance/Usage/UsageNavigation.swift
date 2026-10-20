import Foundation
import GlanceCore
import GlanceKit

/// The period the Usage tab shows (spec 2026-10-09-token-usage-design.md, "The Usage page"), shared by every window.
@MainActor
final class UsageNavigation: ObservableObject {
    static let shared = UsageNavigation()

    @Published private(set) var period: UsagePeriod

    private var calendar: Calendar { UsageService.shared.calendar }

    private init() {
        period = UsagePeriod(.week, containing: Date(), calendar: UsageService.shared.calendar)
    }

    /// Today, this week or this month.
    func show(_ kind: UsagePeriod.Kind) {
        period = UsagePeriod(kind, containing: Date(), calendar: calendar)
    }

    /// Day · Week · Month: the period of that kind around the one shown (today's, when it's showing now).
    func showKind(_ kind: UsagePeriod.Kind) {
        let anchor = isCurrent ? Date() : period.start
        period = UsagePeriod(kind, containing: anchor, calendar: calendar)
    }

    /// ‹ and ›; › stops at the current period.
    func step(_ offset: Int) {
        if offset < 0 {
            period = period.previous(calendar)
        } else if !isCurrent {
            period = period.next(calendar)
        }
    }

    var isCurrent: Bool { period.contains(Date(), calendar: calendar) }
}
