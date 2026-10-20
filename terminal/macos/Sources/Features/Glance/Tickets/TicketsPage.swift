import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Tickets page (spec 2026-10-09-tickets-design.md, "Tickets page and side bar"), set as a ranked log beside
/// Notifications': the rank in mono down a hairline spine, each ticket's status as a light on it and in words at the
/// right, the key and title, and Claude's one-line reason under them. Sections Today and Up next. Colour marks status
/// and urgency, always next to their words.
struct TicketsPage: View {
    @ObservedObject private var service = TicketService.shared
    @ObservedObject private var probe = ConnectorProbe.shared
    @ObservedObject private var navigation = TicketsNavigation.shared
    @AppStorage("ticketsLayout") private var layout: TicketsLayout = .list

    static let maxWidth: CGFloat = 860

    var body: some View {
        // "Due tomorrow" and "as of" move on with the clock.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let arranged = navigation.arranged()
            GeometryReader { geometry in
                let wide = geometry.size.width >= Self.inspectorFrom
                let picked = selected(in: arranged)
                HStack(spacing: 0) {
                    content(arranged: arranged, now: now)
                        .environment(\.ticketsInspector, wide)
                    if wide, let picked {
                        Rectangle().fill(StudioColors.line).frame(width: 1)
                        TicketInspector(ticket: picked.ticket, reason: picked.reason, now: now)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.88), value: wide && picked != nil)
            }
        }
    }

    /// Wider than this, the selected ticket opens in the side panel; narrower, it expands in place.
    static let inspectorFrom: CGFloat = 980

    /// The selected ticket with Claude's reason, from the visible rows, else the book.
    private func selected(in arranged: TicketRanking.Arranged) -> (ticket: Ticket, reason: String?)? {
        guard let id = navigation.selection else { return nil }
        if let item = (arranged.today + arranged.upNext).first(where: { $0.ticket.id == id }) {
            return (item.ticket, item.reason)
        }
        return service.book.ticket(id).map { ($0, nil) }
    }

    private func content(arranged: TicketRanking.Arranged, now: Date) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    TicketsHeader(arranged: arranged, now: now)
                    TicketsSummaryCard(now: now)
                    TicketsNotes()
                    TicketsTrackerBar()
                        .padding(.top, 18)
                    TicketSuggestions()
                    if arranged.today.isEmpty && arranged.upNext.isEmpty {
                        TicketsEmpty()
                            .padding(.top, 36)
                    } else if layout == .board {
                        TicketsBoard(tickets: (arranged.today + arranged.upNext).map(\.ticket), now: now)
                            .padding(.top, 20)
                        TicketsFooter(arranged: arranged, now: now)
                            .padding(.top, 28)
                    } else {
                        TicketSection(title: "Today", rows: arranged.today, numbered: true, now: now)
                            .padding(.top, 24)
                        if !arranged.upNext.isEmpty {
                            TicketSection(title: "Up next", rows: arranged.upNext, numbered: false, now: now)
                                .padding(.top, 26)
                        }
                        TicketsDoneToday(now: now)
                        TicketsFooter(arranged: arranged, now: now)
                            .padding(.top, 28)
                    }
                }
                .frame(maxWidth: layout == .board ? .infinity : Self.maxWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(.easeOut(duration: 0.18), value: navigation.selection)
            .onChange(of: navigation.selection) { _, selection in
                guard let selection else { return }
                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(selection) }
            }
        }
    }
}

// MARK: - Header

/// "Tickets", what's open and when it was read, and on the right Re-rank (R) and Refresh. Below 560 pt the controls
/// drop under the title.
private struct TicketsHeader: View {
    let arranged: TicketRanking.Arranged
    let now: Date
    @ObservedObject private var service = TicketService.shared
    @ObservedObject private var probe = ConnectorProbe.shared

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
            Text("Tickets")
                .font(.studio(19, .bold))
                .tracking(-0.19)
                .foregroundStyle(StudioColors.ink)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(arranged.today.count)").font(.studioMono(12)).contentTransition(.numericText())
                Text(" today").font(.studio(12.5))
                if !arranged.upNext.isEmpty {
                    Text("  ·  ").font(.studio(12.5))
                    Text("\(arranged.upNext.count)").font(.studioMono(12)).contentTransition(.numericText())
                    Text(" up next").font(.studio(12.5))
                }
                Text("  ·  as of ").font(.studio(12.5))
                Text(TicketText.asOf(service.book.asOf, now: now)).font(.studioMono(12))
            }
            .foregroundStyle(StudioColors.muted)
            .accessibilityElement(children: .combine)
        }
        .fixedSize()
    }

    private var controls: some View {
        let fetching = probe.checking || service.states.values.contains(.fetching)
        return HStack(spacing: 10) {
            RerankButton()
            StudioButton(title: "Refresh", icon: .refresh, style: .quiet, busy: fetching && !service.ranking) {
                service.refresh()
            }
            .help("Read your tickets again from each tracker, without a new order")
        }
        .fixedSize()
    }
}

// MARK: - Re-rank and Claude's read of the day

/// The page's one action Claude takes: a capsule on the raised face with the coral dot (teal while Claude orders), its
/// words and R. The glow lights only on hover and while running, so a resting page stays still.
private struct RerankButton: View {
    @ObservedObject private var service = TicketService.shared
    @ObservedObject private var navigation = TicketsNavigation.shared
    @State private var hovering = false

    var body: some View {
        let running = service.ranking
        let reading = running && service.states.values.contains(.fetching)
        let enabled = !service.enabledTrackers.isEmpty
        Button { navigation.rerank() } label: {
            HStack(spacing: 7) {
                if running { TealDot(size: 11) } else { CoralDot(size: 11) }
                Text(reading ? "Reading…" : running ? "Ordering…" : "Re-rank")
                    .font(.studio(12, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Kbd("R")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(TicketsGlow(lit: running || (hovering && enabled)))
        .disabled(!enabled || running)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .help(running ? (reading ? "Reading your tickets from each tracker" : "Claude is ordering your tickets")
              : enabled ? "Read your tickets again and let Claude order them for today (R)" : "No tracker connected")
        .accessibilityLabel(reading ? "Reading" : running ? "Ordering" : "Re-rank")
    }
}

/// MASTER §7.1's glow ring, lit only on demand (as Notifications' Catch me up): at rest a hairline capsule on the
/// raised face; lit, the aurora turning once every 3 s with its halo. The loop runs only while lit, on screen and
/// without Reduce Motion.
private struct TicketsGlow: ViewModifier {
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

/// Claude's read of the day under the header: while ordering, a quiet line; the summary in the reading size with when
/// it was made; a failure says why with Try again. ✕ closes it until the next rank.
private struct TicketsSummaryCard: View {
    let now: Date
    @ObservedObject private var service = TicketService.shared
    @ObservedObject private var navigation = TicketsNavigation.shared

    var body: some View {
        Group {
            if navigation.summaryHidden {
                EmptyView()
            } else if service.ranking {
                card {
                    HStack(spacing: 10) {
                        TealDot(size: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.states.values.contains(.fetching) ? "Reading your trackers…"
                                 : "Claude is ordering your tickets for today…")
                                .font(.studio(12.5, .medium))
                                .foregroundStyle(StudioColors.ink)
                            Text("Your list below stays usable. This can take a minute or two.")
                                .font(.studio(12))
                                .foregroundStyle(StudioColors.muted)
                        }
                        Spacer(minLength: 8)
                        StudioButton(title: "Stop", style: .quiet, height: 24) { service.stopRanking() }
                            .help("Stop ordering and keep the plain order")
                    }
                }
            } else if let error = service.rankError {
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error)
                            .font(.studio(12.5))
                            .foregroundStyle(StudioColors.body)
                            .fixedSize(horizontal: false, vertical: true)
                        StudioButton(title: "Try again", icon: .refresh, style: .secondary, height: 26) {
                            navigation.rerank()
                        }
                    }
                }
            } else if let rank = service.book.rank, !rank.summary.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(rank.summary)
                            .font(.studio(13.5))
                            .foregroundStyle(StudioColors.ink)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 640, alignment: .leading)
                        Text("Claude · " + TicketText.asOf(rank.date, now: now))
                            .font(.studioMono(11))
                            .foregroundStyle(StudioColors.muted)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.24), value: service.ranking)
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        StudioCard(rim: true) {
            HStack(alignment: .top, spacing: 12) {
                content()
                Spacer(minLength: 8)
                Button { navigation.summaryHidden = true } label: {
                    StudioIcon(.close, size: 12)
                        .foregroundStyle(StudioColors.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Claude's read of the day")
                .accessibilityLabel("Close")
            }
            .padding(16)
        }
        .padding(.top, 18)
        .transition(.opacity)
    }
}

// MARK: - Notes

/// The page's banners: Claude's usage limit, and a tracker connector that couldn't be checked.
private struct TicketsNotes: View {
    @ObservedObject private var service = TicketService.shared
    @ObservedObject private var probe = ConnectorProbe.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let until = service.pausedUntil, until > Date() {
                note("Claude's usage limit is reached — Tickets will read your trackers again after "
                     + until.formatted(date: .omitted, time: .shortened) + ".")
            }
            if let error = probe.error, probe.checked, !probe.trackers.isEmpty {
                note(error)
            }
        }
        .padding(.top, 14)
    }

    private func note(_ text: String) -> some View {
        HStack(spacing: 10) {
            StudioIcon(.alert, size: 14)
                .foregroundStyle(StudioColors.amber)
            Text(text)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.noteInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.note))
    }
}

// MARK: - Trackers and the filter

/// All · one chip per connected tracker with its count (a failed fetch says so), and the filter field (⌘F).
struct TicketsTrackerBar: View {
    var compact = false
    @ObservedObject private var service = TicketService.shared
    @ObservedObject private var probe = ConnectorProbe.shared
    @ObservedObject private var navigation = TicketsNavigation.shared
    @FocusState private var filterFocused: Bool

    var body: some View {
        let trackers = service.enabledTrackers
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    if trackers.count > 1 { chips(trackers) }
                    field
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        chips(trackers)
                        Spacer(minLength: 12)
                        TicketsLayoutPicker()
                        field.frame(width: 220)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            chips(trackers)
                            Spacer(minLength: 12)
                            TicketsLayoutPicker()
                        }
                        field
                    }
                }
            }
        }
        .onChange(of: navigation.focusFilter) { filterFocused = true }
    }

    private func chips(_ trackers: [Tracker]) -> some View {
        HStack(spacing: 6) {
            chip(title: "All", count: service.book.tickets.count, failure: nil, selected: navigation.tracker == nil) {
                navigation.tracker = nil
            }
            ForEach(trackers) { tracker in
                let failure: String? = if case .failed(let message) = service.states[tracker.server] { message } else { nil }
                chip(title: tracker.name, count: service.book.tickets.filter { $0.tracker == tracker.server }.count,
                     failure: failure, selected: navigation.tracker == tracker.server) {
                    navigation.tracker = navigation.tracker == tracker.server ? nil : tracker.server
                }
            }
        }
    }

    private func chip(title: String, count: Int, failure: String?, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if failure != nil {
                    StudioIcon(.alert, size: 11)
                        .foregroundStyle(StudioColors.danger)
                }
                Text(title)
                    .font(.studio(12, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? StudioColors.ink : StudioColors.body)
                Text(failure == nil ? "\(count)" : "failed")
                    .font(failure == nil ? .studioMono(11) : .studio(11, .medium))
                    .foregroundStyle(failure == nil ? StudioColors.muted : StudioColors.danger)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(selected ? StudioColors.selection : StudioColors.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(failure.map { "\(title) couldn't be read: \($0)" } ?? "Show \(title == "All" ? "every tracker" : title)")
        .accessibilityLabel("\(title), \(failure == nil ? "\(count) tickets" : "failed")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var field: some View {
        HStack(spacing: 6) {
            StudioIcon(.search, size: 13)
                .foregroundStyle(StudioColors.muted)
            TextField("Filter by key or title", text: $navigation.query)
                .textFieldStyle(.plain)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.ink)
                .focused($filterFocused)
                .onExitCommand { navigation.query = ""; filterFocused = false }
            if !compact { Kbd("⌘F") }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(filterFocused ? StudioColors.coral : .clear, lineWidth: 1))
        .accessibilityLabel("Filter tickets")
    }
}

// MARK: - Sections and rows

/// A section's caption, its count and a hairline, then its rows.
struct TicketSection: View {
    let title: String
    let rows: [TicketRanking.Ranked]
    let numbered: Bool
    let now: Date
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            HStack(spacing: 8) {
                Caption(title)
                Text("\(rows.count)")
                    .font(.studioMono(11))
                    .foregroundStyle(StudioColors.muted)
                if compact { Spacer(minLength: 0) } else { Rectangle().fill(StudioColors.line2).frame(height: 1) }
            }
            .frame(height: compact ? 26 : 20)
            .padding(.horizontal, compact ? 10 : 0)
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: compact ? 1 : 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    if compact {
                        TicketSidebarRow(item: item, number: numbered ? index + 1 : nil)
                        TicketPreview(ticket: item.ticket, reason: item.reason, now: now, indent: 8)
                    } else {
                        TicketRow(item: item, number: numbered ? index + 1 : nil, first: index == 0,
                                  last: index == rows.count - 1, now: now)
                        TicketPreview(ticket: item.ticket, reason: item.reason, now: now, indent: 48)
                    }
                }
            }
        }
    }
}

/// One ticket. The gutter: its rank in mono over the spine, with its status as a light. Then the key and title, and
/// Claude's reason (or where it's from) under them; at the right its urgency, due date and status in words. Click
/// selects; double-click or ↩ opens the ticket.
struct TicketRow: View {
    let item: TicketRanking.Ranked
    let number: Int?
    let first: Bool
    let last: Bool
    let now: Date
    @ObservedObject private var navigation = TicketsNavigation.shared
    @ObservedObject private var service = TicketService.shared
    @State private var hovering = false

    private static let gutter: CGFloat = 48
    private static let lightY: CGFloat = 17
    private static let inset: CGFloat = 8
    private static let spineX: CGFloat = 10

    private var ticket: Ticket { item.ticket }
    private var selected: Bool { navigation.selection == ticket.id }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ticket.key)
                        .font(.studioMono(11.5, .medium))
                        .foregroundStyle(StudioColors.muted)
                        .fixedSize()
                    Text(ticket.title)
                        .font(.studio(13, .semibold))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(detail)
                    .font(.studio(12.5))
                    .foregroundStyle(item.reason == nil ? StudioColors.muted : StudioColors.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            facts
                .padding(.leading, 12)
                .padding(.top, 1)
        }
        .padding(.trailing, 10)
        .padding(.vertical, Self.inset)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? StudioColors.selection : hovering ? StudioColors.hover : .clear)
        }
        .background(alignment: .topLeading) { spine }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { navigation.select(ticket) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { navigation.open(ticket) })
        .contextMenu { TicketMenu(ticket: ticket) }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .animation(.easeOut(duration: 0.16), value: selected)
        .id(ticket.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { navigation.open(ticket) }
    }

    /// Claude's reason, else the sprint and the tracker.
    private var detail: String {
        if let reason = item.reason { return reason }
        return [ticket.sprint, ticket.assignee.map { "Assigned to \($0)" }]
            .compactMap { $0 }.joined(separator: " · ").ifEmpty("Not ranked yet")
    }

    private var facts: some View {
        HStack(spacing: 8) {
            if ticket.group == .upNext && ticket.statusCategory == .todo {
                StudioButton(title: "Assign + Start", style: .secondary, busy: service.moving.contains(ticket.id),
                             height: 22) { service.start(ticket) }
                    .help("Assign \(ticket.key) to you and move it into progress")
                    .opacity(hovering || selected ? 1 : 0)
                    .allowsHitTesting(hovering || selected)
            } else {
                StudioButton(title: "Work on this", icon: .terminal, style: .quiet, height: 22) {
                    TicketRouter.workOn(ticket, near: NSApp.keyWindow)
                }
                .help("A terminal tab in \(ticket.key)'s project with Claude started on it")
                .opacity(hovering || selected ? 1 : 0)
                .allowsHitTesting(hovering || selected)
            }
            if let urgency = TicketText.urgency(ticket) {
                StatePill(text: urgency.text, tone: urgency.tone, height: 20)
            }
            if let due = ticket.due {
                let words = TicketText.due(due, now: now)
                Text(words.text)
                    .font(.studioMono(11, words.late ? .medium : .regular))
                    .foregroundStyle(words.late ? StudioColors.danger : StudioColors.muted)
                    .fixedSize()
                    .help(due.formatted(date: .complete, time: .omitted))
            }
            TicketStatusMenu(ticket: ticket)
        }
        .fixedSize()
    }

    private var gutter: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(light)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(StudioColors.line3, lineWidth: ticket.statusCategory == .todo ? 1 : 0))
                .frame(width: Self.spineX * 2, height: 14)
            Text(number.map(String.init) ?? "")
                .font(.studioMono(12, .medium))
                .foregroundStyle(number == 1 ? StudioColors.ink : StudioColors.muted)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .frame(width: Self.gutter, alignment: .leading)
        .padding(.top, Self.lightY - Self.inset - 7)
    }

    /// The status light: hollow to do, amber in progress, teal in review.
    private var light: Color {
        switch ticket.statusCategory {
        case .todo, .unknown: StudioColors.background
        case .inProgress: StudioColors.amber
        case .review: StudioColors.tealInk
        case .done: StudioColors.ok
        }
    }

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

    private var spoken: String {
        var parts = [number.map { "\($0)." } ?? "", ticket.key, ticket.title, ticket.status]
        if let urgency = TicketText.urgency(ticket) { parts.append(urgency.text) }
        if let due = ticket.due { parts.append(TicketText.due(due, now: now).text) }
        if let reason = item.reason { parts.append(reason) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A ticket's status in words, and the menu of statuses it can move to now (one click moves it). A spinner while it
/// moves.
struct TicketStatusMenu: View {
    let ticket: Ticket
    @ObservedObject private var service = TicketService.shared

    var body: some View {
        if service.moving.contains(ticket.id) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Moving…").font(.studio(11, .semibold)).foregroundStyle(StudioColors.muted)
            }
            .frame(height: 20)
        } else if ticket.transitions.isEmpty {
            StatePill(text: ticket.status, tone: TicketText.tone(ticket.statusCategory), height: 20)
        } else {
            Menu {
                ForEach(ticket.transitions, id: \.id) { transition in
                    Button("Move to \(transition.name)") {
                        service.move(ticket, to: transition, reason: "By you", auto: false)
                    }
                }
            } label: {
                StatePill(text: ticket.status, icon: .chevronDown,
                          tone: TicketText.tone(ticket.statusCategory), height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change \(ticket.key)'s status")
            .accessibilityLabel("\(ticket.status). Change status")
        }
    }
}

/// A ticket's context menu.
struct TicketMenu: View {
    let ticket: Ticket
    @ObservedObject private var service = TicketService.shared

    var body: some View {
        Button("Open \(ticket.key)") { TicketRouter.open(ticket) }
            .disabled(ticket.url == nil)
        if !ticket.transitions.isEmpty {
            Menu("Move to") {
                ForEach(ticket.transitions, id: \.id) { transition in
                    Button(transition.name) { service.move(ticket, to: transition, reason: "By you", auto: false) }
                }
            }
        }
        if ticket.group == .upNext && ticket.statusCategory == .todo {
            Button("Assign to Me and Start") { service.start(ticket) }
        }
        Button("Work on This") { TicketRouter.workOn(ticket, near: NSApp.keyWindow) }
        Divider()
        Button("Copy Key") { copy(ticket.key) }
        if let url = ticket.url {
            Button("Copy Link") { copy(url.absoluteString) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Suggestions and done today

/// What Glance noticed and wants the user to confirm: each pending suggestion's ticket, its evidence (a link when it
/// has one) and the same buttons as its nudge.
private struct TicketSuggestions: View {
    @ObservedObject private var service = TicketService.shared
    @State private var expanded = false

    private static let preview = 3

    var body: some View {
        let items = service.book.suggestions.pending.compactMap { suggestion in
            service.book.ticket(suggestion.ticketID).map { (suggestion, $0) }
        }
        if !items.isEmpty {
            let shown = expanded ? items : Array(items.prefix(Self.preview))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Caption("Suggestions")
                    Text("\(items.count)").font(.studioMono(11)).foregroundStyle(StudioColors.muted)
                    Rectangle().fill(StudioColors.line2).frame(height: 1)
                }
                .frame(height: 20)
                Text("Glance noticed work that looks like it moves these tickets. Accept to move one, or dismiss it.")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
                ForEach(shown, id: \.0.id) { suggestion, ticket in
                    TicketSuggestionRow(suggestion: suggestion, ticket: ticket)
                }
                if items.count > Self.preview {
                    Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                        Text(expanded ? "Show fewer" : "Show all \(items.count)")
                            .font(.studio(12, .medium))
                            .foregroundStyle(StudioColors.coralInk)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 24)
        }
    }
}

private struct TicketSuggestionRow: View {
    let suggestion: Suggestion
    let ticket: Ticket
    @ObservedObject private var service = TicketService.shared
    @State private var hovering = false

    var body: some View {
        let notice = TicketNotices.suggestion(suggestion, ticket: ticket)
        HStack(alignment: .center, spacing: 12) {
            StudioIcon(.suggest, size: 14)
                .foregroundStyle(StudioColors.coralInk)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ticket.key).font(.studioMono(11.5, .medium)).foregroundStyle(StudioColors.muted).fixedSize()
                    Text(ticket.title)
                        .font(.studio(13, .semibold))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                }
                Group {
                    if let link = suggestion.link {
                        Link(suggestion.evidence, destination: link)
                    } else {
                        Text(suggestion.evidence)
                    }
                }
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.body)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if service.moving.contains(ticket.id) {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array((notice.actions ?? []).enumerated()), id: \.element.id) { index, action in
                        StudioButton(title: action.title, style: index == 0 ? .primary : .secondary, height: 26) {
                            service.handle(notice, actionID: action.id)
                        }
                    }
                    if let more = notice.moreActions, !more.isEmpty {
                        Menu {
                            ForEach(more, id: \.id) { action in
                                Button(action.title) { service.handle(notice, actionID: action.id) }
                            }
                        } label: {
                            StudioIcon(.chevronDown, size: 12)
                                .foregroundStyle(StudioColors.body)
                                .frame(width: 26, height: 26)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More")
                    }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hovering ? StudioColors.hover : .clear))
        .onHover { hovering = $0 }
        .contextMenu { TicketMenu(ticket: ticket) }
    }
}

/// Today's moves into done, newest first: the key, its title and how it got there.
private struct TicketsDoneToday: View {
    let now: Date
    @ObservedObject private var service = TicketService.shared

    var body: some View {
        let moves = service.book.moves(on: now, calendar: .current).filter { $0.toCategory == .done }
        if !moves.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Caption("Done today")
                    Text("\(moves.count)").font(.studioMono(11)).foregroundStyle(StudioColors.muted)
                    Rectangle().fill(StudioColors.line2).frame(height: 1)
                }
                .frame(height: 20)
                ForEach(moves) { move in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        StudioIcon(.check, size: 12).foregroundStyle(StudioColors.ok)
                        Text(move.key).font(.studioMono(11.5)).foregroundStyle(StudioColors.muted).fixedSize()
                        Text(service.book.ticket(move.ticketID)?.title ?? move.to)
                            .font(.studio(12.5))
                            .foregroundStyle(StudioColors.body)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(move.reason + " · " + move.date.formatted(date: .omitted, time: .shortened))
                            .font(.studio(11.5))
                            .foregroundStyle(StudioColors.muted)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                }
            }
            .padding(.top, 26)
        }
    }
}

// MARK: - Empty and footer

/// What the page says with nothing to list: looking for trackers, none connected (and how to connect one), nothing
/// fetched yet, a filter that matches nothing, or everything done.
private struct TicketsEmpty: View {
    @ObservedObject private var service = TicketService.shared
    @ObservedObject private var probe = ConnectorProbe.shared
    @ObservedObject private var navigation = TicketsNavigation.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(words.title)
                .font(.studio(15, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text(words.line)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
            if let action = words.action {
                StudioButton(title: action.title, icon: action.icon, style: .secondary,
                             busy: probe.checking || service.states.values.contains(.fetching), action: action.run)
                    .padding(.top, 6)
            }
        }
    }

    private var words: (title: String, line: String, action: (title: String, icon: StudioIcons.Name, run: () -> Void)?) {
        let checkAgain = (title: "Check again", icon: StudioIcons.Name.refresh, run: { probe.check(force: true) })
        let refresh = (title: "Refresh", icon: StudioIcons.Name.refresh, run: { service.refresh() })
        if !probe.checked {
            return ("Looking for your trackers…", "Claude Code is saying which connectors it has.", nil)
        }
        if service.enabledTrackers.isEmpty {
            if let error = probe.error { return ("Couldn't check your connectors", error, checkAgain) }
            // Added but not signed in: say so, and where to sign in (a claude.ai connector's sign-in is on claude.ai).
            if service.allTrackers.isEmpty, let signIn = TrackerProbe.signInWords(probe.servers) {
                let connectors = (title: "Open Connectors", icon: StudioIcons.Name.plug,
                                  run: { ConnectorsSettings.open() })
                let claudeAI = (title: "Open claude.ai Connectors", icon: StudioIcons.Name.plug, run: {
                    _ = BrowserTabController.open(url: ConnectorsSettings.claudeConnectors, from: NSApp.keyWindow)
                })
                let onClaudeAI = TrackerProbe.signInNeeded(probe.servers).contains { $0.server.isClaudeAI }
                return (signIn.title, signIn.line, onClaudeAI ? claudeAI : connectors)
            }
            return ("No tracker connected",
                    "Tickets reads Jira through Claude's connector or straight from a site Glance is signed in to, "
                        + "and Linear or GitHub through Claude. Connect one in Settings → Connectors.",
                    (title: "Open Connectors", icon: StudioIcons.Name.plug, run: { ConnectorsSettings.open() }))
        }
        if service.book.tickets.isEmpty {
            if service.states.values.contains(.fetching) {
                return ("Reading your tickets…", "Reading what's assigned to you from each tracker.", nil)
            }
            let failures = service.states.values.compactMap { state -> String? in
                if case .failed(let message) = state { return message } else { return nil }
            }
            if let failure = failures.first { return ("Couldn't read your tickets", failure, refresh) }
            return ("Nothing fetched yet", "Refresh reads what's assigned to you and what's open in your sprint.",
                    refresh)
        }
        if !navigation.query.isEmpty || navigation.tracker != nil {
            return ("No tickets match", "Try another key or words, or show every tracker.",
                    (title: "Show all", icon: .close, run: {
                        navigation.query = ""
                        navigation.tracker = nil
                    }))
        }
        return ("Nothing open", "Every ticket assigned to you is done.", refresh)
    }
}

/// How the order was made.
private struct TicketsFooter: View {
    let arranged: TicketRanking.Arranged
    let now: Date
    @ObservedObject private var service = TicketService.shared

    var body: some View {
        Text(words)
            .font(.studio(11.5))
            .foregroundStyle(StudioColors.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var words: String {
        if arranged.ranked, let rank = service.book.rank {
            return "Ordered by Claude at \(TicketText.asOf(rank.date, now: now)). Tickets it didn't place follow in the "
                + "plain order."
        }
        return "Plain order: urgency first, then the due date, then what's already started."
    }
}

extension String {
    /// `fallback` when this is empty.
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// The selected ticket, previewed in place under its row or inside its board card (no new tab or window): status,
/// urgency, due, who and where, Claude's reason, the Claude box, and the buttons to open it fully (also ↩ or
/// double-click) or start work on it. `indent` 0 means inside a card, which supplies its own edges.
struct TicketPreview: View {
    let ticket: Ticket
    let reason: String?
    let now: Date
    let indent: CGFloat
    @ObservedObject private var navigation = TicketsNavigation.shared

    private var embedded: Bool { indent == 0 }

    var body: some View {
        if navigation.selection == ticket.id {
            VStack(alignment: .leading, spacing: 10) {
                if embedded { Rectangle().fill(StudioColors.line2).frame(height: 1) }
                HStack(spacing: 6) {
                    StatePill(text: ticket.status, tone: TicketText.tone(ticket.statusCategory), height: 20)
                    if let urgency = TicketText.urgency(ticket) {
                        StatePill(text: urgency.text, tone: urgency.tone, height: 20)
                    }
                    if let due = ticket.due {
                        let words = TicketText.due(due, now: now)
                        Text(words.text)
                            .font(.studioMono(11, words.late ? .medium : .regular))
                            .foregroundStyle(words.late ? StudioColors.danger : StudioColors.muted)
                    }
                }
                if let reason {
                    Text(reason)
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.body)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let facts = [ticket.assignee.map { "Assigned to \($0)" }, ticket.sprint, ticket.repository,
                             ticket.updated.map { "Updated " + TicketText.asOf($0, now: now) }]
                    .compactMap { $0 }.joined(separator: " · ")
                if !facts.isEmpty {
                    Text(facts)
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TicketClaudeEdit(ticket: ticket)
                HStack(spacing: 6) {
                    StudioButton(title: "Open \(ticket.key)", style: .secondary, height: 24) {
                        TicketRouter.open(ticket)
                    }
                    StudioButton(title: "Work on this", icon: .terminal, style: .quiet, height: 24) {
                        TicketRouter.workOn(ticket, near: NSApp.keyWindow)
                    }
                }
            }
            .padding(.leading, indent)
            .padding(.trailing, embedded ? 0 : 10)
            .padding(.top, embedded ? 4 : 0)
            .padding(.bottom, embedded ? 0 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
