import AppKit
import Charts
import GlanceCore
import GlanceKit
import SwiftUI

/// The Usage page (spec "The Usage page"): the period bar, four tiles, the chart, the by-model and by-project tables
/// and the footer. While nothing has been read it says what Usage will show; the store's error replaces it all.
struct UsagePage: View {
    @ObservedObject private var usage = UsageService.shared
    @ObservedObject private var navigation = UsageNavigation.shared
    @ObservedObject private var features = StudioFeatures.shared
    @State private var report: UsageReport?
    @State private var showCost = false

    var body: some View {
        if let error = usage.storeError {
            UsageProblem(text: error)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    JournalPageHeader(title: "Usage",
                                      subtitle: "Claude Code tokens on this Mac, and what they'd cost at API rates.")
                    UsagePeriodBar()
                    if let progress = usage.importing {
                        Text("Reading \(progress.done) of \(progress.total) transcripts…")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                    }
                    if let report {
                        if report.trackedSince == nil && usage.importing == nil {
                            UsageEmptyCard()
                        } else {
                            UsageTiles(report: report)
                            UsageChartCard(report: report, showCost: $showCost)
                            UsageTable(title: "By model", rows: report.models, projects: false)
                            UsageTable(title: "By project", rows: report.projects, projects: true)
                            if features.isOn(.automations) {
                                AutomationsUsageCard(period: navigation.period, calendar: usage.calendar)
                            }
                            Text(footer(report))
                                .font(.studio(11.5))
                                .foregroundStyle(StudioColors.muted)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                reload()
                usage.scan()
            }
            .onChange(of: navigation.period) { reload() }
            .onChange(of: usage.revision) { reload() }
        }
    }

    private func reload() {
        let period = navigation.period
        usage.report(period) { report in
            if UsageNavigation.shared.period == period { self.report = report }
        }
    }

    private func footer(_ report: UsageReport) -> String {
        var parts: [String] = []
        if let since = report.trackedSince {
            parts.append("Tracked since \(UsageFormat.day(since, calendar: usage.calendar))")
        }
        parts.append("prices as of \(UsagePricing.asOf)")
        parts.append("estimates at API rates, not a bill")
        if report.unpricedTokens > 0 { parts.append("— means the model has no price yet") }
        return parts.joined(separator: " · ")
    }
}

/// Day · Week · Month, ‹ the period ›, and Today.
private struct UsagePeriodBar: View {
    @ObservedObject private var navigation = UsageNavigation.shared

    var body: some View {
        let kind = navigation.period.kind
        HStack(spacing: 10) {
            Picker("Period", selection: Binding(get: { kind }, set: { navigation.showKind($0) })) {
                ForEach(UsagePeriod.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            Button { navigation.step(-1) } label: {
                StudioIcon(.chevronLeft, size: 14).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioColors.body)
            .help("Previous \(kind.title.lowercased())")
            .accessibilityLabel("Previous \(kind.title.lowercased())")
            Text(UsageFormat.title(navigation.period, calendar: UsageService.shared.calendar))
                .font(.studio(14, .semibold))
                .foregroundStyle(StudioColors.ink)
                .monospacedDigit()
                .frame(minWidth: 130)
            Button { navigation.step(1) } label: {
                StudioIcon(.chevronRight, size: 14).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(navigation.isCurrent ? StudioColors.line3 : StudioColors.body)
            .disabled(navigation.isCurrent)
            .help("Next \(kind.title.lowercased())")
            .accessibilityLabel("Next \(kind.title.lowercased())")
            Spacer(minLength: 0)
            Button("Today") { navigation.show(kind) }
                .disabled(navigation.isCurrent)
        }
    }
}

/// Tokens, cost, requests and the change from the period before.
private struct UsageTiles: View {
    let report: UsageReport

    var body: some View {
        let totals = report.totals
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .leading)],
                  alignment: .leading, spacing: 12) {
            UsageTile(label: "Tokens", value: UsageFormat.tokens(totals.total),
                      detail: "\(UsageFormat.tokens(totals.input)) in · \(UsageFormat.tokens(totals.output)) out · "
                          + "\(UsageFormat.tokens(totals.cacheWrite + totals.cacheRead)) cache")
            UsageTile(label: "Cost at API rates", value: UsageFormat.cost(report.cost),
                      detail: report.unpricedTokens > 0 ? "Some models have no price" : "Estimate")
            UsageTile(label: "Requests", value: UsageFormat.tokens(report.requests), detail: "API calls")
            UsageTile(label: "vs previous \(report.period.kind.title.lowercased())",
                      value: UsageFormat.change(report.change) ?? "—", detail: "Cost")
        }
    }
}

private struct UsageTile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption(label)
            Text(value)
                .font(.studioMono(22, .semibold))
                .foregroundStyle(StudioColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.studio(11.5))
                .foregroundStyle(StudioColors.muted)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Stacked bars per hour or day, by kind of token, or the cost; hovering a bar shows its numbers.
private struct UsageChartCard: View {
    let report: UsageReport
    @Binding var showCost: Bool
    @State private var hovered: Date?

    private static let kinds = ["Output", "Input", "Cache write", "Cache read"]

    private struct Segment: Identifiable {
        let start: Date
        let kind: String
        let value: Double
        var id: String { "\(start.timeIntervalSince1970)-\(kind)" }
    }

    var body: some View {
        let unit: Calendar.Component = report.period.kind == .day ? .hour : .day
        InsightCard(title: showCost ? "Cost at API rates" : "Tokens") {
            Picker("Show", selection: $showCost) {
                Text("Tokens").tag(false)
                Text("$").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            Chart {
                ForEach(segments) { segment in
                    BarMark(x: .value("Time", segment.start, unit: unit),
                            y: .value(showCost ? "Dollars" : "Tokens", segment.value))
                        .foregroundStyle(by: .value("Kind", segment.kind))
                }
                if let bucket = hoveredBucket {
                    RuleMark(x: .value("Time", bucket.start, unit: unit))
                        .foregroundStyle(StudioColors.line3)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            UsageHoverCard(bucket: bucket, hourly: unit == .hour)
                        }
                }
            }
            .chartForegroundStyleScale(domain: showCost ? ["Cost"] : Self.kinds,
                                       range: showCost ? [JournalPalette.series[0]]
                                           : Array(JournalPalette.series.prefix(4)))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(showCost ? UsageFormat.cost(number) : UsageFormat.tokens(Int(number)))
                        }
                    }
                }
            }
            .chartXSelection(value: $hovered)
            .frame(height: 220)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(showCost ? "Cost by \(unit == .hour ? "hour" : "day")"
                                    : "Tokens by \(unit == .hour ? "hour" : "day")")
            .accessibilityValue(summary)
        }
    }

    private var segments: [Segment] {
        report.buckets.flatMap { bucket -> [Segment] in
            if showCost { return [Segment(start: bucket.start, kind: "Cost", value: bucket.cost)] }
            let tokens = bucket.tokens
            return [Segment(start: bucket.start, kind: "Output", value: Double(tokens.output)),
                    Segment(start: bucket.start, kind: "Input", value: Double(tokens.input)),
                    Segment(start: bucket.start, kind: "Cache write", value: Double(tokens.cacheWrite)),
                    Segment(start: bucket.start, kind: "Cache read", value: Double(tokens.cacheRead))]
        }
    }

    private var hoveredBucket: UsageReport.Bucket? {
        guard let hovered else { return nil }
        return report.buckets.last { $0.start <= hovered }
    }

    private var summary: String {
        let total = "\(UsageFormat.tokens(report.totals.total)) tokens, \(UsageFormat.cost(report.cost))"
        guard let busiest = report.buckets.max(by: { $0.tokens.total < $1.tokens.total }),
              busiest.tokens.total > 0 else { return total }
        let label = UsageFormat.bucket(busiest.start, hourly: report.period.kind == .day,
                                       calendar: UsageService.shared.calendar)
        return total + "; busiest \(label) with \(UsageFormat.tokens(busiest.tokens.total)) tokens"
    }
}

private struct UsageHoverCard: View {
    let bucket: UsageReport.Bucket
    let hourly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(UsageFormat.bucket(bucket.start, hourly: hourly, calendar: UsageService.shared.calendar))
                .font(.studio(11.5, .semibold))
                .foregroundStyle(StudioColors.ink)
            line("Output", bucket.tokens.output)
            line("Input", bucket.tokens.input)
            line("Cache write", bucket.tokens.cacheWrite)
            line("Cache read", bucket.tokens.cacheRead)
            Text("\(UsageFormat.tokens(bucket.tokens.total)) tokens · \(UsageFormat.cost(bucket.cost))")
                .font(.studioMono(11, .semibold))
                .foregroundStyle(StudioColors.ink)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.solid))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }

    private func line(_ label: String, _ count: Int) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.studio(11)).foregroundStyle(StudioColors.muted)
            Spacer(minLength: 0)
            Text(UsageFormat.tokens(count)).font(.studioMono(11)).foregroundStyle(StudioColors.body)
        }
        .frame(width: 150)
    }
}

/// A table of shares: name, tokens, cost and a share bar, biggest first.
private struct UsageTable: View {
    let title: String
    let rows: [UsageReport.Share]
    let projects: Bool

    var body: some View {
        InsightCard(title: title) {
            if rows.isEmpty {
                Text("Nothing in this period.")
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
            }
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                                .font(.studio(13, .medium))
                                .foregroundStyle(StudioColors.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if projects && row.subagentShare >= 0.005 {
                                Text("incl. \(UsageFormat.percent(row.subagentShare)) subagents")
                                    .font(.studio(11))
                                    .foregroundStyle(StudioColors.muted)
                            }
                        }
                        .help(projects && !row.key.isEmpty ? row.key : row.name)
                        Spacer(minLength: 8)
                        Text(UsageFormat.tokens(row.tokens.total))
                            .font(.studioMono(12))
                            .foregroundStyle(StudioColors.body)
                            .frame(width: 70, alignment: .trailing)
                        Text(UsageFormat.cost(row.cost))
                            .font(.studioMono(12, .semibold))
                            .foregroundStyle(StudioColors.ink)
                            .frame(width: 80, alignment: .trailing)
                        UsageShareBar(fraction: row.share)
                            .frame(width: 90)
                        Text(UsageFormat.percent(row.share))
                            .font(.studioMono(11))
                            .foregroundStyle(StudioColors.muted)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                    if row.id != rows.last?.id {
                        Rectangle().fill(StudioColors.line2).frame(height: 1)
                    }
                }
            }
        }
    }
}

/// Usage's "Automations" row (spec 2026-10-09-automations-design.md, "Claude steps": "Usage shows an Automations
/// row"): what automations' Claude steps cost in the period, from their run logs. Those steps keep no transcript, so
/// the totals above leave them out; this says so. The run logs are read off the main thread.
private struct AutomationsUsageCard: View {
    let period: UsagePeriod
    let calendar: Calendar
    @State private var cost: Double?

    var body: some View {
        InsightCard(title: "Automations") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude steps in automations")
                        .font(.studio(13, .medium))
                        .foregroundStyle(StudioColors.ink)
                    Text("Not in the totals above: automations' Claude steps keep no transcript.")
                        .font(.studio(11))
                        .foregroundStyle(StudioColors.muted)
                }
                Spacer(minLength: 8)
                Text(cost.map { UsageFormat.cost($0) } ?? "")
                    .font(.studioMono(12, .semibold))
                    .foregroundStyle(StudioColors.ink)
                    .frame(width: 80, alignment: .trailing)
            }
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)
        }
        .task(id: period) {
            let library = AutomationEngine.shared.library
            let from = period.start
            let to = period.end(calendar)
            let total = await Task.detached(priority: .utility) { library.claudeCost(from: from, to: to) }.value
            if !Task.isCancelled { cost = total }
        }
    }
}

private struct UsageShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(StudioColors.field)
                Capsule().fill(StudioColors.coral)
                    .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Before anything was read.
private struct UsageEmptyCard: View {
    var body: some View {
        InsightCard(title: "Nothing read yet") {
            Text("Usage counts the tokens in Claude Code's transcripts on this Mac (~/.claude/projects) and keeps them, "
                + "even after Claude Code deletes old transcripts. The first read can only reach back as far as the "
                + "transcripts still there, usually about 30 days.")
                .font(.studio(13))
                .foregroundStyle(StudioColors.body)
        }
    }
}

/// The usage store couldn't be opened at all.
private struct UsageProblem: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage can't open its file")
                .font(.studio(18, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text(text)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.muted)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
