import AppKit
import SwiftUI

/// Markdown as it's written, rendered as it's typed, in one editor like Notion's page: headings grow, bold and italics
/// show as such, code sits on a chip, and the Markdown marks stay in the text but dim, so there is
/// one place to type and nothing to keep in sync. Its container draws the border. `open` is where a click on a
/// link goes.
///
/// `preview` (a note) goes further, as Obsidian's live preview: the marks hide on every line but the caret's, a list's
/// `-` shows as a bullet, and `- [ ]` as a box that a click ticks (writing `[x]`, so the text stays plain Markdown).
struct LiveMarkdownEditor: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 160
    /// The page's own colour where the editor is the page (a note), the card's elsewhere.
    var background: Color = StudioColors.card
    var preview = false
    /// Lets a toolbar act on the text (the note's ☑ button).
    var handle: MarkdownEditorHandle?
    let open: (URL) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.muted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
            LiveMarkdownTextView(text: $text, minHeight: minHeight, preview: preview, handle: handle, open: open)
        }
        .background(background)
    }
}

/// What a toolbar can do to a `LiveMarkdownEditor`'s text.
@MainActor
final class MarkdownEditorHandle {
    fileprivate weak var view: NSTextView?

    /// The caret's lines become to-dos, or stop being them; with the editor not in use, a to-do starts at the end.
    func toggleChecklist() {
        guard let view else { return }
        MarkdownChecklist.toggle(in: view)
    }
}

/// The text view under `LiveMarkdownEditor`: it restyles the text storage after every edit (`MarkdownLiveStyle`) and
/// grows to its text, so the page around it scrolls. It is never shorter than `minHeight`, so a click anywhere in the
/// editor's box lands in the text view.
private struct LiveMarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let minHeight: CGFloat
    let preview: Bool
    let handle: MarkdownEditorHandle?
    let open: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, with a layout manager that can hide marks and draw the boxes.
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.textContainer?.replaceLayoutManager(MarkdownLayoutManager())
        view.preview = preview
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 14, height: 12)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.minSize = NSSize(width: 0, height: minHeight)
        view.string = text
        MarkdownLiveStyle.apply(to: view)
        handle?.view = view

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        handle?.view = view
        // A change from outside (a drafted description arriving) replaces the text; typing already matches.
        if view.string != text {
            view.string = text
        }
        MarkdownLiveStyle.apply(to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? NSTextView, let container = view.textContainer,
              let layout = view.layoutManager else { return nil }
        let width = proposal.width ?? 480
        // Measure at the proposed width, then put the container back: SwiftUI also proposes widths it won't use
        // (0, nil), and the text would otherwise wrap at whichever came last.
        let fitted = container.containerSize
        container.containerSize = NSSize(width: max(width - view.textContainerInset.width * 2, 0),
                                         height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + view.textContainerInset.height * 2
        container.containerSize = fitted
        return CGSize(width: width, height: max(height, minHeight))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LiveMarkdownTextView
        init(_ parent: LiveMarkdownTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            MarkdownLiveStyle.apply(to: view)
            view.invalidateIntrinsicContentSize()
        }

        /// The caret moving to another line shows that line's marks and hides the last one's.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? MarkdownTextView, view.preview,
                  MarkdownLiveStyle.revealed(in: view) != view.revealed else { return }
            MarkdownLiveStyle.apply(to: view)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            parent.open(url)
            return true
        }
    }
}

// MARK: - Preview: hidden marks, bullets and boxes

extension NSAttributedString.Key {
    /// A Markdown mark the preview hides (no glyph, no width).
    fileprivate static let markdownHidden = NSAttributedString.Key("GlanceMarkdownHidden")
    /// A list's `-`, `*` or `+`, drawn as a bullet.
    fileprivate static let markdownBullet = NSAttributedString.Key("GlanceMarkdownBullet")
    /// A to-do's `[ ]` or `[x]` (an NSNumber: ticked), drawn as a box.
    fileprivate static let markdownCheckbox = NSAttributedString.Key("GlanceMarkdownCheckbox")
}

/// Hides the preview's marks, turns list marks into bullets, and draws each to-do's box over its `[ ]`.
private final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    static let boxSide: CGFloat = 12

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange range: NSRange) -> Int {
        guard let storage = textStorage, range.length > 0 else { return 0 }
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: range.length))
        var newProps = Array(UnsafeBufferPointer(start: props, count: range.length))
        var changed = false
        for i in 0..<range.length {
            let index = characterIndexes[i]
            guard index < storage.length else { continue }
            if storage.attribute(.markdownHidden, at: index, effectiveRange: nil) != nil {
                newProps[i] = .null
                changed = true
            } else if storage.attribute(.markdownBullet, at: index, effectiveRange: nil) != nil,
                      let bullet = Self.bulletGlyph(in: font) {
                newGlyphs[i] = bullet
                changed = true
            }
        }
        guard changed else { return 0 }
        newGlyphs.withUnsafeBufferPointer { glyphs in
            newProps.withUnsafeBufferPointer { props in
                layoutManager.setGlyphs(glyphs.baseAddress!, properties: props.baseAddress!,
                                        characterIndexes: characterIndexes, font: font, forGlyphRange: range)
            }
        }
        return range.length
    }

    private static func bulletGlyph(in font: NSFont) -> CGGlyph? {
        var character: UniChar = 0x2022
        var glyph: CGGlyph = 0
        return CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1) ? glyph : nil
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for (range, ticked) in checkboxes(in: characters) {
            guard let rect = boxRect(for: range) else { continue }
            drawBox(rect.offsetBy(dx: origin.x, dy: origin.y), ticked: ticked)
        }
    }

    /// Each to-do's `[ ]` in `range` (all of the text by default), and whether it's ticked.
    func checkboxes(in range: NSRange? = nil) -> [(NSRange, Bool)] {
        guard let storage = textStorage else { return [] }
        var found: [(NSRange, Bool)] = []
        let scope = range ?? NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.markdownCheckbox, in: scope) { value, run, _ in
            if let ticked = value as? NSNumber { found.append((run, ticked.boolValue)) }
        }
        return found
    }

    /// The box over a to-do's `[ ]`, in the text container's coordinates: centred on it, at the height of a capital.
    func boxRect(for range: NSRange) -> NSRect? {
        guard let container = textContainers.first else { return nil }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let bounds = boundingRect(forGlyphRange: glyphs, in: container)
        let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let baseline = line.minY + location(forGlyphAt: glyphs.location).y
        let side = Self.boxSide
        return NSRect(x: bounds.midX - side / 2, y: baseline - 4.6 - side / 2, width: side, height: side)
    }

    private func drawBox(_ rect: NSRect, ticked: Bool) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        if ticked {
            NSColor(StudioColors.coral).setFill()
            box.fill()
            // The text view is flipped: y grows down.
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.52))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.7))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.32))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            NSColor(StudioColors.card).setFill()
            box.fill()
            NSColor(StudioColors.muted).withAlphaComponent(0.7).setStroke()
            box.lineWidth = 1.2
            box.stroke()
        }
    }
}

/// The preview's text view: a click on a box ticks it, and the caret's lines show their marks only while it's in use.
final class MarkdownTextView: NSTextView {
    var preview = false
    /// The lines whose marks show (the caret's), as last styled.
    var revealed: [NSRange] = []

    private var markdownLayout: MarkdownLayoutManager? { layoutManager as? MarkdownLayoutManager }

    override func mouseDown(with event: NSEvent) {
        if preview, let box = checkbox(at: convert(event.locationInWindow, from: nil)) {
            toggle(box)
            return
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, preview { MarkdownLiveStyle.apply(to: self) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // After the window has moved on, so the caret's line counts as not in use.
        if resigned, preview { Task { @MainActor [weak self] in if let self { MarkdownLiveStyle.apply(to: self) } } }
        return resigned
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard preview, let layout = markdownLayout else { return }
        for (range, _) in layout.checkboxes() {
            guard let rect = layout.boxRect(for: range) else { continue }
            addCursorRect(rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).insetBy(dx: -3, dy: -3),
                          cursor: .pointingHand)
        }
    }

    /// The to-do whose box is under `point` (in the view), if any.
    private func checkbox(at point: NSPoint) -> (NSRange, Bool)? {
        guard let layout = markdownLayout else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        return layout.checkboxes().first { range, _ in
            layout.boxRect(for: range)?.insetBy(dx: -3, dy: -3).contains(local) ?? false
        }
    }

    /// `[ ]` ⇄ `[x]`, as an edit (so it undoes and reaches the binding).
    private func toggle(_ box: (NSRange, Bool)) {
        let mark = NSRange(location: box.0.location + 1, length: 1)
        let replacement = box.1 ? " " : "x"
        guard shouldChangeText(in: mark, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: mark, with: replacement)
        didChangeText()
        undoManager?.setActionName(box.1 ? "Untick To-do" : "Tick To-do")
    }
}

/// The note's ☑: turns lines into to-dos and back.
@MainActor
enum MarkdownChecklist {
    private static let task = #/^(\s*)[-*+]\s+\[[ xX]\]\s?/#
    private static let listMark = #/^(\s*)([-*+]|\d+[.)])\s+/#

    static func toggle(in view: NSTextView) {
        let source = view.string as NSString
        guard view.window?.firstResponder === view else {
            // Not in use: a new to-do at the end.
            view.window?.makeFirstResponder(view)
            let end = source.length
            let line = end > 0 && source.character(at: end - 1) != 0x0A ? "\n- [ ] " : "- [ ] "
            replace(NSRange(location: end, length: 0), with: line, in: view)
            view.setSelectedRange(NSRange(location: end + (line as NSString).length, length: 0))
            return
        }
        let range = source.lineRange(for: view.selectedRange())
        let (changed, ending) = toggled(source.substring(with: range))
        replace(range, with: changed.joined(separator: "\n") + ending, in: view)
        let length = (changed.joined(separator: "\n") as NSString).length
        view.setSelectedRange(changed.count == 1 ? NSRange(location: range.location + length, length: 0)
                                                 : NSRange(location: range.location, length: length))
    }

    /// The lines with the ☑ applied: all to-dos become plain lines, otherwise every line becomes a to-do (a list item
    /// keeps its indent; blank lines among several stay blank). `ending` is the line break after the last one.
    static func toggled(_ text: String) -> (lines: [String], ending: String) {
        var lines = text.components(separatedBy: "\n")
        let ending = lines.count > 1 && lines.last == "" ? { lines.removeLast(); return "\n" }() : ""
        let filled = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allTasks = !filled.isEmpty && filled.allSatisfy { $0.firstMatch(of: task) != nil }
        let changed = lines.map { line -> String in
            if allTasks {
                guard let match = line.firstMatch(of: task) else { return line }
                return String(match.1) + line[match.range.upperBound...]
            }
            if line.firstMatch(of: task) != nil || (lines.count > 1 && line.trimmingCharacters(in: .whitespaces).isEmpty) {
                return line
            }
            if let match = line.firstMatch(of: listMark) {
                return String(match.1) + "- [ ] " + line[match.range.upperBound...]
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            return indent + "- [ ] " + line.dropFirst(indent.count)
        }
        return (changed, ending)
    }

    private static func replace(_ range: NSRange, with text: String, in view: NSTextView) {
        guard view.shouldChangeText(in: range, replacementString: text) else { return }
        view.textStorage?.replaceCharacters(in: range, with: text)
        view.didChangeText()
        view.undoManager?.setActionName("To-do")
    }
}

// MARK: - Styling

/// Styles Markdown source in place. Pure attribute work: the characters never change, so the caret, undo and the
/// binding are untouched.
@MainActor
enum MarkdownLiveStyle {
    private static let size: CGFloat = 13

    static func apply(to view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let selection = view.selectedRanges
        let markdownView = view as? MarkdownTextView
        let preview = markdownView?.preview ?? false
        let reveal = preview ? revealed(in: view) : []
        storage.beginEditing()
        style(storage, preview: preview, reveal: reveal)
        storage.endEditing()
        if let markdownView, preview {
            markdownView.revealed = reveal
            // Hidden marks and bullets are glyph changes, which attribute edits alone don't redo.
            let whole = NSRange(location: 0, length: storage.length)
            view.layoutManager?.invalidateGlyphs(forCharacterRange: whole, changeInLength: 0, actualCharacterRange: nil)
            view.layoutManager?.invalidateLayout(forCharacterRange: whole, actualCharacterRange: nil)
            view.needsDisplay = true
            view.window?.invalidateCursorRects(for: view)
            view.invalidateIntrinsicContentSize()
        }
        view.selectedRanges = selection
        view.typingAttributes = [.font: font(size), .foregroundColor: color(StudioColors.body)]
    }

    /// The lines whose marks show: the caret's (or the selection's), while the editor is in use.
    static func revealed(in view: NSTextView) -> [NSRange] {
        guard view.window?.firstResponder === view else { return [] }
        let source = view.string as NSString
        return view.selectedRanges.map { source.lineRange(for: $0.rangeValue) }
    }

    static func style(_ storage: NSTextStorage, preview: Bool = false, reveal: [NSRange] = []) {
        let source = storage.string as NSString
        let whole = NSRange(location: 0, length: source.length)
        let body = color(StudioColors.body), ink = color(StudioColors.ink), muted = color(StudioColors.muted)
        storage.setAttributes([.font: font(size), .foregroundColor: body, .paragraphStyle: paragraph()], range: whole)

        var inFence = false
        source.enumerateSubstrings(in: whole, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let text = source.substring(with: line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                storage.addAttributes([.font: mono(size - 1), .foregroundColor: muted], range: line)
                return
            }
            if inFence {
                storage.addAttributes([.font: mono(size - 1), .foregroundColor: ink,
                                       .backgroundColor: color(StudioColors.field)], range: line)
                return
            }
            let shown = reveal.contains { NSLocationInRange(line.location, $0) || NSIntersectionRange(line, $0).length > 0 }
            styleLine(text, range: line, in: storage, preview: preview, conceal: preview && !shown)
        }
    }

    private static func styleLine(_ text: String, range: NSRange, in storage: NSTextStorage, preview: Bool,
                                  conceal: Bool) {
        let muted = color(StudioColors.muted), ink = color(StudioColors.ink)
        let nsText = text as NSString
        /// A mark: dim, and hidden in the preview off the caret's line.
        func mark(_ local: NSRange) {
            let r = NSRange(location: range.location + local.location, length: local.length)
            storage.addAttribute(.foregroundColor, value: muted, range: r)
            if conceal { storage.addAttribute(.markdownHidden, value: true, range: r) }
        }
        if let heading = text.firstMatch(of: #/^(#{1,6})\s/#) {
            let level = heading.1.count
            let big = size + (level == 1 ? 5 : level == 2 ? 3 : level == 3 ? 1.5 : 0.5)
            storage.addAttributes([.font: font(big, bold: true), .foregroundColor: ink], range: range)
            mark(NSRange(location: 0, length: level + 1))
        } else if let quote = text.firstMatch(of: #/^\s{0,3}>\s?/#) {
            storage.addAttribute(.foregroundColor, value: muted, range: range)
            if preview {
                storage.enumerateAttribute(.font, in: range) { value, run, _ in
                    if let current = value as? NSFont { storage.addAttribute(.font, value: italicized(current), range: run) }
                }
            }
            mark(NSRange(location: 0, length: quote.output.utf16.count))
        } else if text.firstMatch(of: #/^\s{0,3}([-*_])(\s*\1){2,}\s*$/#) != nil {
            storage.addAttribute(.foregroundColor, value: muted, range: range)
        } else if preview, let item = text.firstMatch(of: #/^(\s*)([-*+])(\s+)\[([ xX])\](\s|$)/#) {
            // A to-do: the dash hides, the box is drawn over `[ ]` (set small and fixed so it's the box's width).
            let indent = item.1.utf16.count, dash = item.2.utf16.count + item.3.utf16.count
            mark(NSRange(location: indent, length: dash))
            let box = NSRange(location: range.location + indent + dash, length: 3)
            let ticked = item.4 != " "
            storage.addAttributes([.font: mono(9), .foregroundColor: NSColor.clear,
                                   .markdownCheckbox: NSNumber(value: ticked)], range: box)
            if ticked {
                let start = box.upperBound + item.5.utf16.count // the words, not the space before them
                let rest = NSRange(location: start, length: range.upperBound - start)
                storage.addAttributes([.foregroundColor: muted, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .strikethroughColor: muted], range: rest)
            }
        } else if let item = text.firstMatch(of: #/^(\s*)([-*+]|\d+[.)])(\s+\[[ xX]\])?\s/#) {
            let marks = nsText.range(of: String(item.output.0))
            storage.addAttribute(.foregroundColor, value: color(StudioColors.coralInk),
                                 range: NSRange(location: range.location + marks.location, length: marks.length))
            if conceal, item.3 == nil, ["-", "*", "+"].contains(item.2) {
                storage.addAttribute(.markdownBullet, value: true,
                                     range: NSRange(location: range.location + item.1.utf16.count, length: 1))
            }
        }
        styleInline(nsText, range: range, in: storage, mark: mark)
    }

    /// Code spans, bold, italics, strikethrough and links within one line. Marks are dimmed (`mark`, which also hides
    /// them in the preview); what they wrap is styled.
    private static func styleInline(_ line: NSString, range: NSRange, in storage: NSTextStorage,
                                    mark: (NSRange) -> Void) {
        let muted = color(StudioColors.muted)
        func each(_ pattern: String, _ body: (NSTextCheckingResult) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: line as String, range: NSRange(location: 0, length: line.length)) {
                body(match)
            }
        }
        func shifted(_ r: NSRange) -> NSRange { NSRange(location: range.location + r.location, length: r.length) }
        func ends(_ r: NSRange, _ length: Int) {
            mark(NSRange(location: r.location, length: length))
            mark(NSRange(location: r.location + r.length - length, length: length))
        }

        // Bold (**x** or __x__), then italics (*x* or _x_), over whatever font the line already has.
        each(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#) { match in
            storage.enumerateAttribute(.font, in: shifted(match.range(at: 2))) { value, run, _ in
                if let current = value as? NSFont { storage.addAttribute(.font, value: bolded(current), range: run) }
            }
            ends(match.range, 2)
        }
        each(#"(?<![*\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*\w])"#) { match in
            storage.enumerateAttribute(.font, in: shifted(match.range(at: 2))) { value, run, _ in
                if let current = value as? NSFont {
                    storage.addAttribute(.font, value: italicized(current), range: run)
                }
            }
            ends(match.range, 1)
        }
        // ~~x~~: struck through.
        each(#"~~(?=\S)(.+?)(?<=\S)~~"#) { match in
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: muted],
                                  range: shifted(match.range(at: 1)))
            ends(match.range, 2)
        }
        // `code`: mono on a chip, its ticks dim.
        each(#"`[^`\n]+`"#) { match in
            storage.addAttributes([.font: mono(size - 1.5), .foregroundColor: color(StudioColors.ink),
                                   .backgroundColor: color(StudioColors.chip)], range: shifted(match.range))
            ends(match.range, 1)
        }
        // [text](url): the text coral and a link, the brackets and address dim.
        each(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#) { match in
            let label = match.range(at: 1)
            mark(NSRange(location: match.range.location, length: 1))
            mark(NSRange(location: label.upperBound, length: match.range.upperBound - label.upperBound))
            storage.addAttribute(.foregroundColor, value: color(StudioColors.coralInk), range: shifted(label))
            if let url = URL(string: line.substring(with: match.range(at: 2))) {
                storage.addAttribute(.link, value: url, range: shifted(label))
            }
        }
    }

    // MARK: Faces

    private static func color(_ color: Color) -> NSColor { NSColor(color) }

    private static func paragraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = size * 0.25
        return style
    }

    private static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let base = NSFont(name: "DMSans-9ptRegular", size: size) ?? NSFont.systemFont(ofSize: size)
        return bold ? bolded(base) : base
    }

    private static func mono(_ size: CGFloat) -> NSFont {
        NSFont(name: "JetBrainsMono-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func bolded(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func italicized(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
}
