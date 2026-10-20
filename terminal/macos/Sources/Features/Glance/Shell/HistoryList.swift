import AppKit
import GlanceCore
import GlanceKit
import Observation
import SwiftUI

/// A suggestions popup over a terminal (the Tab menu, the ↑ list, ⌃R): ShellAssist keeps one open at a time, tells it
/// when the line changes, and hands it the keys while it is open.
@MainActor
protocol ShellOverlay: AnyObject {
    var session: ShellSession? { get }
    var surface: Ghostty.SurfaceView? { get }
    var window: NSWindow? { get }
    /// The shell's line changed. False closes the popup.
    func lineChanged(_ text: String, cursor: Int) -> Bool
    func handleKey(_ event: NSEvent) -> Bool
    /// A ⌘ key while it's open (⌘C in Claude's panel).
    func handleKeyEquivalent(_ event: NSEvent) -> Bool
    func close()
}

extension ShellOverlay {
    func handleKeyEquivalent(_ event: NSEvent) -> Bool { false }
}

/// The ↑ list (spec "S2: history"): this tab's commands at the bottom, newest first going up, then this folder's, then
/// the rest; typing keeps editing the line and narrows the list. ↑ ↓ move (↓ past the newest closes), ⏎ runs, Tab or →
/// puts it on the line, Esc closes, ⌃R opens the search.
@MainActor
final class HistoryList: ShellOverlay {
    private(set) weak var session: ShellSession?
    private(set) weak var surface: Ghostty.SurfaceView?
    let model: HistoryListModel
    private let popup: ShellPopup
    /// The pick: the command and whether to run it.
    var onPick: ((String, _ run: Bool) -> Void)?
    var onSearch: ((String) -> Void)?
    var onClose: (() -> Void)?

    static let margin: CGFloat = 18
    var window: NSWindow? { popup.parent }

    init(session: ShellSession, surface: Ghostty.SurfaceView, rows: @escaping (String) -> [HistoryRow]) {
        self.session = session
        self.surface = surface
        model = HistoryListModel(folder: session.folder, rows: rows)
        popup = ShellPopup(HistoryListView(model: model).padding(Self.margin))
        model.onPick = { [weak self] index in
            self?.model.selected = index
            self?.pick(run: true)
        }
    }

    func show() {
        guard let surface, let window = surface.window, let cursor = surface.cursorScreenRect, let session else { return }
        model.refresh(typed: session.text)
        let width = HistoryListView.width(in: window)
        // Lined up with the start of the input (one line: the cursor less what's before it), kept in the window.
        let column = CGFloat(session.text.prefix(session.cursor).count) * max(surface.cellSize.width, 1)
        let start = max(cursor.minX - column, window.frame.minX + 8)
        let anchor = NSRect(x: start, y: cursor.minY, width: 1, height: cursor.height)
        popup.show(over: window, anchor: anchor, size: size(width: width), leading: Self.margin + 8,
                   margin: Self.margin, preferAbove: true)
    }

    private func size(width: CGFloat) -> NSSize {
        NSSize(width: width + Self.margin * 2, height: model.cardHeight + Self.margin * 2)
    }

    func lineChanged(_ text: String, cursor: Int) -> Bool {
        model.refresh(typed: text)
        if let window { popup.resize(to: size(width: HistoryListView.width(in: window))) }
        return true
    }

    func close() { popup.close() }

    private func pick(run: Bool) {
        guard let row = model.current else { return }
        onPick?(row.entry.command, run)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 126: model.move(older: true)                       // ↑
        case 125:                                               // ↓, past the newest closes
            if model.selected == 0 { onClose?() } else { model.move(older: false) }
        case 36, 76: pick(run: true)                            // ⏎
        case 48, 124: pick(run: false)                          // ⇥, →
        case 53: onClose?()                                     // esc
        default:
            guard flags == .control, event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }
            onSearch?(session?.text ?? "")
        }
        return true
    }
}

@MainActor
@Observable
final class HistoryListModel {
    static let visibleRows = 12
    static let rowHeight: CGFloat = 26
    static let headerHeight: CGFloat = 22
    static let footerHeight: CGFloat = 28

    /// Newest first: row 0 sits at the bottom, next to the prompt.
    private(set) var rows: [HistoryRow] = []
    var selected = 0
    let folder: String
    @ObservationIgnored private let source: (String) -> [HistoryRow]
    @ObservationIgnored var onPick: ((Int) -> Void)?

    init(folder: String, rows: @escaping (String) -> [HistoryRow]) {
        self.folder = folder
        source = rows
    }

    var current: HistoryRow? { rows.indices.contains(selected) ? rows[selected] : nil }

    func refresh(typed: String) {
        let previous = current?.entry.command
        rows = source(typed)
        selected = rows.firstIndex { $0.entry.command == previous } ?? 0
    }

    func move(older: Bool) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + (older ? 1 : -1), 0), rows.count - 1)
    }

    var cardHeight: CGFloat {
        let shown = min(rows.count, Self.visibleRows)
        let sections = Set(rows.prefix(Self.visibleRows).map(\.section)).count
        let content = rows.isEmpty ? Self.rowHeight : CGFloat(shown) * Self.rowHeight + CGFloat(sections) * Self.headerHeight
        return content + 8 + Self.footerHeight
    }
}

/// The ↑ list's card: the house solid card; each row the command in mono (newlines as ⏎) with, on the right, a failed
/// run's ✕ and code, the folder when it isn't this one, and how long ago.
struct HistoryListView: View {
    let model: HistoryListModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    static func width(in window: NSWindow) -> CGFloat {
        min(720, max(440, window.frame.width * 0.62))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.rows.isEmpty {
                            Text("No command in your history matches what you typed.")
                                .font(.studio(12))
                                .foregroundStyle(StudioColors.muted)
                                .padding(.horizontal, 10)
                                .frame(height: HistoryListModel.rowHeight)
                        }
                        // Oldest at the top, the newest at the bottom by the prompt.
                        ForEach(Array(model.rows.enumerated()).reversed(), id: \.element.id) { index, row in
                            if index == model.rows.count - 1 || model.rows[index + 1].section != row.section {
                                ShellListHeader(title: Self.title(row.section))
                            }
                            HistoryRowView(command: row.entry.command, highlight: row.highlight,
                                           exit: row.entry.lastExit,
                                           folder: row.entry.lastFolder == model.folder ? nil : row.entry.lastFolder,
                                           when: row.entry.recordedCount > 0 ? row.entry.lastStart : nil,
                                           selected: index == model.selected)
                                .id(row.entry.command)
                                .onTapGesture { model.onPick?(index) }
                        }
                    }
                    .padding(4)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.selected) { _, _ in
                    if let row = model.current { proxy.scrollTo(row.entry.command) }
                }
            }
            ShellHints(hints: [("⏎", "run"), ("⇥", "edit"), ("⌃R", "search"), ("esc", "close")])
        }
        .frame(height: model.cardHeight)
        .shellCard(shape)
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : -4)
        .onAppear { withAnimation(.easeOut(duration: 0.16)) { shown = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command history")
    }

    static func title(_ section: HistorySection) -> String {
        switch section {
        case .tab: "This tab"
        case .folder: "This folder"
        case .everywhere: "Everywhere"
        }
    }
}

// MARK: - Shared pieces of the history popups

/// A history row: the command (one line, ⏎ for newlines, the matched characters strong), then its exit mark, folder,
/// duration and age.
struct HistoryRowView: View {
    let command: String
    let highlight: [Range<Int>]
    let exit: Int?
    let folder: String?
    /// When it last ran; nil for a command only imported from zsh's file (its time isn't known).
    let when: Date?
    var duration: TimeInterval? = nil
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(Self.text(command, highlight))
                .font(.studioMono(13))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 12)
            if let exit, exit != 0 {
                Text("✕ \(exit)")
                    .font(.studioMono(11, .medium))
                    .foregroundStyle(StudioColors.danger)
                    .accessibilityLabel("failed with \(exit)")
            }
            if let folder {
                Text(ShellFormat.folder(folder))
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 180, alignment: .trailing)
            }
            if let duration {
                Text(ShellFormat.duration(duration))
                    .font(.studioMono(11))
                    .foregroundStyle(StudioColors.muted)
            }
            if let when {
                Text(ShellFormat.age(when))
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                    .frame(minWidth: 28, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: HistoryListModel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? StudioColors.selection : Color.clear))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(StudioColors.coral).frame(width: 2, height: 14).offset(x: 1) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    static func text(_ command: String, _ ranges: [Range<Int>]) -> AttributedString {
        // One line: each newline shows as ⏎ (one character, so the ranges still line up).
        let flat = String(command.map { $0 == "\n" ? "⏎" : $0 })
        var text = AttributedString(flat)
        text.foregroundColor = StudioColors.body
        let count = flat.count
        for range in ranges where range.lowerBound >= 0 && range.upperBound <= count {
            let lower = text.index(text.startIndex, offsetByCharacters: range.lowerBound)
            let upper = text.index(text.startIndex, offsetByCharacters: range.upperBound)
            text[lower..<upper].foregroundColor = StudioColors.ink
            text[lower..<upper].font = .studioMono(13, .semibold)
        }
        return text
    }
}

/// A group's label in a suggestions list: 11pt caps, tracked, muted.
struct ShellListHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.studio(10.5, .semibold))
            .tracking(0.6)
            .foregroundStyle(StudioColors.muted)
            .padding(.horizontal, 10)
            .frame(height: HistoryListModel.headerHeight, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The footer's key hints: each key as a chip, then what it does.
struct ShellHints: View {
    let hints: [(String, String)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(hints, id: \.0) { key, action in
                HStack(spacing: 5) {
                    Text(key)
                        .font(.studioMono(10.5, .medium))
                        .foregroundStyle(StudioColors.body)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(StudioColors.chip))
                    Text(action).font(.studio(11)).foregroundStyle(StudioColors.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: HistoryListModel.footerHeight)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
    }
}

extension View {
    /// The suggestions' card (MASTER.md): solid, no glass behind code; a hairline, the rim's light along the top, 12pt
    /// corners and a warm shadow.
    func shellCard<S: InsettableShape>(_ shape: S) -> some View {
        background(shape.fill(StudioColors.solid))
            .overlay(shape.strokeBorder(StudioColors.line, lineWidth: 1))
            .overlay(shape.inset(by: 0.5).stroke(LinearGradient(colors: [StudioColors.rim, .clear], startPoint: .top,
                                                                 endPoint: .init(x: 0.5, y: 0.12)), lineWidth: 1))
            .clipShape(shape)
            .shadow(color: Color(red: 0.11, green: 0.07, blue: 0.04).opacity(0.26), radius: 14, y: 6)
    }
}

/// How the popups write folders, durations and ages.
enum ShellFormat {
    static func folder(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return String(format: seconds < 10 ? "%.1fs" : "%.0fs", seconds) }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes)m \(Int(seconds) % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 60): return "\(Int(seconds / (86_400 * 7)))w"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30)))mo"
        default: return "\(Int(seconds / (86_400 * 365)))y"
        }
    }
}
