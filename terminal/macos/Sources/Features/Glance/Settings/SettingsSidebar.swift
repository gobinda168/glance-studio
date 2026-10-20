import AppKit
import GlanceCore
import SwiftUI

/// The Settings side bar (spec 2026-10-08-settings-design.md, "Where Settings lives" and "Search"): the search field,
/// then the sections with the one shown selected; while the field has text, the matching settings instead. Picking
/// either opens the window's Settings tab on it.
struct SettingsSidebarView: View {
    @ObservedObject private var navigation = SettingsNavigation.shared
    @ObservedObject private var features = StudioFeatures.shared
    @State private var window: NSWindow?
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let results = SettingsCatalog.search(text).filter { $0.section.isShown(enabled: features.enabled) }
        let query = text.trimmingCharacters(in: .whitespaces)
        VStack(spacing: 0) {
            SidebarHeader(title: "Settings")
            field(results)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    if query.isEmpty {
                        ForEach(SettingsSection.allCases.filter { $0.isShown(enabled: features.enabled) }, id: \.self) {
                            section in
                            SectionRow(section: section, selected: section == navigation.section) {
                                SettingsTabController.open(section: section, from: window)
                            }
                        }
                    } else if results.isEmpty {
                        Text("No setting matches “\(query)”.")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            ResultRow(entry: entry, highlighted: index == highlighted) { open(entry) }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { window = $0 })
        .onChange(of: text) { highlighted = 0 }
    }

    /// "Search settings": ↓ and ↑ move through the results, Return opens one, Esc clears.
    private func field(_ results: [SettingsCatalog.Entry]) -> some View {
        HStack(spacing: 8) {
            StudioIcon(.search, size: 14)
                .foregroundStyle(StudioColors.muted)
            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .font(.studio(12))
                .foregroundStyle(StudioColors.ink)
                .focused($fieldFocused)
                .onSubmit { if results.indices.contains(highlighted) { open(results[highlighted]) } }
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, max(results.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .onExitCommand { text = "" }
                .accessibilityLabel("Search settings")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(fieldFocused ? StudioColors.coral : StudioColors.line, lineWidth: 1))
    }

    private func open(_ entry: SettingsCatalog.Entry) {
        SettingsTabController.open(section: entry.section, focus: entry.id, from: window)
    }
}

/// A section: its icon and name; the one shown has the selection's tint and the 2pt coral edge.
private struct SectionRow: View {
    let section: SettingsSection
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                StudioIcon(section.icon, size: 16)
                    .foregroundStyle(selected || hovering ? StudioColors.ink : StudioColors.muted)
                Text(section.title)
                    .font(.studio(13, selected ? .semibold : .medium))
                    .foregroundStyle(StudioColors.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background { SettingsRowPlate(selected: selected, hovering: hovering) }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A search result: the setting's name, and its section under it.
private struct ResultRow: View {
    let entry: SettingsCatalog.Entry
    let highlighted: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                StudioIcon(entry.section.icon, size: 14)
                    .foregroundStyle(StudioColors.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.studio(13, .medium))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                    Text(entry.section.title)
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background { SettingsRowPlate(selected: highlighted, hovering: hovering) }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(entry.name), \(entry.section.title)")
    }
}
