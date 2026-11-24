import AppKit
import GlanceCore
import SwiftUI

/// Markdown as the PR pages and the Glance session view show it (a description, a comment, Claude's read): HTML
/// comments out (`MarkdownComments`), blocks from `Blocks.split`, headings sized by level, task lists as boxes, inline
/// styles from `AttributedString(markdown:)`, fenced code highlighted with a Copy button (`CodeBlockView`), `#N` made
/// links. Every link goes to `open`, which keeps this repository's pull requests and issues in Glance.
struct GlanceMarkdown: View {
    let markdown: String
    var size: CGFloat = 15
    var color: Color = StudioColors.body
    /// Extra space between wrapped lines of paragraphs; `size * 0.6` when nil.
    var lineSpacing: CGFloat?
    /// The same for list items and quotes; follows `lineSpacing` when nil.
    var listLineSpacing: CGFloat?
    /// Claude's replies in the session view: a lead paragraph, a heading rhythm and one reading measure. PR pages keep
    /// the plain style.
    var reading = false
    let open: (URL) -> Void

    /// About 66 characters of DM Sans at the reading size.
    private static let measure: CGFloat = 640

    var body: some View {
        let blocks = Blocks.split(PullRequestLinks.autolink(MarkdownComments.strip(markdown)))
        VStack(alignment: .leading, spacing: reading ? 0 : 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if reading {
                    readingBlock(block, index: index, blocks: blocks)
                } else {
                    view(for: block)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            open(url)
            return .handled
        })
        .textSelection(.enabled)
    }

    /// A block in the reading style: more space above a heading than below it, the first paragraph as a lead when the
    /// reply goes on after it, and text held to the measure (code and tables keep the column).
    @ViewBuilder private func readingBlock(_ block: Block, index: Int, blocks: [Block]) -> some View {
        let top: CGFloat = index == 0 ? 0 : block.kind == .heading ? 26 : blocks[index - 1].kind == .heading ? 8
            : index == 1 && Self.isLead(blocks[0], in: blocks) ? 16 : 12
        Group {
            if index == 0, Self.isLead(block, in: blocks) {
                Text(inline(block.markdown, size: size + 1.5))
                    .font(.studio(size + 1.5, .medium))
                    .foregroundStyle(StudioColors.ink)
                    .lineSpacing(lineSpacing ?? size * 0.6)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                view(for: block)
            }
        }
        .frame(maxWidth: Self.isText(block) ? Self.measure : nil, alignment: .leading)
        .padding(.top, top)
    }

    private static func isLead(_ block: Block, in blocks: [Block]) -> Bool {
        block.kind == .paragraph && blocks.count > 1
    }

    private static func isText(_ block: Block) -> Bool {
        switch block.kind {
        case .heading, .paragraph, .list, .quote: true
        case .code, .mermaid, .table, .rule: false
        }
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block.kind {
        case .heading:
            let level = block.markdown.prefix(while: { $0 == "#" }).count
            let heading = reading ? size + (level == 1 ? 4.5 : level == 2 ? 2.5 : level == 3 ? 1 : 0.5)
                : size + (level == 1 ? 5 : level == 2 ? 3 : level == 3 ? 1.5 : 0.5)
            Text(inline(String(block.markdown.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces), size: heading, boldRuns: false))
                .font(.studio(heading, reading ? .semibold : .bold))
                .foregroundStyle(StudioColors.ink)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph:
            Text(inline(block.markdown))
                .font(.studio(size))
                .foregroundStyle(color)
                .lineSpacing(lineSpacing ?? size * 0.6)
                .fixedSize(horizontal: false, vertical: true)
        case .list:
            VStack(alignment: .leading, spacing: reading ? 7 : 4) {
                ForEach(Array(listItems(block.markdown).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let done = item.done {
                            Image(systemName: done ? "checkmark.square.fill" : "square")
                                .font(.system(size: size - 1))
                                .foregroundStyle(done ? StudioColors.ink : StudioColors.muted)
                                .accessibilityLabel(done ? "Done" : "To do")
                        } else {
                            Text(item.marker).font(.studio(size)).foregroundStyle(StudioColors.muted)
                        }
                        Text(inline(item.text))
                            .font(.studio(size))
                            .foregroundStyle(color)
                            .lineSpacing(listLineSpacing ?? lineSpacing ?? size * 0.6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(StudioColors.line3).frame(width: 3)
                Text(inline(block.markdown.split(separator: "\n")
                    .map { String($0.drop(while: { $0 == ">" || $0 == " " })) }
                    .joined(separator: "\n")))
                    .font(.studio(size))
                    .foregroundStyle(StudioColors.muted)
                    .lineSpacing(listLineSpacing ?? lineSpacing ?? size * 0.6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code:
            CodeBlockView(code: block.markdown, lang: block.lang)
        case .mermaid, .table:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.markdown)
                    .font(.studioMono(12))
                    .foregroundStyle(StudioColors.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
        case .rule:
            Rectangle().fill(StudioColors.line).frame(height: 1)
        }
    }

    private struct Item {
        let depth: Int
        let marker: String
        let text: String
        /// A task's box ("- [x] …"): ticked or not; nil for a plain item.
        var done: Bool?
    }

    /// A list's items with their nesting (two spaces a level), numbers kept, bullets drawn as "•", tasks as boxes; a
    /// line that isn't an item continues the one before.
    private func listItems(_ markdown: String) -> [Item] {
        var items: [Item] = []
        for line in markdown.split(separator: "\n") {
            let indent = line.prefix(while: { $0 == " " }).count
            let rest = line.drop(while: { $0 == " " })
            if let match = rest.firstMatch(of: #/^([-*+]|\d+[.)])\s+(.*)$/#) {
                let bullet = String(match.1)
                let marker = bullet.first?.isNumber == true ? bullet : "•"
                if let task = match.2.firstMatch(of: #/^\[([ xX])\]\s+(.*)$/#) {
                    items.append(Item(depth: indent / 2, marker: marker, text: String(task.2), done: task.1 != " "))
                } else {
                    items.append(Item(depth: indent / 2, marker: marker, text: String(match.2)))
                }
            } else if let last = items.popLast() {
                items.append(Item(depth: last.depth, marker: last.marker,
                                  text: last.text + " " + rest.trimmingCharacters(in: .whitespaces), done: last.done))
            }
        }
        return items
    }

    /// Inline Markdown: bold, italics and links from the text; code spans in JetBrains Mono on a chip; links coral. Bold
    /// runs set the semibold face themselves: SwiftUI's own bold does nothing to a variable font fixed at one weight.
    private func inline(_ text: String, size: CGFloat? = nil, boldRuns: Bool = true) -> AttributedString {
        let size = size ?? self.size
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var string = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        if boldRuns {
            let bold = string.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }.map(\.range)
            for range in bold {
                string[range].font = .studio(size, .semibold)
                if reading { string[range].foregroundColor = StudioColors.ink }
            }
        }
        let code = string.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        for range in code {
            string[range].font = .studioMono(size - 1.5)
            string[range].foregroundColor = StudioColors.ink
            string[range].backgroundColor = StudioColors.chip
        }
        let links = string.runs.filter { $0.link != nil }.map(\.range)
        for range in links {
            string[range].foregroundColor = StudioColors.coralInk
        }
        return string
    }
}

/// A fenced code block: language label, Copy, JetBrains Mono 12.5 with SyntaxHighlight colours, scrolls sideways.
struct CodeBlockView: View {
    let code: String
    let lang: String?
    @State private var copied = false
    /// Bumped on each copy, so an older "Copied" reset can't clear a newer one.
    @State private var copyCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang ?? "code").font(.studioMono(11)).foregroundStyle(StudioColors.muted)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    copyCount += 1
                    let count = copyCount
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copyCount == count { copied = false } }
                } label: {
                    Text(copied ? "Copied" : "Copy").font(.studio(11.5, .medium)).foregroundStyle(StudioColors.body)
                        .frame(minWidth: 44, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted)
                    .font(.studioMono(12.5)).lineSpacing(3).foregroundStyle(StudioColors.ink).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 2)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioColors.chip))
    }

    /// The code coloured a line at a time (the highlighter reads one line on its own, so a stray quote can't colour
    /// the lines after it), joined into one selectable text.
    private var highlighted: AttributedString {
        let language = lang.flatMap { SyntaxHighlight.Language(fence: $0) }
        var result = AttributedString()
        for (index, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += DiffColors.code(String(line), language: language)
        }
        return result
    }
}
