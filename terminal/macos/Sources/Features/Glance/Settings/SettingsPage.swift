import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Settings page (spec 2026-10-08-settings-design.md, "Look"): the section's title and line, then its rows. Terminal,
/// Voice and Dictation show a live preview beside the rows (above them below 880pt). A section change blur-swaps the
/// page; a search hit scrolls to its row and flashes it once.
struct SettingsPage: View {
    @ObservedObject private var navigation = SettingsNavigation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The row flashing for a search hit.
    @State private var flash: String?
    /// The last search hit this page has scrolled to.
    @State private var handled = 0

    static let wideWidth: CGFloat = 880

    var body: some View {
        let section = navigation.section
        GeometryReader { geometry in
            let wide = geometry.size.width >= Self.wideWidth
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        // A ZStack, so the old page and the new one swap in place rather than stacking for a moment.
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 0) {
                                header(section)
                                if section.hasPreview && !wide {
                                    SettingsPreview(section: section)
                                        .frame(height: 200)
                                        .padding(.bottom, 24)
                                }
                                SettingsSectionBody(section: section)
                                    .frame(maxWidth: section.hasPreview ? 540 : 720, alignment: .leading)
                            }
                            .padding(.horizontal, 32)
                            .padding(.top, 24)
                            .padding(.bottom, 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(section)
                            .transition(BlurSwap.transition(reduceMotion: reduceMotion))
                        }
                    }
                    .onChange(of: navigation.focus) { _, focus in jump(to: focus, proxy: proxy) }
                    .onAppear { jump(to: navigation.focus, proxy: proxy) }
                }
                if section.hasPreview && wide {
                    ZStack(alignment: .top) {
                        SettingsPreview(section: section)
                            .id(section)
                            .transition(BlurSwap.transition(reduceMotion: reduceMotion))
                    }
                    .frame(width: 340)
                    .padding(.top, 24)
                    .padding(.trailing, 32)
                    .transition(BlurSwap.transition(reduceMotion: reduceMotion))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.16) : .easeOut(duration: 0.24), value: section)
        }
        .environment(\.settingsFlash, flash)
    }

    private func header(_ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.studio(22, .bold))
                .tracking(-0.22)
                .foregroundStyle(StudioColors.ink)
                .accessibilityAddTraits(.isHeader)
            Text(section.line)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.muted)
        }
        .padding(.bottom, 24)
    }

    /// Scrolls to a search hit's row once, then flashes it: the selection colour, fading over 600 ms.
    private func jump(to focus: SettingsNavigation.Focus?, proxy: ScrollViewProxy) {
        guard let focus, focus.serial > handled else { return }
        handled = focus.serial
        // The section's rows are laid out a moment after a section change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { proxy.scrollTo(focus.row, anchor: .center) }
            navigation.focusHandled(focus)
            flash = focus.row
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.easeOut(duration: 0.6)) { flash = nil }
            }
        }
    }
}

/// The section's rows.
private struct SettingsSectionBody: View {
    let section: SettingsSection

    var body: some View {
        if let model = GlanceTerminalHost.shared.settings {
            VStack(alignment: .leading, spacing: 0) {
                switch section {
                case .account: AccountSettings()
                case .connectors: ConnectorsSettings()
                case .general: GeneralSettings(model: model)
                case .terminal: TerminalSettings()
                case .suggestions: SuggestionsSettings(model: model)
                case .voice: VoiceSettings(model: model)
                case .dictation: DictationSettings(model: model)
                case .editor: EditorSettings(model: model)
                case .overlay: OverlaySettings(model: model)
                case .meetings: MeetingsSettings()
                case .browser: BrowserSettings()
                case .notifications: NotificationsSettings()
                case .orbChannel: OrbChannelSettings()
                case .secrets: SecretsSettings()
                case .tickets: TicketsSettings()
                case .journal: JournalSettings()
                }
            }
        }
    }
}

/// The live preview beside a section's rows.
private struct SettingsPreview: View {
    let section: SettingsSection

    var body: some View {
        if let model = GlanceTerminalHost.shared.settings {
            switch section {
            case .terminal: TerminalPreview()
            case .voice: VoicePreview(model: model)
            case .dictation: DictationPreview(model: model)
            case .account, .connectors, .general, .suggestions, .editor, .overlay, .meetings, .browser, .notifications, .orbChannel,
                 .secrets, .tickets, .journal:
                EmptyView()
            }
        }
    }
}

// MARK: - The row kit

/// A preview's card: the `card` fill, a 1pt `line`, 12pt corners, captioned "Preview".
struct PreviewCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption("Preview")
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Rows under a small-caps caption, on hairlines.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Caption(title)
                    .padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .overlay(alignment: .top) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
        }
        .padding(.bottom, 28)
    }
}

/// A setting: its name and why on the left, its control on the shared right edge, a hairline under it. `stacked` puts
/// the control under the words at full width (lists, key fields, wide pickers). A search hit flashes it.
struct SettingsRow<Control: View>: View {
    let id: String
    let name: String
    var detail: String?
    var dimmed = false
    var stacked = false
    /// A state's light before the name (a permission): green when on, red when off.
    var light: Bool?
    @ViewBuilder let control: Control
    @Environment(\.settingsFlash) private var flash

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 10) {
                    words
                    control
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    words
                    control.fixedSize()
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(StudioColors.selection)
            .padding(.horizontal, -8)
            .opacity(flash == id ? 1 : 0))
        .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
        .opacity(dimmed ? 0.5 : 1)
        .id(id)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if let light { StatusLight(on: light) }
                Text(name)
                    .font(.studio(13, .medium))
                    .foregroundStyle(StudioColors.ink)
            }
            if let detail {
                Text(detail)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The house switch: macOS's own, small, coral when on.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(StudioColors.coral)
            .disabled(!enabled)
            .accessibilityLabel(label)
    }
}

/// A state's lit sphere (DESIGN.md's status lights): 7pt, green when on, red when off, with a highlight and no halo.
struct StatusLight: View {
    let on: Bool

    var body: some View {
        Circle()
            .fill(on ? StudioColors.ok : StudioColors.danger)
            .overlay(alignment: .topLeading) {
                Circle().fill(.white.opacity(0.4)).frame(width: 2.5, height: 2.5).offset(x: 1.4, y: 1.2)
            }
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// A note above a page's rows (MASTER's banner): the `note` fill, its words, and one button.
struct SettingsNote: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.noteInk)
            Spacer(minLength: 8)
            StudioButton(title: action, height: 26, action: perform)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.note))
        .padding(.bottom, 20)
    }
}

/// The house change-in-place (MASTER §6): a 5pt rise through a 3pt blur; a plain fade under Reduce Motion.
struct BlurSwap: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 3 * amount)
            .offset(y: 5 * amount)
            .opacity(1 - amount)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: BlurSwap(amount: 1), identity: BlurSwap(amount: 0))
    }
}

private struct SettingsFlashKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The row a search hit is flashing.
    var settingsFlash: String? {
        get { self[SettingsFlashKey.self] }
        set { self[SettingsFlashKey.self] = newValue }
    }
}
