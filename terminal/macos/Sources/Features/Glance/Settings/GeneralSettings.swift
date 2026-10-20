import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// General (spec 2026-10-08-settings-design.md, "Sections"): what runs, what opens at launch, and the version. The
/// words are the old Settings window's.
struct GeneralSettings: View {
    let model: SettingsModel
    @State private var copied = false

    var body: some View {
        SettingsGroup(title: "App") {
            SettingsRow(id: "general.terminal", name: "Built-in terminal", detail: model.surfaces.terminal
                ? "Terminal windows with tabs, the editor and Home, and a Dock icon."
                : "Off: no windows and no Dock icon. Glance lives in the menu bar; turn this on to bring the terminal back.") {
                SettingsSwitch(label: "Built-in terminal",
                               isOn: Binding(get: { model.surfaces.terminal }, set: { model.setTerminalEnabled($0) }))
            }
            SettingsRow(id: "general.overlay", name: "Overlay on other terminals", detail: model.surfaces.overlay
                ? "The menu-bar item, the panel over Warp, iTerm and other terminals, the orb over code editors, ⌥Space and ⌥."
                : "Off: Glance stays out of other apps, with no menu-bar item and no global shortcuts.") {
                SettingsSwitch(label: "Overlay on other terminals",
                               isOn: Binding(get: { model.surfaces.overlay }, set: { model.setOverlayEnabled($0) }))
            }
        }
        SettingsGroup(title: "Launch") {
            SettingsRow(id: "general.home", name: "Show Home at launch",
                        detail: "Home opens as the first window's selected tab: recent projects, Claude and your plan "
                            + "usage. File → Home (⇧⌘H) opens it any time.",
                        dimmed: !model.surfaces.terminal) {
                SettingsSwitch(label: "Show Home at launch",
                               isOn: Binding(get: { model.showHomeAtLaunch }, set: { model.setShowHomeAtLaunch($0) }),
                               enabled: model.surfaces.terminal)
            }
            SettingsRow(id: "general.claude", name: "Open Claude Code at launch",
                        detail: model.openClaudeAtLaunch
                            ? "The first terminal tab starts `claude` in its shell; quitting Claude leaves the shell."
                            : "Off: the first terminal tab is a plain shell.",
                        dimmed: !model.surfaces.terminal) {
                SettingsSwitch(label: "Open Claude Code at launch",
                               isOn: Binding(get: { model.openClaudeAtLaunch }, set: { model.setOpenClaudeAtLaunch($0) }),
                               enabled: model.surfaces.terminal)
            }
            SettingsRow(id: "general.claudeFolder", name: "Claude Code folder",
                        detail: model.claudeLaunchFolder.map { "Claude starts in \(abbreviated($0))." }
                            ?? "Empty: Claude starts in your home folder.",
                        dimmed: !claudeFolderEnabled) {
                HStack(spacing: 8) {
                    StudioButton(title: "Choose…", icon: .folder, enabled: claudeFolderEnabled, height: 26) {
                        chooseClaudeFolder()
                    }
                    if model.claudeLaunchFolder != nil {
                        SettingsIconButton(icon: .close, label: "Use the home folder", size: 26) {
                            model.setClaudeLaunchFolder(nil)
                        }
                        .disabled(!claudeFolderEnabled)
                    }
                }
            }
        }
        if StudioFeatures.shared.isOn(.summaries) {
            SettingsGroup(title: "Claude") {
                SettingsRow(id: "general.summaries", name: "Transcript summaries", detail: model.summaryMode.detail) {
                    SegmentedTabs(items: SummaryMode.allCases.map { SegmentItem(value: $0, title: $0.name, count: nil) },
                                  selection: Binding(get: { model.summaryMode }, set: { model.setSummaryMode($0) }))
                }
                SettingsRow(id: "general.responseStyle", name: "Response style", detail: model.responseStyle.detail) {
                    SegmentedTabs(items: ResponseStyle.allCases.map { SegmentItem(value: $0, title: $0.name, count: nil) },
                                  selection: Binding(get: { model.responseStyle }, set: { model.setResponseStyle($0) }))
                }
            }
        }
        SettingsGroup(title: "Pull requests") {
            SettingsRow(id: "general.pullRequestsClaude", name: "Claude reads pull requests on its own",
                        detail: "Claude's read of each PR you open. Reply drafts come only when you ask.") {
                SettingsSwitch(label: "Claude reads pull requests on its own",
                               isOn: Binding(get: { model.pullRequestsAutoClaude },
                                             set: { model.setPullRequestsAutoClaude($0) }))
            }
        }
        SettingsGroup(title: "About") {
            SettingsRow(id: "general.updates", name: "Updates",
                        detail: "Glance checks for updates on its own. Check now to look right away.") {
                StudioButton(title: "Check for Updates…", icon: .refresh, height: 26) {
                    (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
                }
            }
            SettingsRow(id: "general.version", name: "Version", detail: "Glance's version, build and commit.") {
                HStack(spacing: 10) {
                    Text(AppVersion.current.full)
                        .font(.studioMono(12))
                        .foregroundStyle(StudioColors.body)
                        .textSelection(.enabled)
                    StudioButton(title: copied ? "Copied" : "Copy", icon: copied ? .check : .copy, height: 26) { copy() }
                        .help("Copy the version")
                }
            }
        }
    }

    private var claudeFolderEnabled: Bool { model.surfaces.terminal && model.openClaudeAtLaunch }

    /// `~/…` for a folder in the home folder.
    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseClaudeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder Claude Code starts in at launch."
        panel.directoryURL = URL(fileURLWithPath: model.claudeLaunchFolder ?? NSHomeDirectory())
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let path = panel.url?.path else { return }
            model.setClaudeLaunchFolder(path)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppVersion.current.full, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
