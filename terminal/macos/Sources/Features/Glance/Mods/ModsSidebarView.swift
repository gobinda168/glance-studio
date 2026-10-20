import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Mods side bar, beside a mod's page: All mods (the way back to the full-width library), then the mods that came
/// with Glance and the ones added, each with whether it's on. A row opens the window's tab on that mod; + adds one.
struct ModsSidebarView: View {
    @ObservedObject private var store = ModStore.shared
    @ObservedObject private var navigation = ModsNavigation.shared
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(title: "Mods") {
                SidebarIconButton(icon: .plus, label: "Add a mod") {
                    if let name = ModsPicker.addMod(in: window) { ModsTabController.open(name, from: window) }
                }
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    LibrarySidebarRow(title: "All mods") { ModsTabController.open(library: true, from: window) }
                    section("Yours", store.userMods, empty: "None yet. Add one with +.")
                    section("Built in", store.builtInMods, empty: nil)
                }
                .padding(.horizontal, 6)
            }
            Text("Mods change how Claude Code looks and behaves in Glance's terminals. Switching one reaches terminal tabs you open next.")
                .font(.studio(11.5))
                .foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { window = $0 })
    }

    @ViewBuilder
    private func section(_ title: String, _ mods: [ModStore.Entry], empty: String?) -> some View {
        if !mods.isEmpty || empty != nil {
            Text(title.uppercased())
                .font(.studio(10.5, .semibold))
                .tracking(0.6)
                .foregroundStyle(StudioColors.muted)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
        ForEach(mods) { mod in
            let on = store.isOn(mod.id)
            JournalSidebarRow(icon: nil, title: mod.manifest.displayName, detail: on ? "On" : "Off",
                              dot: on ? StudioColors.ok : StudioColors.muted.opacity(0.5),
                              selected: navigation.selected == mod.id) {
                ModsTabController.open(mod.id, from: window)
            }
        }
        if mods.isEmpty, let empty {
            Text(empty)
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }
}

/// The open panel behind "Add a mod".
@MainActor
enum ModsPicker {
    /// Asks for a mod's folder and adds it to the library; its name, or nil when cancelled or refused (the page shows why).
    static func addMod(in window: NSWindow?) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Add a Claude Code mod"
        panel.message = "Choose the mod's folder: the one that holds .claude-plugin/plugin.json."
        panel.prompt = "Add Mod"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        let name = ModStore.shared.add(from: folder)
        if name == nil { ModsNavigation.shared.show(nil) }
        return name
    }

    /// Asks for a folder or a file for a mod setting; nil when cancelled.
    static func choose(directory: Bool, current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath).deletingLastPathComponent() }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
