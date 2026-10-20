import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Mods page: one mod with its on/off switch, where it lives, and a form for its settings; with none chosen, the
/// library (`ModsLibraryPage`). The form is drawn from
/// the `userConfig` in the mod's plugin.json, so a mod that declares new settings gets new fields with no Glance code.
struct ModsPage: View {
    @ObservedObject private var store = ModStore.shared
    @ObservedObject private var navigation = ModsNavigation.shared
    @State private var window: NSWindow?
    @State private var confirmingRemove = false

    var body: some View {
        Group {
            if let mod = store.entry(named: navigation.selected) {
                page(mod).id(mod.id)
            } else if !store.mods.isEmpty {
                ModsLibraryPage()
            } else {
                empty
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.problem)
        .background(WindowAccessor { window = $0 })
        .onAppear { store.reload() }
    }

    // MARK: A mod

    private func page(_ mod: ModStore.Entry) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                JournalPageHeader(title: mod.manifest.displayName,
                                  subtitle: mod.manifest.detail.isEmpty ? "No description." : mod.manifest.detail) {
                    Toggle("", isOn: Binding(get: { store.isOn(mod.id) }, set: { store.setOn(mod.id, $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(StudioColors.coral)
                        .accessibilityLabel("\(mod.manifest.displayName) is \(store.isOn(mod.id) ? "on" : "off")")
                }
                if let problem = store.problem {
                    Text(problem)
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.danger)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.dangerFill))
                        .transition(.opacity)
                }
                Text(store.isOn(mod.id)
                    ? "On for the terminal tabs you open from now on. Tabs already open keep what they started with."
                    : "Off. Terminal tabs you open from now on won't load it; tabs already open keep it until they close.")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                settings(mod)
                about(mod)
                if !mod.isBuiltIn {
                    HStack {
                        GlanceButton("Remove mod…", style: .secondary) { confirmingRemove = true }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Remove \(mod.manifest.displayName)?", isPresented: $confirmingRemove) {
            Button("Move to Trash", role: .destructive) {
                store.remove(mod.id)
                ModsNavigation.shared.show(nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its folder goes to the Trash. Terminal tabs already open keep it until they close.")
        }
    }

    private func settings(_ mod: ModStore.Entry) -> some View {
        let fields = mod.manifest.fields.filter { !$0.sensitive }
        return card(title: "Settings") {
            if fields.isEmpty {
                Text(mod.manifest.fields.isEmpty
                    ? "This mod has nothing to set."
                    : "Its settings are secrets. Set them in Claude Code with /plugin.")
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
                    .padding(.vertical, 12)
            } else {
                ForEach(fields) { field in
                    ModFieldRow(mod: mod.id, field: field)
                    if field.id != fields.last?.id { Divider().overlay(StudioColors.line) }
                }
            }
        }
    }

    private func about(_ mod: ModStore.Entry) -> some View {
        card(title: "About") {
            aboutRow("Made by", mod.isBuiltIn ? "Glance" : "You")
            Divider().overlay(StudioColors.line)
            if let version = mod.manifest.version {
                aboutRow("Version", version)
                Divider().overlay(StudioColors.line)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Folder").font(.studio(12.5)).foregroundStyle(StudioColors.muted).frame(width: 80, alignment: .leading)
                Text((mod.folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.studioMono(11.5))
                    .foregroundStyle(StudioColors.body)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([mod.folder]) }
                    .buttonStyle(.link)
                    .font(.studio(12))
                    .accessibilityLabel("Show \(mod.manifest.displayName) in Finder")
            }
            .padding(.vertical, 10)
        }
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.studio(12.5)).foregroundStyle(StudioColors.muted).frame(width: 80, alignment: .leading)
            Text(value).font(.studio(12.5)).foregroundStyle(StudioColors.ink)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.studio(11, .semibold))
                .tracking(0.66)
                .foregroundStyle(StudioColors.muted)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line))
        }
    }

    // MARK: No mods

    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            JournalPageHeader(title: "Mods", subtitle: "Add-ons for Claude Code in Glance's terminals.")
            Text("A mod is a Claude Code plugin folder. Add one and it shows up here with a switch, and any settings its plugin.json declares under userConfig get a form.")
                .font(.studio(13))
                .foregroundStyle(StudioColors.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                GlanceButton("Add a mod…", style: .primary) {
                    if let name = ModsPicker.addMod(in: window) { ModsNavigation.shared.show(name) }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One setting: its title and description on the left, the control that fits its type on the right.
private struct ModFieldRow: View {
    let mod: String
    let field: ModManifest.Field
    @ObservedObject private var store = ModStore.shared
    @State private var draft = ""
    @State private var refused = false
    @FocusState private var focused: Bool

    private var stored: Bool { store.values[mod]?[field.key] != nil }
    private var current: ModValue? { store.value(of: field, in: mod) }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.title)
                    .font(.studio(13, .medium))
                    .foregroundStyle(StudioColors.ink)
                if !field.detail.isEmpty {
                    Text(field.detail)
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if refused {
                    Text(refusal).font(.studio(11.5)).foregroundStyle(StudioColors.danger)
                } else if stored {
                    Button("Reset to default") { store.set(field, in: mod, to: nil); draft = current?.text ?? "" }
                        .buttonStyle(.link)
                        .font(.studio(11.5))
                } else if field.required && current == nil {
                    Text("Needs a value.").font(.studio(11.5)).foregroundStyle(StudioColors.amber)
                }
            }
            Spacer(minLength: 8)
            control.frame(maxWidth: 260, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .onAppear { draft = current?.text ?? "" }
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .boolean:
            Toggle("", isOn: Binding(get: { current == .bool(true) }, set: { store.set(field, in: mod, to: .bool($0)) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(StudioColors.coral)
                .accessibilityLabel(field.title)
        case .string where !field.options.isEmpty:
            Picker("", selection: Binding(get: { current?.text ?? "" }, set: { store.set(field, in: mod, to: .string($0)) })) {
                if current == nil { Text("Not set").tag("") }
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(field.title)
        case .directory, .file:
            HStack(spacing: 6) {
                textField
                Button("Choose…") {
                    if let path = ModsPicker.choose(directory: field.kind == .directory, current: draft) {
                        draft = path
                        commit()
                    }
                }
                .accessibilityLabel("Choose \(field.title)")
            }
        case .string, .number:
            textField
        }
    }

    private var textField: some View {
        TextField(field.defaultValue?.text ?? "", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.studio(12.5))
            .multilineTextAlignment(field.kind == .number ? .trailing : .leading)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { isFocused in
                if !isFocused { commit() }
            }
            .accessibilityLabel(field.title)
    }

    private var refusal: String {
        guard field.kind == .number else { return "That isn't a valid value." }
        switch (field.minimum, field.maximum) {
        case let (low?, high?): return "Use a number from \(ModValue.number(low).text) to \(ModValue.number(high).text)."
        case let (low?, nil): return "Use a number of \(ModValue.number(low).text) or more."
        case let (nil, high?): return "Use a number of \(ModValue.number(high).text) or less."
        default: return "Use a number."
        }
    }

    /// Saves the draft: an empty one clears the setting, a value the field refuses is flagged and kept for fixing.
    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            refused = false
            if stored { store.set(field, in: mod, to: nil) }
            return
        }
        guard let value = field.value(from: text) else { refused = true; return }
        refused = false
        if value != current || !stored { store.set(field, in: mod, to: value) }
    }
}
