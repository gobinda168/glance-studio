import GlanceCore
import GlanceKit
import SwiftUI

/// Editor (spec 2026-10-08-settings-design.md, "Sections"): which editor a new editor tab opens, and Razor Code's
/// format on save. The words are the old Settings window's.
struct EditorSettings: View {
    let model: SettingsModel

    var body: some View {
        if !model.surfaces.terminal {
            SettingsNote(text: "Editor tabs live in the built-in terminal's windows. Turn it on in General.",
                         action: "General") { SettingsNavigation.shared.show(.general, focus: "general.terminal") }
        }
        SettingsGroup(title: "Editor tab") {
            if EditorTabs.offersGSCode {
                SettingsRow(id: "editor.kind", name: "Editor tab", detail: model.editorKind == .razor
                    ? "Razor Code opens instantly and stays light: Monaco with a file tree, tabs, project search and Claude's "
                        + "changes. Each editor tab can switch to GS Code."
                    : "GS Code is a full VS Code workbench: extensions, IntelliSense, debugging. It downloads 130 MB the "
                        + "first time and uses about 1 GB of memory per tab.") {
                    SegmentedTabs(items: EditorKind.allCases.map { SegmentItem(value: $0, title: $0.name, count: nil) },
                                  selection: Binding(get: { model.editorKind }, set: { model.setEditorKind($0) }))
                }
            }
            SettingsRow(id: "editor.formatOnSave", name: "Format on save",
                        detail: "Razor Code formats a file each time you save it, the same as ⇧⌥F: Prettier for web "
                            + "languages, the project's own formatter for Python, Swift, Go, Rust and shell.") {
                SettingsSwitch(label: "Format on save",
                               isOn: Binding(get: { model.formatOnSave }, set: { model.setFormatOnSave($0) }))
            }
        }
        .opacity(model.surfaces.terminal ? 1 : 0.5)
        .disabled(!model.surfaces.terminal)
    }
}
