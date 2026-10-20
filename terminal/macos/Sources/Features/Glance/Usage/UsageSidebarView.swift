import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Usage side bar: Today, This week and This month with their tokens and cost. A row opens the window's Usage tab on
/// that period.
struct UsageSidebarView: View {
    @ObservedObject private var usage = UsageService.shared
    @ObservedObject private var navigation = UsageNavigation.shared
    @State private var window: NSWindow?
    @State private var reports: [UsagePeriod.Kind: UsageReport] = [:]

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(title: "Usage") {
                if usage.importing != nil {
                    ProgressView().controlSize(.mini).padding(.trailing, 8)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(UsagePeriod.Kind.allCases, id: \.self) { kind in
                    JournalSidebarRow(icon: kind == .day ? .clock : .chart, title: title(kind), detail: detail(kind),
                                      dot: nil, selected: navigation.isCurrent && navigation.period.kind == kind) {
                        UsageTabController.open(period: kind, from: window)
                    }
                }
            }
            .padding(.horizontal, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { window = $0 })
        .onAppear { reload() }
        .onChange(of: usage.revision) { reload() }
    }

    private func title(_ kind: UsagePeriod.Kind) -> String {
        switch kind {
        case .day: "Today"
        case .week: "This week"
        case .month: "This month"
        }
    }

    private func detail(_ kind: UsagePeriod.Kind) -> String {
        guard let report = reports[kind] else { return "—" }
        return "\(UsageFormat.tokens(report.totals.total)) tokens · \(UsageFormat.cost(report.cost))"
    }

    private func reload() {
        for kind in UsagePeriod.Kind.allCases {
            usage.report(UsagePeriod(kind, containing: Date(), calendar: usage.calendar)) { report in
                reports[kind] = report
            }
        }
    }
}
