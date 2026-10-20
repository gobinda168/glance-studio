import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

// Settings' own controls on top of the PR pages' (spec 2026-10-08-settings-design.md, "Look"): a menu, a square icon
// button, a provider's key field, and the plate under a chosen row.

/// A menu on a row (the PR pages' branch menu): the chosen option's words and a chevron; the options, the chosen one
/// checked.
struct SettingsMenu<Value: Hashable>: View {
    let label: String
    let title: String
    let options: [SegmentItem<Value>]
    let selection: Value?
    var width: CGFloat = 240
    let choose: (Value) -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(options) { option in
                Toggle(option.title, isOn: Binding(get: { option.value == selection }, set: { _ in choose(option.value) }))
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.studio(12, .medium))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                StudioIcon(.chevronDown, size: 12).foregroundStyle(StudioColors.muted)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel("\(label): \(title)")
    }
}

/// A square button with a line icon (▶ on a voice, Show on a key), outlined like the secondary button; its words in
/// the tooltip.
struct SettingsIconButton: View {
    let icon: StudioIcons.Name
    let label: String
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            StudioIcon(icon, size: 13)
                .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A provider's key (the old window's key field): the field, hidden unless shown, with the saved key's mask as its
/// placeholder; Save, Test, and Remove once one is saved; and what the last check found.
struct SettingsKeyField: View {
    @Bindable var model: KeyFieldModel
    @FocusState private var focused: Bool

    var body: some View {
        let name = model.provider.displayName
        let placeholder = !model.hasSavedKey ? "Paste your \(name) API key"
            : model.savedKeyMask.map { "Saved \($0). Paste a new key to replace it." }
            ?? "Saved in Keychain. Paste a new key to replace it."
        let typed = !APIKey.normalized(model.keyInput).isEmpty
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if model.revealKey {
                        TextField(placeholder, text: $model.keyInput)
                    } else {
                        SecureField(placeholder, text: $model.keyInput)
                    }
                }
                .textFieldStyle(.plain)
                .font(.studioMono(12.5))
                .foregroundStyle(StudioColors.ink)
                .focused($focused)
                .onSubmit { model.save() }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? StudioColors.coral : StudioColors.line3, lineWidth: 1))
                .accessibilityLabel("\(name) API key")
                SettingsIconButton(icon: model.revealKey ? .eyeOff : .eye, label: model.revealKey ? "Hide key" : "Show key",
                                   size: 32) { model.revealKey.toggle() }
            }
            HStack(spacing: 8) {
                StudioButton(title: "Save", style: .primary, enabled: typed, height: 28) { model.save() }
                StudioButton(title: "Test", enabled: model.hasSavedKey || typed, height: 28) { model.test() }
                if model.hasSavedKey {
                    StudioButton(title: "Remove", style: .quiet, height: 28) { model.remove() }
                }
                Spacer(minLength: 8)
                checkState
            }
        }
    }

    @ViewBuilder private var checkState: some View {
        switch model.check {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                Spinner(size: 13)
                Text("Checking…").font(.studio(12)).foregroundStyle(StudioColors.muted)
            }
        case .done(let result):
            HStack(spacing: 6) {
                StatusLight(on: result == .connected)
                Text(result.message)
                    .font(.studio(12, .medium))
                    .foregroundStyle(result == .connected ? StudioColors.ok : StudioColors.danger)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The plate under a chosen row: the selection's tint with a 2pt coral edge, or the hover tint.
struct SettingsRowPlate: View {
    let selected: Bool
    let hovering: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if selected {
            shape.fill(StudioColors.selection)
                .overlay(alignment: .leading) { Rectangle().fill(StudioColors.coral).frame(width: 2) }
                .clipShape(shape)
        } else {
            shape.fill(hovering ? StudioColors.hover : .clear)
        }
    }
}
