import AppKit
import GlanceCore
import GlanceKit
import Observation
import SwiftUI

/// The Tab menu (spec 2026-10-08-terminal-suggestions-design.md, "S1: the Tab menu"): zsh's candidates in a card at the
/// cursor. Typing keeps editing the line and narrows the list; ↑ ↓ move, ⏎ inserts, Tab inserts (and opens a folder),
/// Esc closes. The terminal keeps the keyboard; ShellAssist hands this the keys it uses.
@MainActor
final class CompletionMenu: ShellOverlay {
    private(set) weak var session: ShellSession?
    private(set) weak var surface: Ghostty.SurfaceView?
    let request: Int
    let model: CompletionMenuModel
    private let popup: ShellPopup
    var onAccept: ((CompletionMatch, _ open: Bool) -> Void)?
    var onClose: (() -> Void)?

    /// The card's room for its shadow inside the panel.
    static let margin: CGFloat = 18

    var window: NSWindow? { popup.parent }

    init(session: ShellSession, surface: Ghostty.SurfaceView, request: Int, total: Int,
         candidates: [CompletionCandidate], boost: @escaping (CompletionCandidate) -> Double = { _ in 0 }) {
        self.session = session
        self.surface = surface
        self.request = request
        model = CompletionMenuModel(total: total, candidates: candidates, boost: boost)
        popup = ShellPopup(CompletionMenuView(model: model).padding(Self.margin))
        model.onPick = { [weak self] index in
            guard let self else { return }
            self.model.selected = index
            self.accept(open: false)
        }
    }

    /// Narrows to what the line now says. False when nothing matches any more (the menu should close).
    func lineChanged(_ line: String, cursor: Int) -> Bool {
        guard model.update(line: line, cursor: cursor) else { return false }
        if popup.isVisible { popup.resize(to: size) }
        return true
    }

    func show() {
        guard let surface, let window = surface.window, let anchor = surface.cursorScreenRect else { return }
        // The candidates' text starts under the typed word: back by what was typed, and past the row's icon column.
        let typed = CGFloat(model.typedLength) * max(surface.cellSize.width, 1)
        popup.show(over: window, anchor: anchor, size: size, leading: typed + CompletionMenuView.textInset + Self.margin,
                   margin: Self.margin)
    }

    func close() {
        popup.close()
    }

    private var size: NSSize {
        let card = model.cardSize
        return NSSize(width: card.width + Self.margin * 2, height: card.height + Self.margin * 2)
    }

    private func accept(open: Bool) {
        guard let match = model.current else { return }
        onAccept?(match, open)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 125: model.move(1)                                   // ↓
        case 126: model.move(-1)                                  // ↑
        case 121: model.move(CompletionMenuModel.visibleRows)     // page down
        case 116: model.move(-CompletionMenuModel.visibleRows)    // page up
        case 36, 76: accept(open: false)                          // ⏎, enter
        case 48: if flags.contains(.shift) { model.move(-1) } else { accept(open: true) } // ⇥, ⇧⇥
        case 53: onClose?()                                       // esc
        default:
            guard flags == .control, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
            switch key {
            case "p": model.move(-1)
            case "n": model.move(1)
            default: return false
            }
        }
        return true
    }
}

/// What the Tab menu shows: zsh's candidates narrowed to the typed text, in sections, and the keyboard's highlight.
@MainActor
@Observable
final class CompletionMenuModel {
    static let visibleRows = 10
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 22
    static let footerHeight: CGFloat = 28

    let total: Int
    let candidates: [CompletionCandidate]
    private(set) var sections: [CompletionSection] = []
    private(set) var flat: [CompletionMatch] = []
    var selected = 0
    /// How many characters of the word are typed (to line the card up under it).
    private(set) var typedLength = 0
    @ObservationIgnored var onPick: ((Int) -> Void)?
    /// What was picked in this place before (more first).
    @ObservationIgnored private let boost: (CompletionCandidate) -> Double

    init(total: Int, candidates: [CompletionCandidate], boost: @escaping (CompletionCandidate) -> Double) {
        self.total = total
        self.candidates = candidates
        self.boost = boost
    }

    /// Candidates the shell had and didn't send (it sends 2,000 at most).
    var unsent: Int { max(0, total - candidates.count) }
    var current: CompletionMatch? { flat.indices.contains(selected) ? flat[selected] : nil }
    var showsHeaders: Bool { sections.count > 1 }

    func update(line: String, cursor: Int) -> Bool {
        let previous = current?.candidate.index
        var typed = 0
        let sections = CompletionFilter.sections(candidates) { candidate in
            guard let text = CompletionFilter.query(line: line, cursor: cursor, start: candidate.start,
                                                    hidden: candidate.hidden) else { return nil }
            // A space the shell didn't escape ends the word: the menu is done.
            if text.hasSuffix(" ") && !text.hasSuffix("\\ ") { return nil }
            typed = text.unicodeScalars.count
            return CompletionCandidate.unquoted(text)
        } boost: { [boost] in boost($0) }
        guard !sections.isEmpty else { return false }
        self.sections = sections
        flat = sections.flatMap(\.matches)
        typedLength = typed
        selected = flat.firstIndex { $0.candidate.index == previous } ?? 0
        return true
    }

    func move(_ delta: Int) {
        guard !flat.isEmpty else { return }
        if abs(delta) == 1 {
            selected = (selected + delta + flat.count) % flat.count // wraps, like zsh's menu
        } else {
            selected = min(max(selected + delta, 0), flat.count - 1)
        }
    }

    /// The card: wide enough for the longest name and a description, between 280 and 560 points; ten rows high at most.
    var cardSize: CGSize {
        let longestName = flat.map(\.candidate.name.count).max() ?? 0
        let longestDetail = min(flat.map(\.candidate.detail.count).max() ?? 0, 56)
        var width = CompletionMenuView.textInset + CGFloat(longestName) * 7.9 + 16
        if longestDetail > 0 { width += 20 + CGFloat(longestDetail) * 6.4 }
        width = min(max(width, 280), 560)
        let headers = showsHeaders ? sections.filter { !$0.title.isEmpty }.count : 0
        let more = unsent > 0 ? Self.rowHeight : 0
        let content = CGFloat(flat.count) * Self.rowHeight + CGFloat(headers) * Self.headerHeight + more
        let shown = min(content, CGFloat(Self.visibleRows) * Self.rowHeight + Self.headerHeight)
        return CGSize(width: width, height: shown + 8 + Self.footerHeight)
    }
}

/// The card (MASTER.md): solid (no glass behind code), the rim, a warm shadow, 12pt corners; 24pt rows with the kind's
/// icon, the candidate in mono with the typed part strong, and what it does, muted.
struct CompletionMenuView: View {
    let model: CompletionMenuModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    /// From the card's edge to the candidate's text: the card's padding, the row's, the icon and the gap.
    static let textInset: CGFloat = 4 + 8 + 14 + 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let size = model.cardSize
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.sections) { section in
                            if model.showsHeaders, !section.title.isEmpty {
                                Text(section.title.uppercased())
                                    .font(.studio(10.5, .semibold))
                                    .tracking(0.6)
                                    .foregroundStyle(StudioColors.muted)
                                    .padding(.horizontal, 10)
                                    .frame(height: CompletionMenuModel.headerHeight, alignment: .bottomLeading)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(section.matches) { match in
                                row(match).id(match.candidate.index)
                            }
                        }
                        if model.unsent > 0 {
                            Text("\(model.unsent) more, keep typing")
                                .font(.studio(12))
                                .foregroundStyle(StudioColors.muted)
                                .padding(.horizontal, 10)
                                .frame(height: CompletionMenuModel.rowHeight)
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.selected) { _, _ in
                    if let match = model.current { proxy.scrollTo(match.candidate.index) }
                }
            }
            footer
        }
        .frame(width: size.width, height: size.height)
        .background(shape.fill(StudioColors.solid))
        .overlay(shape.strokeBorder(StudioColors.line, lineWidth: 1))
        // The rim: a light along the top edge, fading down the sides.
        .overlay(shape.inset(by: 0.5).stroke(LinearGradient(colors: [StudioColors.rim, .clear], startPoint: .top,
                                                             endPoint: .init(x: 0.5, y: 0.12)), lineWidth: 1))
        .clipShape(shape)
        .shadow(color: Color(red: 0.11, green: 0.07, blue: 0.04).opacity(0.26), radius: 14, y: 6)
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : 4)
        .onAppear { withAnimation(.easeOut(duration: 0.16)) { shown = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completions")
    }

    private func row(_ match: CompletionMatch) -> some View {
        let isSelected = model.current?.candidate.index == match.candidate.index
        let candidate = match.candidate
        return HStack(spacing: 8) {
            Image(systemName: Self.symbol(candidate.kind))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? StudioColors.coralInk : StudioColors.muted)
                .frame(width: 14)
            Text(Self.highlighted(candidate.name, match.highlight))
                .font(.studioMono(13))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 12)
            if !candidate.detail.isEmpty {
                Text(candidate.detail)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: CompletionMenuModel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? StudioColors.selection : Color.clear))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule().fill(StudioColors.coral).frame(width: 2, height: 14).offset(x: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.onPick?(model.flat.firstIndex { $0.candidate.index == candidate.index } ?? 0) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([candidate.name, candidate.detail, candidate.kind.rawValue].filter { !$0.isEmpty }
            .joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("⏎", "insert")
            if model.current?.candidate.isDirectory == true { hint("⇥", "open folder") } else { hint("⇥", "insert") }
            hint("esc", "close")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: CompletionMenuModel.footerHeight)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
    }

    private func hint(_ key: String, _ action: String) -> some View {
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

    static func symbol(_ kind: CompletionCandidate.Kind) -> String {
        switch kind {
        case .command: "terminal"
        case .option: "flag"
        case .folder: "folder"
        case .file: "doc"
        case .branch: "arrow.triangle.branch"
        case .host: "network"
        case .user: "person"
        case .process: "gearshape"
        case .variable: "dollarsign"
        case .value: "chevron.right"
        }
    }

    /// The name with the typed characters strong (ink, semibold) and the rest in the body colour.
    static func highlighted(_ name: String, _ ranges: [Range<Int>]) -> AttributedString {
        var text = AttributedString(name)
        text.foregroundColor = StudioColors.body
        let characters = Array(name)
        for range in ranges where range.lowerBound >= 0 && range.upperBound <= characters.count {
            let lower = text.index(text.startIndex, offsetByCharacters: range.lowerBound)
            let upper = text.index(text.startIndex, offsetByCharacters: range.upperBound)
            text[lower..<upper].foregroundColor = StudioColors.ink
            text[lower..<upper].font = .studioMono(13, .semibold)
        }
        return text
    }
}
