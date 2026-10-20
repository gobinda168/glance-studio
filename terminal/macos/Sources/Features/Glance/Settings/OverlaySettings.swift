import GlanceCore
import GlanceKit
import SwiftUI

/// Overlay (spec 2026-10-08-settings-design.md, "Sections"): Glance over other terminals and over code editors. With
/// the overlay off in General, both show dimmed under a note that leads there. The words are the old Settings window's.
struct OverlaySettings: View {
    let model: SettingsModel

    var body: some View {
        let on = model.surfaces.overlay
        if !on {
            SettingsNote(text: "Turn on Overlay on other terminals in General.", action: "General") {
                SettingsNavigation.shared.show(.general, focus: "general.overlay")
            }
        }
        SettingsGroup(title: "Terminals") {
            SettingsRow(id: "overlay.terminals", name: "Show Glance over terminals", detail: model.terminalsAlwaysShown
                ? "The panel stays docked over Warp, iTerm and other terminals while one is in front. Close it to hide it "
                    + "until Claude's next reply."
                : "Off: the panel appears when Claude replies, or with ⌥Space.",
                        dimmed: !on) {
                SettingsSwitch(label: "Show Glance over terminals",
                               isOn: Binding(get: { model.terminalsAlwaysShown }, set: { model.setTerminalsAlwaysShown($0) }),
                               enabled: on)
            }
        }
        SettingsGroup(title: "Code editors") {
            SettingsRow(id: "overlay.editors", name: "Show Glance over code editors", detail: model.editorsEnabled
                ? "In VS Code, Cursor, Windsurf and Zed, Glance is an orb at the bottom right of the editor. Click it for "
                    + "the reply; drag it anywhere."
                : "Off: Glance leaves code editors to the Glance VS Code extension. Terminals still get the panel.",
                        dimmed: !on) {
                SettingsSwitch(label: "Show Glance over code editors",
                               isOn: Binding(get: { model.editorsEnabled }, set: { model.setEditorsEnabled($0) }),
                               enabled: on)
            }
        }
    }
}
