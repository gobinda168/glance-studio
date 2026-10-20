import AppKit
import GlanceCore
import SwiftUI

/// The colours of the activity strip and its side bars: the tokens of the "Glance Studio — PR Management" design (its
/// `.gs` rules), flat and opaque where the rest of the chrome is glass. Light and dark follow macOS. See the main
/// repository's docs/superpowers/specs/2026-10-07-activity-strip-design.md, "Colours".
enum StudioColors {
    /// The window behind content (`--bg`).
    static let background = adaptive(light: 0xFAF7F0, dark: 0x161513)
    /// The strip and the side bars (`--bar`).
    static let bar = adaptive(light: 0xF3EFE6, dark: 0x1C1B19)
    static let card = adaptive(light: 0xFFFDF9, dark: 0x211F1D)
    static let hover = adaptive(light: 0x1C1A17, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.07)
    /// The selected icon or row (`--sel`).
    static let selection = adaptive(light: 0xE8643C, dark: 0xE8643C, lightAlpha: 0.14, darkAlpha: 0.2)
    static let line = adaptive(light: 0x1C1A17, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.09)
    /// Fields and key hints (`--seg`).
    static let field = adaptive(light: 0x1C1A17, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.07)
    static let chip = adaptive(light: 0xECE6D8, dark: 0xFFFFFF, lightAlpha: 0.85, darkAlpha: 0.08)

    static let ink = adaptive(light: 0x1C1A17, dark: 0xF1EDE4)
    static let body = adaptive(light: 0x4A453D, dark: 0xC5BFB3)
    static let muted = adaptive(light: 0x6B655C, dark: 0x9A948A)

    static let coral = adaptive(light: 0xE8643C, dark: 0xE8643C)
    /// The primary button under the pointer (`.btn.primary:hover`).
    static let coralHover = adaptive(light: 0xF07A54, dark: 0xF07A54)
    /// Coral as text.
    static let coralInk = adaptive(light: 0xC4471F, dark: 0xFF9B7A)
    /// Text on a coral fill.
    static let onCoral = adaptive(light: 0x1C1A17, dark: 0x1C1A17)

    static let ok = adaptive(light: 0x1A7F37, dark: 0x56C26A)
    static let okFill = adaptive(light: 0x2EA043, dark: 0x2EA043, lightAlpha: 0.14, darkAlpha: 0.16)
    static let danger = adaptive(light: 0xC62A22, dark: 0xFF7B72)
    static let dangerFill = adaptive(light: 0xF85149, dark: 0xF85149, lightAlpha: 0.13, darkAlpha: 0.16)
    /// `okline`: under an added diff line.
    static let okLine = adaptive(light: 0x2EA043, dark: 0x2EA043, lightAlpha: 0.09, darkAlpha: 0.1)
    /// `delline`: under a removed diff line.
    static let dangerLine = adaptive(light: 0xF85149, dark: 0xF85149, lightAlpha: 0.08, darkAlpha: 0.1)
    static let amber = adaptive(light: 0x8A5A00, dark: 0xE3B45A)
    /// A raised face: the selected segment, the glow pill (`--solid`).
    static let solid = adaptive(light: 0xFFFAF6, dark: 0x2A2724)
    /// Hairlines inside cards (`--line2`), and around fields and outlined buttons (`--line3`).
    static let line2 = adaptive(light: 0x1C1A17, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.06)
    static let line3 = adaptive(light: 0x1C1A17, dark: 0xFFFFFF, lightAlpha: 0.18, darkAlpha: 0.15)
    /// A card's lit top edge (`--rim`).
    static let rim = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.7, darkAlpha: 0.12)
    /// Claude's note (`--note`) and its words (`--notefg`).
    static let note = adaptive(light: 0xFBE9DF, dark: 0x402416, lightAlpha: 0.9, darkAlpha: 0.7)
    static let noteInk = adaptive(light: 0x6B2C14, dark: 0xF3D4C4)
    /// Claude at work (`--teal-ink`, `--tealfill`).
    static let tealInk = adaptive(light: 0x1D6B6F, dark: 0x8FD9DC)
    static let tealFill = adaptive(light: 0x2A8F94, dark: 0x2A8F94, lightAlpha: 0.13, darkAlpha: 0.18)
    /// An amber pill's fill (Pending, Waiting on you).
    static let amberFill = adaptive(light: 0xE3B45A, dark: 0xE3B45A, lightAlpha: 0.18, darkAlpha: 0.18)
    /// Code in the PR diffs (`SyntaxHighlight`): warm keywords, teal strings, amber numbers and constants, violet
    /// types, blue calls and keys. Comments are `muted`.
    static let syntaxKeyword = adaptive(light: 0xB8401C, dark: 0xFF8F6B)
    static let syntaxString = adaptive(light: 0x1D6B6F, dark: 0x8FD9DC)
    static let syntaxNumber = adaptive(light: 0x8A5A00, dark: 0xE3B45A)
    static let syntaxType = adaptive(light: 0x7341A8, dark: 0xC9A8F5)
    static let syntaxFunction = adaptive(light: 0x2457A0, dark: 0x8CBBF2)

    private static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// The side bars' header: the mode's name in small caps on the left, its buttons on the right (the canvas's
/// "PULL REQUESTS" row).
struct SidebarHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 2) {
            Text(title.uppercased())
                .font(.studio(11, .semibold))
                .tracking(0.66)
                .foregroundStyle(StudioColors.muted)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            actions
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 36)
    }
}

extension SidebarHeader where Actions == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A side bar header's icon button (+, refresh): the canvas's `.ib`, a 16 pt line icon in a 28 pt square that lights
/// under the pointer.
struct SidebarIconButton: View {
    let icon: StudioIcons.Name
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            StudioIcon(icon, size: 16)
                .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The side bars' footer action: the canvas's coral `.btn.primary` across the bottom over a hairline, its key on a
/// dark-on-coral `.kbd`.
struct SidebarPrimaryButton: View {
    let icon: StudioIcons.Name
    let title: String
    var hint: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                StudioIcon(icon, size: 16)
                Text(title)
                    .font(.studio(12, .semibold))
                Spacer(minLength: 4)
                if let hint {
                    Text(hint)
                        .font(.studioMono(10.5, .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(StudioColors.onCoral.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(StudioColors.onCoral.opacity(0.2), lineWidth: 1))
                }
            }
            .foregroundStyle(StudioColors.onCoral)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? StudioColors.coralHover : StudioColors.coral))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line).frame(height: 1) }
    }
}
