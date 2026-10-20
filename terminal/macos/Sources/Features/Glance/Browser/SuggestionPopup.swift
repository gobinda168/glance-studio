import AppKit
import GlanceCore
import SwiftUI

/// The address field's suggestions: a borderless panel under the field that never takes the caret, so typing stays
/// in the field, and that floats over the page's web view.
@MainActor
final class SuggestionPopup {
    private var panel: NSPanel?
    private var host: NSHostingView<SuggestionList>?

    /// Shows `rows` under `anchor` (in `window`'s content view, top-left origin, from SwiftUI's `.global` frame).
    func show(_ rows: [AddressSuggestion], highlighted: Int?, below anchor: CGRect, in window: NSWindow,
              choose: @escaping (AddressSuggestion) -> Void) {
        guard !rows.isEmpty, let content = window.contentView else { return hide() }
        let list = SuggestionList(rows: rows, highlighted: highlighted, choose: choose)
        let panel = self.panel ?? makePanel()
        let host: NSHostingView<SuggestionList>
        if let existing = self.host {
            existing.rootView = list
            host = existing
        } else {
            host = NSHostingView(rootView: list)
            panel.contentView = host
            self.host = host
        }
        let height = host.fittingSize.height
        let inWindow = NSRect(x: anchor.minX, y: content.bounds.height - anchor.maxY, width: anchor.width,
                              height: anchor.height)
        let onScreen = window.convertToScreen(content.convert(inWindow, to: nil))
        panel.setFrame(NSRect(x: onScreen.minX, y: onScreen.minY - height - 4, width: onScreen.width, height: height),
                       display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        return panel
    }
}

/// The rows: what Return does first, then apps, tabs and history; the highlighted one tinted.
struct SuggestionList: View {
    let rows: [AddressSuggestion]
    let highlighted: Int?
    let choose: (AddressSuggestion) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                SuggestionRow(row: row, isHighlighted: index == highlighted) { choose(row) }
            }
        }
        .padding(6)
        .background(shape.fill(StudioColors.solid))
        .overlay(shape.strokeBorder(StudioColors.line, lineWidth: 1))
        .clipShape(shape)
    }
}

private struct SuggestionRow: View {
    let row: AddressSuggestion
    let isHighlighted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.frame(width: 18, height: 18)
                Text(row.title)
                    .font(.studio(13, .medium))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.detail)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? StudioColors.selection : hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .search: StudioIcon(.search, size: 14).foregroundStyle(StudioColors.muted)
        case .address: StudioIcon(.globe, size: 14).foregroundStyle(StudioColors.muted)
        case .history: StudioIcon(.clock, size: 14).foregroundStyle(StudioColors.muted)
        case .app, .tab: SiteIcon(url: row.url, size: 18)
        }
    }
}
