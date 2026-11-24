import AppKit
import GlanceCore
import SwiftUI

/// The Command board (spec 2026-11-01-command-center-design.md §5): every Claude session as a card in four lanes, from
/// `BoardModel`. The model runs only while this page is really on screen.
struct CommandPage: View {
    @ObservedObject private var model = BoardModel.shared
    @StateObject private var keys = BoardKeyMonitor()
    @State private var window: NSWindow?
    @State private var watching = false

    var body: some View {
        GeometryReader { page in
            VStack(spacing: 0) {
                CommandHeader(model: model, window: window)
                if model.loaded && model.cards.isEmpty {
                    BoardEmpty(window: window)
                } else {
                    GeometryReader { proxy in
                        // Four lanes of at least 250: the board scrolls sideways before it squeezes.
                        let width = max(proxy.size.width - 40, 4 * 250 + 3 * 12)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(BoardLane.allCases, id: \.self) { lane in
                                    BoardLaneView(lane: lane, cards: SessionBoard.ordered(model.visible, in: lane),
                                                  selection: model.selection, reply: model.reply, window: window,
                                                  loaded: model.loaded)
                                }
                            }
                            .frame(width: width, height: max(0, proxy.size.height - 16), alignment: .top)
                            .padding(.horizontal, 20).padding(.top, 16)
                        }
                    }
                }
                if page.size.width >= 700 { BoardKeyLegend() }
            }
            .frame(width: page.size.width, height: page.size.height)
            // The keys work only with nothing else focused, and SwiftUI's taps don't take the focus from the side pane or a
            // field: a click on the board's empty space does. A card or a button takes its own tap first.
            .contentShape(Rectangle())
            .onTapGesture { window?.makeFirstResponder(nil) }
        }
        .background(StudioColors.background)
        .background(WindowAccessor { found in
            window = found
            // Not inside the layout pass that reported the window; skipped if the page left that window meanwhile.
            DispatchQueue.main.async { if window === found { syncWatching(found) } }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if let window, (note.object as AnyObject?) === window { syncWatching(window) }
        }
        .onDisappear { setWatching(false, in: nil) }
    }

    /// A tab behind others is a window that's still "on screen" to SwiftUI: only a visible one keeps the model running.
    private func syncWatching(_ window: NSWindow?) {
        setWatching(window?.occlusionState.contains(.visible) == true, in: window)
    }

    /// Start and stop stay paired for this page, so the model's count of watchers holds with several windows or Command
    /// tabs open.
    private func setWatching(_ on: Bool, in window: NSWindow?) {
        guard on != watching else { return }
        watching = on
        if on {
            model.start()
            keys.start(window: window)
        } else {
            model.stop()
            keys.stop()
        }
    }
}

// MARK: Header

private struct CommandHeader: View {
    @ObservedObject var model: BoardModel
    let window: NSWindow?

    var body: some View {
        let cards = model.visible
        let counts = SessionBoard.counts(cards)
        let worktrees = Set(cards.compactMap(\.worktree)).count
        let sub = "\(cards.count) \(cards.count == 1 ? "session" : "sessions") · \(worktrees) \(worktrees == 1 ? "worktree" : "worktrees")"
            + (model.filter.map { " · " + $0 } ?? "")
        let title = VStack(alignment: .leading, spacing: 3) {
            Text("Command")
                .font(.studio(19, .bold))
                .foregroundStyle(StudioColors.ink)
                .accessibilityAddTraits(.isHeader)
            // A notice from an action (a closed tab, a missing folder) takes the sub-line for a few seconds.
            Text(model.notice ?? sub)
                .font(.studio(12, model.notice == nil ? .regular : .medium))
                .foregroundStyle(model.notice == nil ? StudioColors.muted : StudioColors.danger)
                .lineLimit(1)
                .task(id: model.notice) {
                    guard let shown = model.notice else { return }
                    try? await Task.sleep(for: .seconds(6))
                    if !Task.isCancelled, model.notice == shown { model.notice = nil }
                }
        }
        let newSession = StudioButton(title: "New session", icon: .plus, style: .primary) {
            NewSessionFlow.start(from: window)
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                title
                Spacer(minLength: 0)
                countButtons(counts)
                newSession
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    title
                    Spacer(minLength: 0)
                    newSession
                }
                ScrollView(.horizontal, showsIndicators: false) { countButtons(counts) }
            }
        }
        .padding(.top, 20).padding(.horizontal, 28).padding(.bottom, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
    }

    private func countButtons(_ counts: BoardCounts) -> some View {
        HStack(spacing: 6) {
            BoardCountButton(kind: .needsYou, count: counts.needsYou, label: "need you",
                             help: "Select the first session that needs you") { select(lane: .needsYou) }
            BoardCountButton(kind: .working, count: counts.working, label: "working",
                             help: "Select the first working session") { select(lane: .working) }
            BoardCountButton(kind: .ready, count: counts.ready, label: "ready",
                             help: "Select the first session ready for review") { select(lane: .ready) }
            BoardCountButton(kind: .failing, count: counts.failing, label: "failing",
                             help: "Select the first session with a failing check") {
                select(card: SessionBoard.ordered(model.visible).first(where: \.failing))
            }
        }
    }

    private func select(lane: BoardLane) { select(card: SessionBoard.ordered(model.visible, in: lane).first) }

    private func select(card: BoardCard?) { if let card { model.selection = card.id } }
}

/// A count in the header: its number, its words and a dot whose shape tells it from the others (amber ring, teal dot,
/// green dot, red square).
private struct BoardCountButton: View {
    enum Kind { case needsYou, working, ready, failing }

    let kind: Kind
    let count: Int
    let label: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                dot
                Text("\(count)")
                    .font(.studioMono(15, .semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.studio(12.5, .medium))
                    .foregroundStyle(StudioColors.body)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.chip))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(hovering ? StudioColors.line3 : StudioColors.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("\(count) \(label)")
        .accessibilityHint(help)
    }

    @ViewBuilder private var dot: some View {
        switch kind {
        case .needsYou: Circle().strokeBorder(StudioColors.amber, lineWidth: 2).frame(width: 7, height: 7)
        case .working: Circle().fill(StudioColors.tealInk).frame(width: 7, height: 7)
        case .ready: Circle().fill(StudioColors.ok).frame(width: 7, height: 7)
        case .failing: RoundedRectangle(cornerRadius: 2).fill(StudioColors.danger).frame(width: 7, height: 7)
        }
    }

    private var tint: Color {
        switch kind {
        case .needsYou: StudioColors.amber
        case .working: StudioColors.tealInk
        case .ready: StudioColors.ok
        case .failing: StudioColors.danger
        }
    }
}

// MARK: Lanes

private struct BoardLaneView: View {
    let lane: BoardLane
    let cards: [BoardCard]
    let selection: String?
    let reply: String?
    let window: NSWindow?
    let loaded: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                dot
                Text(lane.title)
                    .font(.studio(12.5, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Spacer(minLength: 0)
                Text("\(cards.count)")
                    .font(.studioMono(11.5, .medium))
                    .foregroundStyle(StudioColors.muted)
            }
            .padding(.horizontal, 4)
            .frame(height: 40)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(lane.title), \(cards.count)")
            .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    // Lazy, and each card compares by value: a long board draws what's on screen and only what changed.
                    LazyVStack(spacing: 8) {
                        ForEach(cards) { card in
                            BoardCardView(card: card, focused: selection == card.id, replying: reply == card.id,
                                          window: window).equatable()
                        }
                        if cards.isEmpty && loaded {
                            Text("Nothing here")
                                .font(.studio(12))
                                .foregroundStyle(StudioColors.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 8).padding(.vertical, 16)
                        }
                    }
                    .padding(.bottom, 12)
                }
                // Only the lane holding the selected card scrolls, and only as far as it must.
                .onChange(of: selection) { _, id in
                    if let id, cards.contains(where: { $0.id == id }) { proxy.scrollTo(id) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(lane == .needsYou ? StudioColors.amber.opacity(0.55) : StudioColors.line)
                .frame(height: 1)
        }
    }

    @ViewBuilder private var dot: some View {
        switch lane {
        case .needsYou: Circle().strokeBorder(StudioColors.amber, lineWidth: 2).frame(width: 7, height: 7)
        case .working: Circle().fill(StudioColors.tealInk).frame(width: 7, height: 7)
        case .ready: Circle().fill(StudioColors.ok).frame(width: 7, height: 7)
        case .done: Circle().fill(StudioColors.muted).frame(width: 7, height: 7)
        }
    }
}

// MARK: Legend and empty state

/// The board's keys, in the replica's `.cx-keys`. Shown only where the page is wide enough.
private struct BoardKeyLegend: View {
    var body: some View {
        HStack(spacing: 5) {
            BoardKey("n"); Text("next that needs you")
            BoardKey("j"); BoardKey("k"); Text("move")
            BoardKey("↵"); Text("open")
            BoardKey("r"); Text("reply")
            BoardKey("1"); Text("–"); BoardKey("4"); Text("lanes")
        }
        .font(.studio(11.5))
        .foregroundStyle(StudioColors.muted)
        .frame(maxWidth: .infinity)
        .padding(10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keys: n next that needs you, j and k move, return opens, r replies, 1 to 4 pick a lane")
    }
}

/// A key cap at 11 pt, the floor for text (the shared `Kbd` is 10.5).
private struct BoardKey: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.studioMono(11, .semibold))
            .foregroundStyle(StudioColors.body)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(StudioColors.chip))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
    }
}

private struct BoardEmpty: View {
    let window: NSWindow?

    var body: some View {
        VStack(spacing: 8) {
            Text("No Claude sessions yet")
                .font(.studio(15, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text("Sessions show here as soon as Claude runs in a Studio tab or any terminal.")
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.muted)
                .multilineTextAlignment(.center)
            StudioButton(title: "New session", icon: .plus, style: .primary) { NewSessionFlow.start(from: window) }
                .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
