import Combine
import GlanceCore
import SwiftUI

/// Claude's plan usage for the top bar, shared by every window: one watcher of the status-line script's `usage.json`
/// (the same file the Glance pane's usage strip reads).
@MainActor
final class PlanUsageModel: ObservableObject {
    static let shared = PlanUsageModel()

    @Published private(set) var reading: UsageWatcher.Reading?
    private let watcher = UsageWatcher()

    private init() {
        watcher.onChange = { [weak self] reading in MainActor.assumeIsolated { self?.reading = reading } }
        watcher.start()
    }
}

/// "5H ▰▰▰▱ 83%   WEEK ▰▰▱▱ 75%" in a glass capsule: a slim bar per plan window (teal, as in the Glance pane's
/// strip; amber from 70%, red from 90%) and the numbers in mono, rolling to new values. Hidden without data.
struct PlanUsageItem: View {
    @ObservedObject private var model = PlanUsageModel.shared
    @ObservedObject private var features = StudioFeatures.shared

    var body: some View {
        if let reading = model.reading {
            let summary = reading.usage.hoverText(now: Date(), updated: reading.updated)
            let capsule = HStack(spacing: 12) {
                if let window = reading.usage.fiveHour { Meter(label: "5H", window: window) }
                if let window = reading.usage.sevenDay { Meter(label: "WEEK", window: window) }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .glassSurface(Capsule(style: .continuous), solid: Color(nsColor: .controlBackgroundColor))
            .padding(.horizontal, 2)
            // With Usage on, a click opens it: tokens by day, week and month.
            if features.isOn(.usage) {
                Button { UsageTabController.open(from: NSApp.keyWindow) } label: { capsule }
                    .buttonStyle(.plain)
                    .help(summary + "\nClick for token usage by day, week and month.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(summary)
                    .accessibilityHint("Opens Usage")
            } else {
                capsule
                    .help(summary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(summary)
            }
        } else {
            // The toolbar drops zero-sized items, so keep a sliver.
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private struct Meter: View {
        let label: String
        let window: PlanUsage.Window
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var ink: Color {
            switch window.severity {
            case .normal: GlassChrome.ink
            case .warn: GlassChrome.warnInk
            case .critical: GlassChrome.criticalInk
            }
        }

        var body: some View {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(GlassChrome.ink2)
                MeterBar(fraction: window.percent / 100, severity: window.severity)
                Text("\(window.shownPercent)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ink)
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: window.percent))
            }
            .animation(reduceMotion ? GlassChrome.fade : .smooth(duration: 0.6), value: window.percent)
        }
    }

    /// A slim bar filled to the window's percent, in the severity's colour.
    private struct MeterBar: View {
        static let width: CGFloat = 38
        let fraction: Double
        let severity: PlanUsage.Window.Severity

        private var color: Color {
            switch severity {
            case .normal: GlassChrome.teal
            case .warn: GlassChrome.warn
            case .critical: GlassChrome.critical
            }
        }

        var body: some View {
            let shown = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.13))
                Capsule()
                    .fill(color)
                    .frame(width: max(3, Self.width * shown))
            }
            .frame(width: Self.width, height: 3)
            .accessibilityHidden(true)
        }
    }
}
