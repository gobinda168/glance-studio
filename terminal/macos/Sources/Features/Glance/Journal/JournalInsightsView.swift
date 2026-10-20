import AppKit
import Charts
import GlanceCore
import GlanceKit
import SwiftUI

/// Insights (spec "Insights"): a range picker, then five cards:
/// - Activity: the year grid, streaks, busiest day and hour;
/// - Where time went;
/// - Output + impact;
/// - Skills + themes;
/// - Journey.
/// With fewer than 3 active days in the range, each chart says what it will show instead.
struct JournalInsightsView: View {
    @ObservedObject private var journal = JournalService.shared
    @State private var range: JournalInsights.Range = .days30
    @State private var insights: JournalInsights?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                JournalPageHeader(title: "Insights", subtitle: "How your work adds up.") {
                    Picker("Range", selection: $range) {
                        ForEach(JournalInsights.Range.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }
                if let insights {
                    ActivityCard(insights: insights)
                    if insights.activeDays < 3 {
                        InsightCard(title: "More soon") {
                            Text("After three active days in this range, you'll see where your time went, what you "
                                + "shipped and reviewed, and which skills you used.")
                                .font(.studio(13))
                                .foregroundStyle(StudioColors.muted)
                        }
                    } else {
                        TimeCard(insights: insights)
                        OutputCard(insights: insights)
                        SkillsCard(insights: insights)
                    }
                    JourneyCard(milestones: insights.journey)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { reload() }
        .onChange(of: range) { reload() }
        .onChange(of: journal.revision) { reload() }
    }

    private func reload() {
        journal.loadInsights(range) { insights = $0 }
    }
}

/// The board's palette: six categorical hues in a fixed order, Glance coral first, stepped for each mode and checked
/// with the dataviz validator (lightness band, chroma, colour-blind separation, contrast) against the card surfaces.
/// "Other" is always the quiet line colour.
@MainActor
enum JournalPalette {
    static let series: [Color] = [
        adaptive(light: 0xE8643C, dark: 0xE8643C), // coral
        adaptive(light: 0x2A78D6, dark: 0x3987E5), // blue
        adaptive(light: 0x1BAF7A, dark: 0x199E70), // aqua
        adaptive(light: 0xEDA100, dark: 0xC98500), // yellow
        adaptive(light: 0xE87BA4, dark: 0xD55181), // magenta
        adaptive(light: 0x008300, dark: 0x008300), // green
    ]

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
        })
    }

    static func scale(_ names: [String]) -> (domain: [String], range: [Color]) {
        let named = names.filter { $0 != "Other" }
        let colors = named.indices.map { series[$0 % series.count] }
        return names.contains("Other") ? (named + ["Other"], colors + [StudioColors.line3]) : (named, colors)
    }

    static func date(_ day: JournalDay) -> Date {
        day.start(in: JournalService.shared.calendar).addingTimeInterval(12 * 3600)
    }
}

/// A card: the `card` fill, a 1pt line, 12pt corners, a caption title.
struct InsightCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Caption(title)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }
}

/// A number with its label under it.
private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.studioMono(18, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text(label)
                .font(.studio(11.5))
                .foregroundStyle(StudioColors.muted)
        }
    }
}

private struct ActivityCard: View {
    let insights: JournalInsights

    var body: some View {
        InsightCard(title: "Activity") {
            // A year is ~690pt wide: narrower pages scroll it, showing this week first.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(Array(insights.grid.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: 3) {
                            ForEach(column, id: \.day) { cell in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(color(cell))
                                    .frame(width: 10, height: 10)
                                    .help(cell.isFuture ? "" : "\(JournalFormat.short(cell.day)) · "
                                        + (cell.minutes > 0 ? JournalFormat.duration(cell.minutes) : "nothing"))
                            }
                        }
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("A year of activity, \(insights.currentStreak) day current streak")
            legend
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading,
                      spacing: 14) {
                Stat(value: days(insights.currentStreak), label: "Current streak")
                Stat(value: days(insights.longestStreak), label: "Longest streak")
                Stat(value: insights.busiestWeekday.map { weekday($0) } ?? "–", label: "Busiest day")
                Stat(value: insights.busiestHour.map { hour($0) } ?? "–", label: "Busiest hour")
            }
        }
    }

    /// Less ▢▢▢▢▢ More: what the grid's five shades mean (none, under 1 h, 1–3 h, 3–5 h, 5 h or more).
    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less").font(.studio(11)).foregroundStyle(StudioColors.muted)
            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(shade(level)).frame(width: 10, height: 10)
            }
            Text("More").font(.studio(11)).foregroundStyle(StudioColors.muted)
        }
        .help("None · under 1 h · 1–3 h · 3–5 h · 5 h or more")
        .accessibilityHidden(true)
    }

    private func color(_ cell: JournalGridCell) -> Color {
        cell.isFuture ? .clear : shade(cell.level)
    }

    private func shade(_ level: Int) -> Color {
        switch level {
        case 0: return StudioColors.field
        case 1: return StudioColors.coral.opacity(0.28)
        case 2: return StudioColors.coral.opacity(0.5)
        case 3: return StudioColors.coral.opacity(0.75)
        default: return StudioColors.coral
        }
    }

    private func days(_ count: Int) -> String { "\(count) day\(count == 1 ? "" : "s")" }

    private func weekday(_ number: Int) -> String {
        let symbols = JournalService.shared.calendar.weekdaySymbols
        return symbols.indices.contains(number - 1) ? symbols[number - 1] : "–"
    }

    private func hour(_ value: Int) -> String {
        let date = Calendar.current.date(bySettingHour: value, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct TimeCard: View {
    let insights: JournalInsights

    private struct Bar: Identifiable {
        let id = UUID()
        let week: Date
        let project: String
        let hours: Double
    }

    var body: some View {
        let bars = insights.weeks.flatMap { week in
            week.projects.map { Bar(week: JournalPalette.date(week.start), project: label($0.name),
                                    hours: Double($0.value) / 60) }
        }
        let names = insights.weeks.flatMap { $0.projects.map { label($0.name) } }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let scale = JournalPalette.scale(names)
        InsightCard(title: "Where time went") {
            Chart(bars) { bar in
                BarMark(x: .value("Week", bar.week, unit: .weekOfYear), y: .value("Hours", bar.hours))
                    .foregroundStyle(by: .value("Project", bar.project))
            }
            .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
            .chartYAxisLabel("hours")
            .frame(height: 200)
            HStack(spacing: 32) {
                Stat(value: JournalFormat.duration(insights.focusMinutes), label: "Focus")
                Stat(value: JournalFormat.duration(insights.meetingMinutes), label: "Meetings")
            }
            Text("Time touched per project: overlapping work counts for each project.")
                .font(.studio(11.5))
                .foregroundStyle(StudioColors.muted)
        }
    }

    private func label(_ project: String) -> String {
        project == "Other" ? "Other" : FolderLabel.name(forPath: project)
    }
}

private struct OutputCard: View {
    let insights: JournalInsights
    @ObservedObject private var navigation = JournalNavigation.shared

    private struct Point: Identifiable {
        let id = UUID()
        let week: Date
        let series: String
        let count: Int
    }

    var body: some View {
        let points = insights.output.flatMap { week -> [Point] in
            let date = JournalPalette.date(week.start)
            return [Point(week: date, series: "PRs merged", count: week.merged),
                    Point(week: date, series: "Reviews", count: week.reviews),
                    Point(week: date, series: "Commits", count: week.commits),
                    Point(week: date, series: "Claude sessions", count: week.sessions)]
        }
        let scale = JournalPalette.scale(["PRs merged", "Reviews", "Commits", "Claude sessions"])
        InsightCard(title: "Output + impact") {
            Chart(points) { point in
                LineMark(x: .value("Week", point.week, unit: .weekOfYear), y: .value("Count", point.count))
                    .foregroundStyle(by: .value("Kind", point.series))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
            .frame(height: 180)
            if insights.impact.isEmpty {
                Text("Star an entry, or give it a measured impact, and it shows here.")
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(insights.impact.prefix(8)) { entry in
                        Button { navigation.show(.day(entry.day)) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(JournalFormat.short(entry.day))
                                    .font(.studioMono(11))
                                    .foregroundStyle(StudioColors.muted)
                                    .frame(width: 84, alignment: .leading)
                                Text(entry.title)
                                    .font(.studio(13, .medium))
                                    .foregroundStyle(StudioColors.ink)
                                if !entry.impact.isEmpty {
                                    Text(entry.impact)
                                        .font(.studioMono(11.5))
                                        .foregroundStyle(StudioColors.tealInk)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct SkillsCard: View {
    let insights: JournalInsights

    private struct Area: Identifiable {
        let id = UUID()
        let month: Date
        let skill: String
        let count: Int
    }

    var body: some View {
        let calendar = JournalService.shared.calendar
        let areas = insights.skillMonths.flatMap { month -> [Area] in
            let date = JournalDay(key: month.month + "-15").map { $0.start(in: calendar) } ?? Date()
            return month.skills.map { Area(month: date, skill: $0.name, count: $0.value) }
        }
        let scale = JournalPalette.scale(insights.topSkills.map(\.name))
        InsightCard(title: "Skills + themes") {
            if areas.isEmpty {
                Text("Skills come from your entries' tags. Draft a few recaps and they show here.")
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
            } else {
                Chart(areas) { area in
                    AreaMark(x: .value("Month", area.month, unit: .month), y: .value("Entries", area.count))
                        .foregroundStyle(by: .value("Skill", area.skill))
                }
                .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
                .frame(height: 180)
                HStack(spacing: 6) {
                    ForEach(insights.topSkills, id: \.name) { skill in
                        Text("\(skill.name) \(skill.value)")
                            .font(.studio(11.5, .medium))
                            .foregroundStyle(StudioColors.body)
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(Capsule().fill(StudioColors.chip))
                    }
                }
            }
        }
    }
}

private struct JourneyCard: View {
    let milestones: [JournalMilestone]
    @ObservedObject private var navigation = JournalNavigation.shared

    var body: some View {
        InsightCard(title: "Journey") {
            if milestones.isEmpty {
                Text("Firsts, streaks and highlights collect here as your days add up.")
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(milestones.prefix(40)) { milestone in
                        Button { navigation.show(.day(milestone.day)) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(JournalFormat.short(milestone.day))
                                    .font(.studioMono(11))
                                    .foregroundStyle(StudioColors.muted)
                                    .frame(width: 84, alignment: .trailing)
                                    .padding(.top, 2)
                                Circle()
                                    .fill(milestone.kind == .highlight ? StudioColors.coral : StudioColors.line3)
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 5)
                                    .frame(width: 12)
                                    .frame(maxHeight: .infinity, alignment: .top)
                                    .background { Rectangle().fill(StudioColors.line).frame(width: 1) }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(milestone.title)
                                        .font(.studio(13, milestone.kind == .month ? .semibold : .medium))
                                        .foregroundStyle(StudioColors.ink)
                                    if !milestone.detail.isEmpty {
                                        Text(milestone.detail)
                                            .font(.studio(11.5))
                                            .foregroundStyle(StudioColors.muted)
                                    }
                                }
                                .padding(.bottom, 12)
                                Spacer(minLength: 0)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
