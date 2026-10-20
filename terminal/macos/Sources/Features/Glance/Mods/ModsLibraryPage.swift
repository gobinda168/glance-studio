import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Mods tab with no mod chosen: the library, full width with no side bar (spec
/// 2026-10-14-fullwidth-libraries-design.md). Yours and Built in as cards, each with its switch; a card opens the mod's
/// page, where the side bar comes back.
struct ModsLibraryPage: View {
    @ObservedObject private var store = ModStore.shared
    @State private var window: NSWindow?
    @State private var query = ""
    @State private var filter = LibraryFilter.all

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let shown = store.mods.filter { matches($0) && filter.keeps(store.isOn($0.id)) }
        let on = store.mods.filter { store.isOn($0.id) }.count
        LibraryScroll {
            LibraryHeader(title: "Mods",
                          subtitle: "Add-ons for Claude Code in Glance's terminals. Switching one reaches the terminal tabs you open next.",
                          searchPrompt: "Search mods", query: $query, addTitle: "Add a mod…") {
                if let name = ModsPicker.addMod(in: window) { ModsTabController.open(name, from: window) }
            }
            if let problem = store.problem {
                Text(problem)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.danger)
                    .padding(12)
                    .frame(maxWidth: 720, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.dangerFill))
            }
            VStack(alignment: .leading, spacing: 10) {
                LibraryCaption(title: "Library", count: store.mods.count) {
                    LibraryFilterTabs(filter: $filter, on: on, off: store.mods.count - on)
                }
                if shown.isEmpty {
                    LibraryNoMatch(noun: "mod", query: searching ? query : "", filter: filter)
                } else {
                    group("Yours", shown.filter { !$0.isBuiltIn })
                    group("Built in", shown.filter(\.isBuiltIn))
                }
            }
        }
        .background(WindowAccessor { window = $0 })
    }

    private func matches(_ mod: ModStore.Entry) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return "\(mod.manifest.displayName) \(mod.id) \(mod.manifest.detail)".lowercased().contains(query)
    }

    @ViewBuilder private func group(_ title: String, _ mods: [ModStore.Entry]) -> some View {
        if !mods.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.studio(12, .medium))
                    .foregroundStyle(StudioColors.muted)
                    .accessibilityAddTraits(.isHeader)
                LibraryGrid {
                    ForEach(mods) { mod in card(mod) }
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func card(_ mod: ModStore.Entry) -> some View {
        let settings = mod.manifest.fields.filter { !$0.sensitive }.count
        return LibraryCard(name: mod.manifest.displayName,
                           detail: mod.manifest.detail.isEmpty ? "No description." : mod.manifest.detail,
                           isOn: Binding(get: { store.isOn(mod.id) }, set: { store.setOn(mod.id, $0) }),
                           open: { ModsTabController.open(mod.id, from: window) }) {
            LibraryChip(text: settings == 0 ? "Nothing to set" : settings == 1 ? "1 setting" : "\(settings) settings")
            Spacer(minLength: 4)
            Text(mod.isBuiltIn ? "By Glance" : "By you")
                .font(.studioMono(11))
                .foregroundStyle(StudioColors.muted)
                .lineLimit(1)
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([mod.folder]) }
        }
    }
}
