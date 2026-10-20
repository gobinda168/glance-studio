import AppKit
import GlanceCore
import GlanceKit
import Observation
import SwiftUI

/// ⌃R (spec "S2: history", "⌃R search"): a search field over all of Glance's history, laid out like fzf: the field at
/// the bottom by the prompt, the best match just above it. Words match in any order. ↑ ↓ move, ⏎ runs, → at the end of
/// the field puts the command on the line, Tab cycles All / Folder / Tab, Esc closes, ⌘C copies, ⌘⌫ deletes it from
/// Glance's history. The field needs the keyboard, so this panel becomes key; closing gives it back to the terminal.
@MainActor
final class HistorySearch: NSObject, ShellOverlay, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private(set) weak var session: ShellSession?
    private(set) weak var surface: Ghostty.SurfaceView?
    private(set) weak var window: NSWindow?
    let model: HistorySearchModel
    private let panel: Panel
    private var monitor: Any?
    private var closing = false
    var onPick: ((String, _ run: Bool) -> Void)?
    var onDelete: ((String) -> Void)?
    var onClose: (() -> Void)?

    static let margin: CGFloat = 18

    init(session: ShellSession, surface: Ghostty.SurfaceView, query: String,
         search: @escaping (String, HistoryScope) -> [HistoryHit]) {
        self.session = session
        self.surface = surface
        model = HistorySearchModel(query: query, folder: session.folder, search: search)
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                      backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: HistorySearchView(model: model).padding(Self.margin))
        model.onPick = { [weak self] index in
            self?.model.selected = index
            self?.pick(run: true)
        }
    }

    func show() {
        guard let surface, let window = surface.window, let cursor = surface.cursorScreenRect, let session else { return }
        self.window = window
        let width = HistoryListView.width(in: window)
        let size = NSSize(width: width + Self.margin * 2, height: HistorySearchModel.cardHeight + Self.margin * 2)
        let column = CGFloat(session.text.prefix(session.cursor).count) * max(surface.cellSize.width, 1)
        var origin = NSPoint(x: max(cursor.minX - column, window.frame.minX + 8) - Self.margin - 8,
                             y: cursor.maxY + 2 - Self.margin)
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        if origin.y + size.height - Self.margin > screen.maxY { origin.y = cursor.minY - 2 - size.height + Self.margin }
        origin.x = min(max(origin.x, screen.minX - Self.margin + 4), screen.maxX - size.width + Self.margin - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func lineChanged(_ text: String, cursor: Int) -> Bool { true }

    /// The panel has the keyboard itself; nothing comes through the terminal while it's open.
    func handleKey(_ event: NSEvent) -> Bool { false }

    func close() {
        guard !closing else { return }
        closing = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
        // The terminal gets the keyboard back.
        if let window, let surface {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(surface)
        }
    }

    /// Clicking elsewhere closes it.
    func windowDidResignKey(_ notification: Notification) {
        guard !closing else { return }
        onClose?()
    }

    private func pick(run: Bool) {
        guard let hit = model.current else { return }
        onPick?(hit.entry.command, run)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.keyCode, flags) {
        case (126, []): model.move(worse: true)       // ↑: further from the best
        case (125, []): model.move(worse: false)      // ↓
        case (36, []), (76, []): pick(run: true)      // ⏎
        case (48, []): model.scope = model.scope.next // ⇥
        case (53, []): onClose?()                     // esc
        case (124, []):                               // → at the end of the field: edit it on the line
            guard let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length == 0,
                  editor.selectedRange().location == (editor.string as NSString).length else { return false }
            pick(run: false)
        case (8, [.command]):                         // ⌘C, unless text in the field is selected
            if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return false }
            guard let hit = model.current else { return true }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hit.entry.command, forType: .string)
        case (51, [.command]):                        // ⌘⌫
            guard let hit = model.current else { return true }
            onDelete?(hit.entry.command)
            model.refresh()
        default:
            if flags == .control, event.charactersIgnoringModifiers?.lowercased() == "r" {
                model.move(worse: true) // ⌃R again: the next one, as in zsh
                return true
            }
            return false
        }
        return true
    }
}

@MainActor
@Observable
final class HistorySearchModel {
    static let visibleRows = 14
    static let fieldHeight: CGFloat = 42
    static var cardHeight: CGFloat {
        CGFloat(visibleRows) * HistoryListModel.rowHeight + 8 + fieldHeight + HistoryListModel.footerHeight
    }

    var query: String { didSet { refresh() } }
    var scope: HistoryScope = .all { didSet { refresh() } }
    /// Best first: hit 0 sits at the bottom, by the field.
    private(set) var hits: [HistoryHit] = []
    var selected = 0
    let folder: String
    @ObservationIgnored private let search: (String, HistoryScope) -> [HistoryHit]
    @ObservationIgnored var onPick: ((Int) -> Void)?

    init(query: String, folder: String, search: @escaping (String, HistoryScope) -> [HistoryHit]) {
        self.query = query
        self.folder = folder
        self.search = search
        refresh()
    }

    var current: HistoryHit? { hits.indices.contains(selected) ? hits[selected] : nil }

    func refresh() {
        hits = search(query, scope)
        selected = 0
    }

    func move(worse: Bool) {
        guard !hits.isEmpty else { return }
        selected = min(max(selected + (worse ? 1 : -1), 0), hits.count - 1)
    }
}

struct HistorySearchView: View {
    @Bindable var model: HistorySearchModel
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        if model.hits.isEmpty {
                            Text(model.query.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "Nothing in Glance's history yet." : "No command matches “\(model.query)”.")
                                .font(.studio(12))
                                .foregroundStyle(StudioColors.muted)
                                .padding(.horizontal, 10)
                                .frame(height: HistoryListModel.rowHeight)
                        }
                        ForEach(Array(model.hits.enumerated()).reversed(), id: \.element.id) { index, hit in
                            HistoryRowView(command: hit.entry.command, highlight: hit.highlight, exit: hit.entry.lastExit,
                                           folder: hit.entry.lastFolder == model.folder ? nil : hit.entry.lastFolder,
                                           when: hit.entry.recordedCount > 0 ? hit.entry.lastStart : nil,
                                           duration: hit.entry.lastDuration, selected: index == model.selected)
                                .id(hit.entry.command)
                                .onTapGesture { model.onPick?(index) }
                        }
                    }
                    .frame(minHeight: CGFloat(HistorySearchModel.visibleRows) * HistoryListModel.rowHeight,
                           alignment: .bottom)
                    .padding(4)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.selected) { _, _ in
                    if let hit = model.current { proxy.scrollTo(hit.entry.command) }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioColors.muted)
                TextField("Search your commands", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.studioMono(13))
                    .foregroundStyle(StudioColors.ink)
                    .focused($focused)
                    .accessibilityLabel("Search command history")
                SegmentedTabs(items: HistoryScope.allCases.map { SegmentItem(value: $0, title: $0.title, count: nil) },
                              selection: $model.scope)
                    .scaleEffect(0.86, anchor: .trailing)
                    .frame(height: 28)
            }
            .padding(.horizontal, 12)
            .frame(height: HistorySearchModel.fieldHeight)
            .overlay(alignment: .top) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
            ShellHints(hints: [("⏎", "run"), ("→", "edit"), ("⇥", "scope"), ("⌘⌫", "forget"), ("esc", "close")])
        }
        .frame(height: HistorySearchModel.cardHeight)
        .shellCard(shape)
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : -4)
        .onAppear {
            focused = true
            withAnimation(.easeOut(duration: 0.16)) { shown = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search command history")
    }
}
