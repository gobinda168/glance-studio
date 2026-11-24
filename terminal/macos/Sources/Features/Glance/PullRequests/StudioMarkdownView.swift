import SwiftUI

/// Markdown as the PR pages show it (a description, a comment, Claude's read): `GlanceMarkdown` at 13.5 pt with the
/// PR pages' tighter line spacing, and list items and quotes left unspaced.
struct StudioMarkdownView: View {
    let markdown: String
    var size: CGFloat = 13.5
    var color: Color = StudioColors.body
    let open: (URL) -> Void

    var body: some View {
        GlanceMarkdown(markdown: markdown, size: size, color: color, lineSpacing: size * 0.25, listLineSpacing: 0,
                       open: open)
    }
}
