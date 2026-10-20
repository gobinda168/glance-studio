import GlanceCore
import SwiftUI

/// Markdown as the PR pages show it (a description, a comment, Claude's read): HTML comments out
/// (`MarkdownComments`), blocks from `Blocks.split`, headings sized by level, task lists as boxes, inline styles from
/// `AttributedString(markdown:)`, code in JetBrains Mono, `#N` made links. Every link goes to `open`, which keeps this
/// repository's pull requests and issues in Glance.
struct StudioMarkdownView: View {
    let markdown: String
    var size: CGFloat = 13.5
    var color: Color = StudioColors.body
    let open: (URL) -> Void

    var body: some View {
        let blocks = Blocks.split(PullRequestLinks.autolink(MarkdownComments.strip(markdown)))
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            open(url)
            return .handled
        })
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block.kind {
        case .heading:
            let level = block.markdown.prefix(while: { $0 == "#" }).count
            Text(inline(String(block.markdown.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                .font(.studio(size + (level == 1 ? 5 : level == 2 ? 3 : level == 3 ? 1.5 : 0.5), .bold))
                .foregroundStyle(StudioColors.ink)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph:
            Text(inline(block.markdown))
                .font(.studio(size))
                .foregroundStyle(color)
                .lineSpacing(size * 0.25)
                .fixedSize(horizontal: false, vertical: true)
        case .list:
            VStack(alignment: .leading, spacing: 4) {
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code, .mermaid, .table:
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

    /// Inline Markdown: bold, italics and links from the text; code spans in JetBrains Mono on a chip; links coral.
    private func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var string = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
