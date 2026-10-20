import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Terminal (spec 2026-10-08-settings-design.md, "Terminal preferences"): the font, its size, the theme and the
/// cursor, written to the terminal's config file; Open Config File… for everything else.
struct TerminalSettings: View {
    @ObservedObject private var terminal = TerminalSettingsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Font") {
                SettingsRow(id: "terminal.font", name: "Font family",
                            detail: "Monospaced fonts on this Mac. Fallback fonts in the file stay.") {
                    FontPicker(terminal: terminal)
                }
                failure("terminal.font")
                SettingsRow(id: "terminal.size", name: "Font size", detail: "⌘+ and ⌘− change it in one terminal for a while.") {
                    HStack(spacing: 8) {
                        Text("\(TerminalSettingsModel.format(terminal.fontSize)) pt")
                            .font(.studioMono(12.5))
                            .foregroundStyle(StudioColors.ink)
                            .frame(minWidth: 44, alignment: .trailing)
                        Stepper("Font size",
                                value: Binding(get: { terminal.fontSize.rounded() }, set: { terminal.setFontSize($0) }),
                                in: Double(TerminalSettingsModel.sizes.lowerBound)...Double(TerminalSettingsModel.sizes.upperBound),
                                step: 1)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }
                failure("terminal.size")
            }
            SettingsGroup(title: "Colours") {
                SettingsRow(id: "terminal.theme", name: "Theme", detail: themeDetail) {
                    ThemePicker(terminal: terminal)
                }
                failure("terminal.theme")
            }
            SettingsGroup(title: "Cursor") {
                SettingsRow(id: "terminal.cursor", name: "Cursor", detail: "Programs like Vim can change it while they run.") {
                    SegmentedTabs(items: [SegmentItem(value: "block", title: "Block", count: nil),
                                          SegmentItem(value: "bar", title: "Bar", count: nil),
                                          SegmentItem(value: "underline", title: "Underline", count: nil)],
                                  selection: Binding(get: { terminal.cursorStyle }, set: { terminal.setCursorStyle($0) }))
                }
                failure("terminal.cursor")
                SettingsRow(id: "terminal.blink", name: "Blink", detail: "On unless a program turns it off.") {
                    SettingsSwitch(label: "Blink",
                                   isOn: Binding(get: { terminal.cursorBlink }, set: { terminal.setCursorBlink($0) }))
                }
                failure("terminal.blink")
            }
            SettingsGroup(title: "Config file") {
                SettingsRow(id: "terminal.config", name: "Open Config File…",
                            detail: "Every other terminal setting, in \(terminal.path.map(TerminalSettingsModel.short) ?? "the config file"). "
                                + "The rows above write their lines there.") {
                    StudioButton(title: "Open Config File…", height: 26) {
                        (NSApp.delegate as? AppDelegate)?.openConfigFile(nil)
                    }
                }
                failure("terminal.config")
            }
        }
        .onAppear { terminal.load() }
    }

    private var themeDetail: String {
        if let theme = terminal.theme, TerminalConfig.themeLabel(theme) != theme {
            return "Your file picks a light and a dark theme; choosing one here uses it in both."
        }
        return "Applies to every terminal at once."
    }

    @ViewBuilder private func failure(_ row: String) -> some View {
        if let failure = terminal.failure, failure.row == row {
            InlineError(message: failure.message).padding(.vertical, 10)
        }
    }
}

// MARK: - The pickers

/// The font menu: the main font in its own face; a popover with a filter lists the default and every monospaced font.
private struct FontPicker: View {
    @ObservedObject var terminal: TerminalSettingsModel
    @State private var open = false

    var body: some View {
        let family = terminal.fontFamily
        PickerButton(label: "Font family", open: $open) {
            Text(family ?? "\(TerminalSettingsModel.defaultFamily) (default)")
                .font(TerminalFont.font(family, size: 12.5))
                .foregroundStyle(StudioColors.ink)
                .lineLimit(1)
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FilterList(placeholder: "Filter fonts",
                       items: [PickerItem(id: "", title: "\(TerminalSettingsModel.defaultFamily) (default)")]
                           + terminal.families.map { PickerItem(id: $0, title: $0) },
                       selected: family ?? "") { item in
                terminal.setFontFamily(item.id.isEmpty ? nil : item.id)
                open = false
            } row: { item in
                Text(item.title)
                    .font(TerminalFont.font(item.id.isEmpty ? nil : item.id, size: 13))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
            }
        }
    }
}

/// The theme menu: the theme's name and colours; a popover with a filter lists Glance's colours and every theme, each
/// with its swatch strip.
private struct ThemePicker: View {
    @ObservedObject var terminal: TerminalSettingsModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var open = false

    var body: some View {
        let theme = terminal.theme
        PickerButton(label: "Theme", open: $open) {
            HStack(spacing: 8) {
                Swatches(colors: TerminalColors(theme: terminal.shownTheme(dark: colorScheme == .dark), config: nil).palette,
                         count: 8, width: 6)
                Text(theme.map(TerminalConfig.themeLabel) ?? "Glance (default)")
                    .font(.studio(12, .medium))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FilterList(placeholder: "Filter themes",
                       items: [PickerItem(id: "", title: "Glance (default)")]
                           + terminal.themes.map { PickerItem(id: $0.name, title: $0.name, theme: $0) },
                       selected: theme ?? "") { item in
                terminal.setTheme(item.id.isEmpty ? nil : item.id)
                open = false
            } row: { item in
                HStack(spacing: 10) {
                    Text(item.title)
                        .font(.studio(13, .medium))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if item.id.isEmpty || item.theme?.hasColors == true {
                        Swatches(colors: TerminalColors(theme: item.theme, config: nil).palette, count: 16, width: 6)
                    }
                }
            }
        }
    }
}

private struct PickerItem: Identifiable {
    let id: String
    let title: String
    var theme: TerminalTheme?
}

/// A picker's button: the menu look (outlined, a chevron), opening its popover.
private struct PickerButton<Content: View>: View {
    let label: String
    @Binding var open: Bool
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                content
                Spacer(minLength: 4)
                StudioIcon(.chevronDown, size: 12).foregroundStyle(StudioColors.muted)
            }
            .padding(.horizontal, 12)
            .frame(width: 240, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel(label)
    }
}

/// A popover's list with a filter field: Return picks the first match, the chosen item is selected and in view.
private struct FilterList<Row: View>: View {
    let placeholder: String
    let items: [PickerItem]
    let selected: String
    let choose: (PickerItem) -> Void
    @ViewBuilder let row: (PickerItem) -> Row
    @State private var filter = ""
    @FocusState private var focused: Bool

    var body: some View {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StudioIcon(.search, size: 14).foregroundStyle(StudioColors.muted)
                TextField(placeholder, text: $filter)
                    .textFieldStyle(.plain)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.ink)
                    .focused($focused)
                    .onSubmit { if let first = shown.first { choose(first) } }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line).frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(shown) { item in
                            FilterRow(selected: item.id == selected, action: { choose(item) }) { row(item) }
                                .id(item.id)
                        }
                        if shown.isEmpty {
                            Text("Nothing matches “\(query)”.")
                                .font(.studio(12))
                                .foregroundStyle(StudioColors.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                    }
                    .padding(6)
                }
                .onAppear { proxy.scrollTo(selected, anchor: .center) }
            }
        }
        .frame(width: 340, height: 400)
        .background(StudioColors.card)
        .onAppear { focused = true }
    }
}

private struct FilterRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background { SettingsRowPlate(selected: selected, hovering: hovering) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A theme's colours as a strip of small squares.
private struct Swatches: View {
    let colors: [Color]
    let count: Int
    let width: CGFloat

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<min(count, colors.count), id: \.self) { index in
                Rectangle().fill(colors[index]).frame(width: width, height: 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - The preview

/// The Terminal preview (spec "Look"): a drawn sample in the chosen font, size and theme, a prompt, two lines of
/// `git status`, the cursor in its style (blinking every 600 ms when on), and the theme's 16 colours under it.
struct TerminalPreview: View {
    @ObservedObject private var terminal = TerminalSettingsModel.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colors = TerminalColors(theme: terminal.shownTheme(dark: colorScheme == .dark), config: terminal.config)
        let family = terminal.fontFamily
        let size = CGFloat(terminal.fontSize)
        let key = "\(family ?? "")|\(size)|\(terminal.theme ?? "")|\(colorScheme == .dark)"
        PreviewCard {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TerminalSample(colors: colors, font: TerminalFont.font(family, size: size), size: size,
                                   cursor: terminal.cursorStyle, blink: terminal.cursorBlink && !reduceMotion)
                        .id(key)
                        .transition(BlurSwap.transition(reduceMotion: reduceMotion))
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: max(110, size * 6.2 + 20), alignment: .topLeading)
                .background(colors.background)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
                .animation(reduceMotion ? .easeOut(duration: 0.16) : .easeOut(duration: 0.24), value: key)
                Swatches(colors: colors.palette, count: 16, width: 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { terminal.load() }
    }
}

private struct TerminalSample: View {
    let colors: TerminalColors
    let font: Font
    let size: CGFloat
    let cursor: String
    let blink: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.25) {
            prompt(Text("git status").foregroundStyle(colors.foreground))
            Text("  new file:   TerminalConfig.swift").foregroundStyle(colors.palette[2])
            Text("  modified:   SettingsPage.swift").foregroundStyle(colors.palette[1])
            HStack(spacing: 0) {
                prompt(Text(""))
                if blink {
                    TimelineView(.periodic(from: .now, by: 0.6)) { context in
                        let on = Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
                        cursorShape.opacity(on ? 1 : 0)
                    }
                } else {
                    cursorShape
                }
            }
        }
        .font(font)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A terminal showing git status")
    }

    private func prompt(_ command: Text) -> Text {
        Text("~/Code/glance").foregroundStyle(colors.palette[4])
            + Text(" main").foregroundStyle(colors.palette[5])
            + Text(" ❯ ").foregroundStyle(colors.palette[2])
            + command
    }

    /// The cursor in a cell: a block, a 2pt bar at its left, or a 2pt line under it.
    private var cursorShape: some View {
        let width = size * 0.6
        let height = size * 1.2
        return ZStack(alignment: cursor == "underline" ? .bottomLeading : .topLeading) {
            Color.clear
            Rectangle()
                .fill(colors.foreground)
                .frame(width: cursor == "bar" ? 2 : width, height: cursor == "underline" ? 2 : height)
        }
        .frame(width: width, height: height)
    }
}

/// What the terminal draws with: the config file's own colours, else the theme's, else Glance's (the design's ground
/// and white, and the terminal's own 16).
struct TerminalColors {
    let background: Color
    let foreground: Color
    let palette: [Color]

    init(theme: TerminalTheme?, config: TerminalConfig?) {
        let own = config.map { TerminalTheme(name: "config", text: $0.text) }
        background = Self.color(own?.background ?? theme?.background ?? "#161513")
        foreground = Self.color(own?.foreground ?? theme?.foreground ?? "#ffffff")
        palette = (0..<16).map { index in
            Self.color(own?.palette[index] ?? theme?.palette[index] ?? TerminalTheme.defaultPalette[index])
        }
    }

    private static func color(_ hex: String) -> Color {
        guard let rgb = TerminalTheme.rgb(hex) else { return .gray }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// A terminal font family as SwiftUI draws it: the family's regular face, or JetBrains Mono (the default, which
/// Glance registers for itself) when it's the default or isn't installed.
enum TerminalFont {
    @MainActor
    static func font(_ family: String?, size: CGFloat) -> Font {
        if let family, let face = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return Font(face as CTFont)
        }
        return .studioMono(size)
    }
}
