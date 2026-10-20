import GlanceCore
import SwiftUI

/// How the Files page lays a diff out: the toolbar's Unified / Split.
enum DiffLayout: String {
    case unified, split
}

/// The diff list's coordinate space, where line numbers report their frames for a drag across them.
enum DiffSpace {
    static let name = "diff"
}

/// The line under the pointer, for C and +: a reference, so hovering doesn't redraw the page.
final class HoverBox {
    var anchor: ReviewThreads.Anchor?
}

/// Where each line's numbers are, in `DiffSpace`, while a drag picks a range: a reference, so scrolling doesn't redraw
/// the page.
final class DiffLineFrames {
    var frames: [ReviewThreads.Anchor: CGRect] = [:]
}

struct DiffLineFrameKey: PreferenceKey {
    static var defaultValue: [ReviewThreads.Anchor: CGRect] = [:]

    static func reduce(value: inout [ReviewThreads.Anchor: CGRect], nextValue: () -> [ReviewThreads.Anchor: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// What a diff line can do on a page that takes comments: start one on it, or drag across numbers for a range.
struct LineInteraction {
    let hover: HoverBox
    let comment: (ReviewThreads.Anchor) -> Void
    /// Where the drag started and where it is, in `DiffSpace`.
    let drag: (CGPoint, CGPoint) -> Void
    let dragEnded: () -> Void
    /// Off on read-only diffs: the hover button and C/+ ask instead of commenting.
    var canComment = true
}

/// One row of a file's diff list, in order: a hunk's header; a line, or a row of the split view; the threads under it;
/// the comment being written.
enum DiffItem: Identifiable {
    case hunk(index: Int, header: String)
    case unified(PullRequestDiff.Line, hunk: Int)
    case split(PullRequestDiff.Row, hunk: Int, row: Int)
    case threads([ReviewThreads.Thread], anchors: [ReviewThreads.Anchor])
    /// Claude's answer box, by its id.
    case ask(String)
    case composer

    var id: String {
        switch self {
        case .hunk(let index, _): "h\(index)"
        case .unified(let line, let hunk): "u\(hunk):\(line.old ?? -1):\(line.new ?? -1)"
        case .split(_, let hunk, let row): "s\(hunk):\(row)"
        case .threads(_, let anchors): "t" + anchors.map { "\($0.side.rawValue)\($0.line)" }.joined(separator: ",")
        case .ask(let id): "a" + id
        case .composer: "composer"
        }
    }

    /// The lines a row stands for: a unified line's numbers, or both halves of a split row.
    var anchors: [ReviewThreads.Anchor] {
        switch self {
        case .unified(let line, _): Self.anchors(line)
        case .split(let pair, _, _): Self.anchors(pair)
        case .hunk, .threads, .ask, .composer: []
        }
    }

    /// A line's anchors: its old number on the left (removed and context lines), its new one on the right (added and
    /// context lines).
    static func anchors(_ line: PullRequestDiff.Line) -> [ReviewThreads.Anchor] {
        var anchors: [ReviewThreads.Anchor] = []
        if let old = line.old { anchors.append(ReviewThreads.Anchor(side: .left, line: old)) }
        if let new = line.new { anchors.append(ReviewThreads.Anchor(side: .right, line: new)) }
        return anchors
    }

    static func anchors(_ row: PullRequestDiff.Row) -> [ReviewThreads.Anchor] {
        var anchors: [ReviewThreads.Anchor] = []
        if let old = row.left?.old { anchors.append(ReviewThreads.Anchor(side: .left, line: old)) }
        if let new = row.right?.new { anchors.append(ReviewThreads.Anchor(side: .right, line: new)) }
        return anchors
    }

    /// Where a new comment on a unified line goes: the new side, unless the line was removed.
    static func commentAnchor(_ line: PullRequestDiff.Line) -> ReviewThreads.Anchor? {
        if let new = line.new { return ReviewThreads.Anchor(side: .right, line: new) }
        return line.old.map { ReviewThreads.Anchor(side: .left, line: $0) }
    }

    /// A file's list: each hunk's header and its lines (or split rows). Each line is followed by the threads on it and,
    /// on the comment's last line, the comment being written.
    static func items(_ file: PullRequestDiff.File, layout: DiffLayout, placement: ReviewThreads.Placement,
                      composing: ReviewThreads.Anchor?, asks: [ReviewThreads.Anchor: [String]] = [:]) -> [DiffItem] {
        var items: [DiffItem] = []
        for (index, hunk) in file.hunks.enumerated() {
            items.append(.hunk(index: index, header: hunk.header))
            switch layout {
            case .unified:
                for line in hunk.lines {
                    let item = DiffItem.unified(line, hunk: index)
                    items.append(item)
                    items += below(item.anchors, placement: placement, composing: composing, asks: asks)
                }
            case .split:
                for (number, pair) in PullRequestDiff.rows(hunk).enumerated() {
                    let item = DiffItem.split(pair, hunk: index, row: number)
                    items.append(item)
                    items += below(item.anchors, placement: placement, composing: composing, asks: asks)
                }
            }
        }
        return items
    }

    private static func below(_ anchors: [ReviewThreads.Anchor], placement: ReviewThreads.Placement,
                              composing: ReviewThreads.Anchor?, asks: [ReviewThreads.Anchor: [String]]) -> [DiffItem] {
        var items: [DiffItem] = []
        let threads = anchors.flatMap { placement.anchored[$0] ?? [] }
        if !threads.isEmpty { items.append(.threads(threads, anchors: anchors)) }
        items += anchors.flatMap { asks[$0] ?? [] }.map(DiffItem.ask)
        if let composing, anchors.contains(composing) { items.append(.composer) }
        return items
    }
}

/// A drag across line numbers, from the frames the numbers report (`DiffLineFrameKey`).
enum DiffPicking {
    /// The line whose numbers are at `point`: exactly there, or anywhere along their row (on `side` when given).
    static func line(at point: CGPoint, frames: [ReviewThreads.Anchor: CGRect], side: ReviewThreads.Thread.Side?,
                     exact: Bool) -> ReviewThreads.Anchor? {
        frames.first { anchor, frame in
            if exact { return frame.contains(point) }
            return (side.map { anchor.side == $0 } ?? true) && frame.minY <= point.y && point.y < frame.maxY
        }?.key
    }

    /// The line where the drag started and the one under the pointer (on the same side in the split view).
    static func picked(from start: CGPoint, to point: CGPoint, frames: [ReviewThreads.Anchor: CGRect],
                       split: Bool) -> FilesPage.Composing? {
        guard let first = line(at: start, frames: frames, side: nil, exact: true),
              let last = line(at: point, frames: frames, side: split ? first.side : nil, exact: false) else { return nil }
        return FilesPage.Composing(start: first, end: last)
    }

    /// A dragged range with its top line first; one line has no start.
    static func ordered(_ picked: FilesPage.Composing?, frames: [ReviewThreads.Anchor: CGRect]) -> FilesPage.Composing? {
        guard let picked, let first = picked.start, let a = frames[first], let b = frames[picked.end] else { return nil }
        let (top, bottom) = a.minY <= b.minY ? (first, picked.end) : (picked.end, first)
        return FilesPage.Composing(start: top == bottom ? nil : top, end: bottom)
    }

    /// The lines between a range's ends, by where their numbers are (on the same side in the split view).
    static func range(_ range: FilesPage.Composing?, frames: [ReviewThreads.Anchor: CGRect],
                      split: Bool) -> Set<ReviewThreads.Anchor> {
        guard let range, let start = range.start, let a = frames[start], let b = frames[range.end] else { return [] }
        let top = min(a.minY, b.minY), bottom = max(a.maxY, b.maxY)
        let side: ReviewThreads.Thread.Side? = split ? start.side : nil
        return Set(frames.filter { anchor, frame in
            (side.map { anchor.side == $0 } ?? true) && frame.minY >= top - 0.5 && frame.maxY <= bottom + 0.5
        }.keys)
    }
}

/// The canvas's diff tints: `okline`/`delline` under added and removed lines, `okfill`/`delfill` under the pointer or a
/// range being picked; an empty side of a split row shaded.
enum DiffColors {
    static func fill(_ kind: PullRequestDiff.Line.Kind?, strong: Bool) -> Color {
        switch kind {
        case .added?: strong ? StudioColors.okFill : StudioColors.okLine
        case .removed?: strong ? StudioColors.dangerFill : StudioColors.dangerLine
        case .context?: strong ? StudioColors.hover : .clear
        case nil: StudioColors.field.opacity(0.5)
        }
    }

    static func syntax(_ kind: SyntaxHighlight.Kind) -> Color {
        switch kind {
        case .keyword: StudioColors.syntaxKeyword
        case .string: StudioColors.syntaxString
        case .comment: StudioColors.muted
        case .number, .attribute: StudioColors.syntaxNumber
        case .type: StudioColors.syntaxType
        case .function, .property: StudioColors.syntaxFunction
        }
    }

    /// A line's code, coloured for its file's language (plain ink when there's none).
    @MainActor static func code(_ text: String, language: SyntaxHighlight.Language?) -> AttributedString {
        guard let language else { return AttributedString(text) }
        var code = AttributedString()
        for segment in SyntaxHighlight.segments(text, language: language) {
            var piece = AttributedString(segment.text)
            if let kind = segment.kind {
                piece.foregroundColor = syntax(kind)
                if kind == .comment { piece.font = .studioMono(12).italic() }
            }
            code += piece
        }
        return code
    }
}

/// A line's numbers: mono, muted, right-aligned in 52 pt columns.
/// - While the line is hovered, the coral + that starts a comment.
/// - A drag across the numbers picks a range.
/// - It reports where it is, for that drag.
struct DiffGutter: View {
    let numbers: [Int?]
    let anchor: ReviewThreads.Anchor?
    let interaction: LineInteraction?
    let hovering: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(numbers.enumerated()), id: \.offset) { _, number in
                Text(number.map(String.init) ?? "")
                    .font(.studioMono(12))
                    .foregroundStyle(StudioColors.muted)
                    .frame(width: 52, alignment: .trailing)
                    .padding(.trailing, 10)
            }
        }
        .padding(.vertical, 2.5)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) {
            if hovering, let anchor, let interaction {
                Button { interaction.comment(anchor) } label: {
                    if interaction.canComment {
                        Text("+")
                            .font(.studio(13, .bold))
                            .foregroundStyle(StudioColors.onCoral)
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(StudioColors.coral))
                    } else {
                        CoralDot(size: 12).frame(width: 18, height: 18)
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .padding(.top, 1)
                .help(interaction.canComment ? "Comment on this line (C)" : "Ask Claude about this line (A)")
                .accessibilityLabel(interaction.canComment ? "Comment on line \(anchor.line)"
                                    : "Ask Claude about line \(anchor.line)")
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(DiffSpace.name))
            .onChanged { interaction?.drag($0.startLocation, $0.location) }
            .onEnded { _ in interaction?.dragEnded() })
        .background {
            if let anchor, interaction != nil {
                GeometryReader { geometry in
                    Color.clear.preference(key: DiffLineFrameKey.self,
                                           value: [anchor: geometry.frame(in: .named(DiffSpace.name))])
                }
            }
        }
    }
}

/// A line's sign and code: + for added, − for removed. Coloured for its file's language; long lines wrap, and a missing
/// final newline says so.
struct DiffCode: View {
    let line: PullRequestDiff.Line?
    let language: SyntaxHighlight.Language?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(sign)
                .foregroundStyle(line?.kind == .removed ? StudioColors.danger : StudioColors.ok)
                .frame(width: 18, alignment: .leading)
            Text(DiffColors.code(line.map { $0.text.isEmpty ? " " : $0.text } ?? "", language: language))
                .foregroundStyle(StudioColors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if line?.noNewline == true {
                Text("no newline at end")
                    .font(.studio(10.5))
                    .foregroundStyle(StudioColors.muted)
                    .padding(.horizontal, 8)
            }
        }
        .font(.studioMono(12))
        .lineSpacing(5)
        .padding(.vertical, 2.5)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var sign: String {
        switch line?.kind {
        case .added?: "+"
        case .removed?: "−"
        case .context?, nil: ""
        }
    }

    private var spoken: String {
        guard let line else { return "" }
        switch line.kind {
        case .added: return "Added: \(line.text)"
        case .removed: return "Removed: \(line.text)"
        case .context: return line.text
        }
    }
}

/// A unified diff line: its numbers (both for a changed file, one for an added or deleted one), sign and code, tinted by
/// what happened to it and brighter under the pointer or inside a range.
struct UnifiedLineView: View {
    let line: PullRequestDiff.Line
    let twoColumns: Bool
    let language: SyntaxHighlight.Language?
    let interaction: LineInteraction?
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let anchor = DiffItem.commentAnchor(line)
        HStack(alignment: .top, spacing: 0) {
            DiffGutter(numbers: twoColumns ? [line.old, line.new] : [line.new ?? line.old], anchor: anchor,
                       interaction: interaction, hovering: hovering)
            DiffCode(line: line, language: language)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(DiffColors.fill(line.kind, strong: hovering || selected))
        .onHover { inside in
            hovering = inside
            guard let interaction, let anchor else { return }
            if inside {
                interaction.hover.anchor = anchor
            } else if interaction.hover.anchor == anchor {
                interaction.hover.anchor = nil
            }
        }
    }
}

/// A split row: the old line on the left, the new one on the right, each with its number, sign and code.
struct SplitLineView: View {
    let row: PullRequestDiff.Row
    let language: SyntaxHighlight.Language?
    let interaction: LineInteraction?
    let selected: Set<ReviewThreads.Anchor>

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            SplitHalf(line: row.left, anchor: row.left?.old.map { ReviewThreads.Anchor(side: .left, line: $0) },
                      language: language, interaction: interaction, selected: selected)
            Rectangle().fill(StudioColors.line2).frame(width: 1)
            SplitHalf(line: row.right, anchor: row.right?.new.map { ReviewThreads.Anchor(side: .right, line: $0) },
                      language: language, interaction: interaction, selected: selected)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One side of a split row; shaded when that side has no line.
private struct SplitHalf: View {
    let line: PullRequestDiff.Line?
    let anchor: ReviewThreads.Anchor?
    let language: SyntaxHighlight.Language?
    let interaction: LineInteraction?
    let selected: Set<ReviewThreads.Anchor>
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            DiffGutter(numbers: [anchor?.line], anchor: anchor, interaction: line == nil ? nil : interaction,
                       hovering: hovering)
            DiffCode(line: line, language: language)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DiffColors.fill(line?.kind, strong: hovering || anchor.map { selected.contains($0) } == true))
        .onHover { inside in
            hovering = inside && line != nil
            guard let interaction, let anchor else { return }
            if inside {
                interaction.hover.anchor = anchor
            } else if interaction.hover.anchor == anchor {
                interaction.hover.anchor = nil
            }
        }
    }
}
