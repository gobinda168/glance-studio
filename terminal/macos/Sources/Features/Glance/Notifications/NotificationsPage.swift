import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Notifications page (spec 2026-10-09-notifications-design.md, "Notifications page and side bar"), set as a log
/// like Home's: a time gutter down the left edge with a hairline spine, each thread's light on it (coral while
/// unread, a quiet tick once read), then who it's from, what and where, and its last line. Sections Needs you · Today
/// · Earlier (folded) · Done. Coral marks only unread and the selection. The one glow is Catch me up's, and only on
/// hover or while Claude reads; its brief sits in a card under the header.
struct NotificationsPage: View {
    @ObservedObject private var hub = NotificationHub.shared
    @ObservedObject private var navigation = NotificationsNavigation.shared

    static let maxWidth: CGFloat = 820

    var body: some View {
        // Ages and the Today/Earlier split move on with the clock.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let sections = navigation.sections(now: now)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        NotificationsHeader()
                        CatchUpCard(now: now)
                        NoticeFilterBar(compact: false)
                            .padding(.top, 18)
                        if sections.isEmpty {
                            NotificationsEmpty(filter: navigation.filter)
                                .padding(.top, 36)
                        } else {
                            ForEach(sections) { section in
                                NoticeSectionView(section: section, now: now)
                                    .padding(.top, 26)
                            }
                        }
                        NotificationsFooter(hasRows: !sections.isEmpty)
                            .padding(.top, 28)
                    }
                    .frame(maxWidth: Self.maxWidth, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: navigation.selection) { _, selection in
                    guard let selection else { return }
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(selection) }
                }
            }
        }
    }
}

// MARK: - Header

/// "Notifications", what's unread under it, and on the right Catch me up (⌘R), Do not disturb and Mark all read (⇧⌘A).
/// Below 560 pt the controls drop under the title.
private struct NotificationsHeader: View {
    @ObservedObject private var hub = NotificationHub.shared
    @ObservedObject private var navigation = NotificationsNavigation.shared

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                title
                Spacer(minLength: 16)
                controls
            }
            VStack(alignment: .leading, spacing: 14) {
                title
                controls
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notifications")
                .font(.studio(19, .bold))
                .tracking(-0.19)
                .foregroundStyle(StudioColors.ink)
                .accessibilityAddTraits(.isHeader)
            readout
        }
        .fixedSize()
    }

    /// "3 unread · 2 need you", numbers in mono; "Nothing unread" when there's none.
    private var readout: some View {
        let unread = hub.book.unreadCount(navigation.filter)
        let needs = hub.book.rows(filter: navigation.filter, showDone: false)
            .filter { $0.unread && $0.newest.kind.needsYou }.count
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if unread == 0 {
                Text("Nothing unread").font(.studio(12.5))
            } else {
                Text("\(unread)").font(.studioMono(12)).contentTransition(.numericText())
                Text(" unread").font(.studio(12.5))
                if needs > 0 {
                    Text("  ·  ").font(.studio(12.5))
                    Text("\(needs)").font(.studioMono(12)).contentTransition(.numericText())
                    Text(needs == 1 ? " needs you" : " need you").font(.studio(12.5))
                }
            }
            if hub.prefs.doNotDisturb {
                Text("  ·  Nudges held").font(.studio(12.5))
            }
        }
        .foregroundStyle(StudioColors.muted)
        .animation(.easeOut(duration: 0.24), value: unread)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            CatchUpButton()
            DoNotDisturbSwitch()
            StudioButton(title: "Mark all read", icon: .check, hint: "⇧⌘A", style: .secondary,
                         enabled: hub.book.unreadCount(navigation.filter) > 0) { navigation.markAllRead() }
                .help("Mark every unread thread\(navigation.filter.map { " from \($0.title)" } ?? "") read (⇧⌘A)")
        }
        .fixedSize()
    }
}

// MARK: - Catch me up

/// The page's one action Claude takes: a capsule on the raised face with the coral dot (teal while Claude reads), its
/// words and ⌘R. The glow ring lights only on hover and while running, so a resting page stays still.
private struct CatchUpButton: View {
    @ObservedObject private var hub = NotificationHub.shared
    @ObservedObject private var navigation = NotificationsNavigation.shared
    @State private var hovering = false

    var body: some View {
        let running = navigation.catchingUp
        let enabled = running || !navigation.unreadRows.isEmpty
        Button { navigation.runCatchUp() } label: {
            HStack(spacing: 7) {
                if running { TealDot(size: 11) } else { CoralDot(size: 11) }
                Text(running ? "Catching up…" : "Catch me up")
                    .font(.studio(12, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Kbd("⌘R")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(CatchUpGlow(lit: running || (hovering && enabled)))
        .disabled(!enabled || running)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .help(running ? "Claude is reading your unread notifications"
              : enabled ? "A short brief of what's unread, from Claude (⌘R)" : "Nothing unread to catch up on")
        .accessibilityLabel(running ? "Catching up" : "Catch me up")
    }
}

/// MASTER §7.1's glow ring, lit only on demand: at rest a hairline capsule on the raised face; lit, the aurora turning
/// once every 3 s with its halo. The loop runs only while lit, on screen and without Reduce Motion.
private struct CatchUpGlow: ViewModifier {
    let lit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = true

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !lit || reduceMotion || !onScreen)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
            let light = AngularGradient(colors: GlowRing.aurora, center: .center, angle: .degrees(turn * 360))
            content
                .background(Capsule().fill(StudioColors.solid))
                .overlay(Capsule().strokeBorder(StudioColors.line3, lineWidth: 1).opacity(lit ? 0 : 1))
                .overlay(Capsule().strokeBorder(light, lineWidth: 1.5).opacity(lit ? 1 : 0))
                .background(Capsule().fill(light).blur(radius: 9).opacity(lit ? 0.5 : 0))
        }
        .background(OnScreenReader { onScreen = $0 })
        .animation(.easeOut(duration: 0.16), value: lit)
    }
}

/// Claude's brief under the header: the summary in the reading size, then each line as a button that selects (and
/// scrolls to) its row. While Claude reads, a quiet placeholder; a failure says why with Try again. Once 3 or more
/// unread threads arrive that it didn't read, "New since this brief · Refresh". ✕ dismisses (and stops a run).
private struct CatchUpCard: View {
    let now: Date
    @ObservedObject private var hub = NotificationHub.shared
    @ObservedObject private var navigation = NotificationsNavigation.shared

    var body: some View {
        Group {
            switch navigation.catchUp {
            case .idle:
                EmptyView()
            case .running:
                card { running }
            case .ready(let brief, let covered):
                card { ready(brief, covered: covered) }
            case .failed(let why):
                card { failed(why) }
            }
        }
        .animation(.easeOut(duration: 0.16), value: navigation.catchUp)
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Caption("Catch me up")
                Spacer(minLength: 8)
                CardClose { navigation.dismissCatchUp() }
            }
            content()
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColors.card)
        .overlay(alignment: .leading) { Rectangle().fill(StudioColors.coral).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
        .padding(.top, 20)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Catch me up")
    }

    private var running: some View {
        let count = navigation.unreadRows.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TealDot(size: 9)
                Text("Claude is reading \(count) unread \(count == 1 ? "thread" : "threads")…")
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach([440, 340, 390], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(StudioColors.field)
                        .frame(maxWidth: CGFloat(width), minHeight: 9, maxHeight: 9)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.trailing, 8)
    }

    private func ready(_ brief: CatchUp.Brief, covered: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !brief.summary.isEmpty {
                Text(brief.summary)
                    .font(.studio(15))
                    .foregroundStyle(StudioColors.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.trailing, 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(brief.lines.enumerated()), id: \.offset) { _, line in
                    CatchUpLine(line: line, available: navigation.hasRow(line)) { navigation.show(line) }
                }
            }
            .padding(.leading, -8)
            if CatchUp.isStale(briefRowKeys: covered, current: navigation.unreadRows) {
                HStack(spacing: 6) {
                    Text("New since this brief")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                    Text("·").font(.studio(12)).foregroundStyle(StudioColors.muted)
                    LinkButton(title: "Refresh") { navigation.runCatchUp() }
                        .help("Catch me up again (⌘R)")
                }
                .padding(.top, 2)
            }
        }
    }

    private func failed(_ why: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StudioIcon(.alert, size: 13)
                .foregroundStyle(StudioColors.danger)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            VStack(alignment: .leading, spacing: 3) {
                Text("Couldn't catch up")
                    .font(.studio(13, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Text(why)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            StudioButton(title: "Try again", style: .secondary, enabled: !navigation.unreadRows.isEmpty, height: 28) {
                navigation.runCatchUp()
            }
        }
        .padding(.trailing, 8)
        .accessibilityElement(children: .combine)
    }
}

/// One line of the brief: a quiet row that selects the notification it's about; dimmed once its rows are gone.
private struct CatchUpLine: View {
    let line: CatchUp.Line
    let available: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(StudioColors.line3)
                    .frame(width: 5, height: 5)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                Text(line.text)
                    .font(.studio(13))
                    .foregroundStyle(available ? StudioColors.body : StudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StudioIcon(.chevronRight, size: 11)
                    .foregroundStyle(StudioColors.muted)
                    .opacity(hovering && available ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering && available ? StudioColors.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help(available ? "Show this notification" : "Its notifications are gone")
        .accessibilityHint(available ? "Selects its notification" : "")
    }
}

/// The card's ✕.
private struct CardClose: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            StudioIcon(.close, size: 12)
                .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? StudioColors.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Dismiss the brief")
        .accessibilityLabel("Dismiss the brief")
    }
}

/// A word that acts, in ink, underlined on hover: the stale line's Refresh.
private struct LinkButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.studio(12, .semibold))
                .foregroundStyle(StudioColors.ink)
                .underline(hovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Do not disturb: the bell and the coral switch, bound to the hub's prefs (the same switch as Settings').
private struct DoNotDisturbSwitch: View {
    @ObservedObject private var hub = NotificationHub.shared

    var body: some View {
        HStack(spacing: 8) {
            QuietBell(muted: hub.prefs.doNotDisturb, size: 14)
                .foregroundStyle(StudioColors.muted)
            Text("Do not disturb")
                .font(.studio(12, .medium))
                .foregroundStyle(StudioColors.ink)
            SettingsSwitch(label: "Do not disturb", isOn: Binding(get: { hub.prefs.doNotDisturb },
                                                                 set: { hub.prefs.doNotDisturb = $0 }))
        }
        .padding(.leading, 2)
        .frame(height: 30)
        .help("No nudge cards while it's on; everything still lands here")
    }
}

/// The bell, struck through while nudges are held.
struct QuietBell: View {
    let muted: Bool
    let size: CGFloat

    var body: some View {
        StudioIcon(.bell, size: size)
            .overlay {
                if muted {
                    Path { path in
                        path.move(to: CGPoint(x: size * 0.12, y: size * 0.12))
                        path.addLine(to: CGPoint(x: size * 0.88, y: size * 0.88))
                    }
                    .stroke(style: StrokeStyle(lineWidth: max(1.2, size * 0.075), lineCap: .round))
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Filters

/// All · Slack · GitHub · Meetings · Claude, each with its unread count, on a segmented track; the chosen one is the
/// raised face. A paused source says so (its reason in the tooltip). Compact (the side bar): the sources as glyphs.
struct NoticeFilterBar: View {
    let compact: Bool
    @ObservedObject private var hub = NotificationHub.shared
    @ObservedObject private var navigation = NotificationsNavigation.shared
    @ObservedObject private var features = StudioFeatures.shared

    var body: some View {
        HStack(spacing: 2) {
            chip(nil)
            ForEach(NoticeText.sources, id: \.self) { chip($0) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(StudioColors.field))
        .fixedSize(horizontal: !compact, vertical: true)
        .animation(.easeOut(duration: 0.24), value: navigation.filter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter notifications")
        .onAppear(perform: resetHiddenFilter)
        .onChange(of: features.enabled) { _, _ in resetHiddenFilter() }
    }

    /// A feature switched off while its source was the filter: back to All.
    private func resetHiddenFilter() {
        if let source = navigation.filter, !NoticeText.sources.contains(source) { navigation.filter = nil }
    }

    private func chip(_ source: Notice.Source?) -> some View {
        let selected = navigation.filter == source
        let count = hub.book.unreadCount(source)
        let paused: String? = source.flatMap { if case .paused(let why) = hub.status[$0] { why } else { nil } }
        let name = source?.title ?? "All"
        return Button { navigation.filter = source } label: {
            HStack(spacing: compact ? 5 : 6) {
                if compact, let source {
                    NoticeGlyph(source: source, size: 13)
                } else {
                    Text(name).font(.studio(12, selected ? .semibold : .medium))
                }
                if paused != nil {
                    if compact {
                        StudioIcon(.pause, size: 10).foregroundStyle(StudioColors.amber)
                    } else {
                        Text("paused").font(.studio(11, .semibold)).foregroundStyle(StudioColors.amber)
                    }
                }
                if count > 0 {
                    Text("\(count > 99 ? "99+" : "\(count)")")
                        .font(.studioMono(11, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? StudioColors.ink : StudioColors.muted)
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(selected ? StudioColors.ink : StudioColors.muted)
            .padding(.horizontal, compact ? 6 : 12)
            .frame(maxWidth: compact ? .infinity : nil)
            .frame(height: compact ? 24 : 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? StudioColors.solid : .clear)
                .shadow(color: .black.opacity(selected ? 0.16 : 0), radius: 1, y: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(paused.map { "\(name) is paused: \($0)" } ?? (count > 0 ? "\(name): \(count) unread" : name))
        .accessibilityLabel(name + (count > 0 ? ", \(count) unread" : "") + (paused.map { ", paused: \($0)" } ?? ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Sections and rows

/// A section's caption with its count and a hairline running out to the edge; Earlier's is a button that folds it.
struct NoticeSectionView: View {
    let section: NoticeBook.Section
    let now: Date
    var compact = false
    @ObservedObject private var navigation = NotificationsNavigation.shared

    private var folds: Bool { section.kind == .earlier }
    private var open: Bool { !folds || navigation.earlierOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            heading
            if open {
                VStack(alignment: .leading, spacing: compact ? 1 : 0) {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        if compact {
                            NoticeSidebarRow(row: row, now: now)
                        } else {
                            NoticeRow(row: row, now: now, first: index == 0, last: index == section.rows.count - 1)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private var heading: some View {
        let label = HStack(spacing: 8) {
            if folds {
                StudioIcon(.chevronRight, size: 11)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(StudioColors.muted)
            }
            Caption(section.kind.title)
            Text("\(section.rows.count)")
                .font(.studioMono(11))
                .foregroundStyle(StudioColors.muted)
            if !compact {
                Rectangle().fill(StudioColors.line2).frame(height: 1)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(height: compact ? 26 : 20)
        .padding(.horizontal, compact ? 10 : 0)
        .contentShape(Rectangle())
        return Group {
            if folds {
                Button {
                    withAnimation(.easeOut(duration: 0.24)) { navigation.earlierOpen.toggle() }
                } label: { label }
                    .buttonStyle(.plain)
                    .help(open ? "Fold Earlier" : "Show Earlier")
                    .accessibilityLabel("Earlier, \(section.rows.count) threads, \(open ? "shown" : "folded")")
            } else {
                label.accessibilityElement(children: .combine)
            }
        }
    }
}

/// One thread on the page. The gutter: the age in mono over the spine, with the thread's light on it. Then the
/// sender's picture (the source's glyph on its corner), **title** · place and `+N` folded, and the last line. Reply,
/// Open and Done wait at the right edge for the pointer or the selection. Click selects; double-click opens.
struct NoticeRow: View {
    let row: NoticeBook.Row
    let now: Date
    let first: Bool
    let last: Bool
    @ObservedObject private var navigation = NotificationsNavigation.shared
    @ObservedObject private var hub = NotificationHub.shared
    @State private var hovering = false

    static let gutter: CGFloat = 64
    /// Where the light sits on the spine, from the row's top: level with the title's middle.
    private static let lightY: CGFloat = 19
    private static let inset: CGFloat = 7
    private static let spineX: CGFloat = 13

    private var notice: Notice { row.newest }
    private var selected: Bool { navigation.selection == row.id }
    private var done: Bool { notice.state == .done && !row.unread }
    private var canReply: Bool { hub.canReply(notice) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
            NoticeBadge(notice: notice, size: 28)
                .padding(.top, 3)
                .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(notice.title)
                        .font(.studio(13, row.unread ? .semibold : .medium))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let place = notice.place, !place.isEmpty {
                        Text("·").font(.studio(12)).foregroundStyle(StudioColors.muted)
                        Text(place)
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .lineLimit(1)
                    }
                    if row.folded > 0 {
                        Text("+\(row.folded)")
                            .font(.studioMono(10.5, .medium))
                            .foregroundStyle(StudioColors.muted)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(StudioColors.chip))
                            .help("\(row.folded) more in this thread")
                    }
                }
                Text(notice.preview.isEmpty ? notice.kind.label : notice.preview)
                    .font(.studio(12.5))
                    .foregroundStyle(row.unread ? StudioColors.body : StudioColors.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.top, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .padding(.leading, 12)
                .padding(.top, 5)
        }
        .padding(.trailing, 10)
        .padding(.vertical, Self.inset)
        .background { plate }
        .background(alignment: .topLeading) { spine }
        .opacity(done ? 0.62 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { navigation.select(row) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { navigation.open(row) })
        .contextMenu { NoticeMenu(row: row) }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .animation(.easeOut(duration: 0.16), value: selected)
        .id(row.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NoticeText.spoken(row, now: now))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { navigation.open(row) }
        .accessibilityAction(named: "Open") { navigation.open(row) }
        .accessibilityActions {
            if canReply { Button("Reply") { navigation.reply(row) } }
            if !done { Button("Done") { navigation.done(row) } }
        }
    }

    /// The light on the spine and the age beside it.
    private var gutter: some View {
        HStack(spacing: 0) {
            ZStack {
                if row.unread {
                    Circle().fill(StudioColors.coral).frame(width: 7, height: 7)
                } else {
                    Rectangle().fill(StudioColors.line3).frame(width: 7, height: 1)
                }
            }
            .frame(width: Self.spineX * 2, height: 14)
            Text(NoticeText.age(notice.date, now: now))
                .font(.studioMono(11, row.unread ? .medium : .regular))
                .foregroundStyle(row.unread ? StudioColors.ink : StudioColors.muted)
                .lineLimit(1)
                .fixedSize()
                .help(notice.date.formatted(date: .abbreviated, time: .shortened))
            Spacer(minLength: 0)
        }
        .frame(width: Self.gutter, alignment: .leading)
        .padding(.top, Self.lightY - Self.inset - 7)
    }

    /// The hairline through the gutter, joining this row's light to its neighbours'.
    private var spine: some View {
        GeometryReader { proxy in
            let y = Self.lightY
            Path { path in
                if !first {
                    path.move(to: CGPoint(x: Self.spineX, y: 0))
                    path.addLine(to: CGPoint(x: Self.spineX, y: y - 6))
                }
                if !last {
                    path.move(to: CGPoint(x: Self.spineX, y: y + 6))
                    path.addLine(to: CGPoint(x: Self.spineX, y: proxy.size.height))
                }
            }
            .stroke(StudioColors.line, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var plate: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? StudioColors.selection : hovering ? StudioColors.hover : .clear)
    }

    /// Reply (when the source can), Open, Done: kept in the layout so a row never reflows under the pointer, shown on
    /// hover or selection.
    private var actions: some View {
        let shown = hovering || selected
        return HStack(spacing: 2) {
            if let custom = notice.actions, !custom.isEmpty {
                // A source's own buttons (Tickets: Move to Done · Not now); the rest are in the context menu.
                ForEach(custom, id: \.id) { action in
                    RowAction(icon: nil, title: action.title, key: nil) { hub.act(notice, actionID: action.id) }
                }
            } else if canReply {
                RowAction(icon: .reply, title: "Reply", key: "R") { navigation.reply(row) }
            }
            RowAction(icon: nil, title: "Open", key: "↩") { navigation.open(row) }
            if !done {
                RowAction(icon: .check, title: "Done", key: "E") { navigation.done(row) }
            }
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(true)
    }
}

/// A row's quiet action: its words (and icon), its key in the tooltip.
private struct RowAction: View {
    let icon: StudioIcons.Name?
    let title: String
    let key: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { StudioIcon(icon, size: 12) }
                Text(title).font(.studio(12, .medium))
            }
            .foregroundStyle(hovering ? StudioColors.ink : StudioColors.body)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? StudioColors.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(StudioColors.line, lineWidth: hovering ? 0 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(key.map { "\(title) (\($0))" } ?? title)
    }
}

/// A row's right-click menu, on the page and in the side bar.
struct NoticeMenu: View {
    let row: NoticeBook.Row
    @ObservedObject private var hub = NotificationHub.shared
    private var navigation: NotificationsNavigation { .shared }

    var body: some View {
        if let actions = row.newest.actions, !actions.isEmpty {
            ForEach(actions + (row.newest.moreActions ?? []), id: \.id) { action in
                Button(action.title) { hub.act(row.newest, actionID: action.id) }
            }
            Divider()
        }
        Button("Open") { navigation.open(row) }
        if hub.canReply(row.newest) {
            Button("Reply") { navigation.reply(row) }
        }
        if row.unread {
            Button("Mark as Read") { hub.markRead(row) }
        }
        if !(row.newest.state == .done && !row.unread) {
            Button("Done") { navigation.done(row) }
        }
    }
}

/// Who a notice is from: their picture or initials with the source's glyph on its corner (Slack, GitHub); else the
/// glyph alone on a quiet tile (meetings, Claude).
struct NoticeBadge: View {
    let notice: Notice
    let size: CGFloat

    var body: some View {
        if notice.avatarURL != nil || !notice.people.isEmpty {
            NoticeAvatar(notice: notice, size: size)
                .overlay(alignment: .bottomTrailing) {
                    NoticeGlyph(source: notice.source, size: size * 0.32)
                        .foregroundStyle(StudioColors.ink)
                        .padding(size * 0.09)
                        .background(Circle().fill(StudioColors.solid))
                        .overlay(Circle().strokeBorder(StudioColors.line, lineWidth: 0.5))
                        .offset(x: size * 0.14, y: size * 0.14)
                }
        } else {
            NoticeGlyph(source: notice.source, size: size * 0.54)
                .foregroundStyle(StudioColors.body)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).fill(StudioColors.field))
        }
    }
}

// MARK: - Empty state and footer

/// "All clear", and what's being watched: the spine trailing off in dashes beside it, as on Home.
private struct NotificationsEmpty: View {
    let filter: Notice.Source?
    @ObservedObject private var hub = NotificationHub.shared

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Circle().strokeBorder(StudioColors.line3, lineWidth: 1).frame(width: 7, height: 7)
                Path { path in
                    path.move(to: CGPoint(x: 0.5, y: 0))
                    path.addLine(to: CGPoint(x: 0.5, y: 40))
                }
                .stroke(StudioColors.line, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .frame(width: 1, height: 40)
                .padding(.top, 4)
            }
            .frame(width: 26)
            .padding(.top, 5)
            VStack(alignment: .leading, spacing: 6) {
                Text(filter.map { "Nothing from \($0.title)" } ?? "All clear")
                    .font(.studio(15, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Text(NoticeText.watching(hub.status, only: filter))
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, NoticeRow.gutter - 26)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Show done, and the page's keys.
private struct NotificationsFooter: View {
    let hasRows: Bool
    @ObservedObject private var hub = NotificationHub.shared
    @ObservedObject private var navigation = NotificationsNavigation.shared

    var body: some View {
        let doneCount = hub.book.rows(filter: navigation.filter, showDone: true)
            .filter { $0.newest.state == .done && !$0.unread }.count
        if hasRows || doneCount > 0 || navigation.showDone {
            content(doneCount)
        }
    }

    private func content(_ doneCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle().fill(StudioColors.line2).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    showDone(doneCount)
                    Spacer(minLength: 12)
                    if hasRows { keys }
                }
                VStack(alignment: .leading, spacing: 10) {
                    showDone(doneCount)
                    if hasRows { keys }
                }
            }
        }
    }

    @ViewBuilder private func showDone(_ count: Int) -> some View {
        if count > 0 || navigation.showDone {
            Toggle(isOn: $navigation.showDone) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Show done").font(.studio(12, .medium))
                    Text("\(count)").font(.studioMono(11))
                }
                .foregroundStyle(StudioColors.body)
            }
            .toggleStyle(.checkbox)
            .tint(StudioColors.coral)
            .fixedSize()
        }
    }

    private var keys: some View {
        HStack(spacing: 12) {
            key("↑↓", "Move")
            key("↩", "Open")
            if navigation.selectedRow.map({ hub.canReply($0.newest) }) == true { key("R", "Reply") }
            key("E", "Done")
            key("⇧⌘A", "Mark all read")
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func key(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Kbd(keys)
            Text(label).font(.studio(11.5)).foregroundStyle(StudioColors.muted)
        }
    }
}

// MARK: - Words

enum NoticeText {
    /// `now`, `4m`, `2h`, `3d`, then the day (`Oct 7`).
    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// VoiceOver's line for a row.
    static func spoken(_ row: NoticeBook.Row, now: Date) -> String {
        let notice = row.newest
        var parts = [row.unread ? "Unread" : nil, notice.source.title, notice.title, notice.place,
                     notice.preview.isEmpty ? nil : notice.preview].compactMap { $0 }
        if row.folded > 0 { parts.append("\(row.folded) more in the thread") }
        let age = age(notice.date, now: now)
        parts.append(age == "now" ? "just now" : "\(age) ago")
        return parts.joined(separator: ", ")
    }

    /// A source's state: what it says, or (until it reports) on for Meetings and Claude, which need nothing, and off
    /// for Slack and GitHub.
    static func state(_ source: Notice.Source, _ status: [Notice.Source: SourceStatus]) -> SourceStatus {
        status[source] ?? (source == .meeting || source == .claude ? .running : .off)
    }

    /// The sources this build has: Tickets and Automations show only while their feature is on.
    @MainActor static var sources: [Notice.Source] {
        Notice.Source.allCases.filter { source in
            switch source {
            case .tickets: StudioFeatures.shared.isOn(.tickets)
            case .automations: StudioFeatures.shared.isOn(.automations)
            default: true
            }
        }
    }

    /// "Watching Meetings and Claude. Slack and GitHub are off." with any paused source and its reason.
    @MainActor static func watching(_ status: [Notice.Source: SourceStatus], only: Notice.Source?) -> String {
        let sources = only.map { [$0] } ?? Self.sources
        var running: [String] = [], off: [String] = [], paused: [String] = []
        for source in sources {
            switch state(source, status) {
            case .running: running.append(source.title)
            case .off: off.append(source.title)
            case .paused(let why): paused.append("\(source.title) is paused: \(why).")
            }
        }
        var lines: [String] = []
        if !running.isEmpty {
            lines.append(only == nil ? "Watching \(list(running))." : "Watching \(list(running)); new ones show here.")
        }
        if !off.isEmpty { lines.append("\(list(off)) \(off.count == 1 ? "is" : "are") off.") }
        lines.append(contentsOf: paused)
        return lines.joined(separator: " ")
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
