import GlanceCore
import GlanceKit
import SwiftUI

/// Suggestions (spec 2026-10-08-terminal-suggestions-design.md, "Settings: the Suggestions section"): the terminal's
/// Tab menu and its command history. Each switch reaches every open zsh tab at once.
struct SuggestionsSettings: View {
    let model: SettingsModel

    var body: some View {
        let elsewhere = ShellAssist.shared.keysOwnedElsewhere
        if !elsewhere.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(elsewhere, id: \.self) { line in
                    Text(line).font(.studio(12.5)).foregroundStyle(StudioColors.noteInk)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.note))
            .padding(.bottom, 20)
        }
        SettingsGroup(title: "Completions") {
            SettingsRow(id: "suggestions.tab", name: "Tab menu",
                        detail: "Tab shows every possible next word, with what it does, in a menu at the cursor. Keep "
                            + "typing to narrow it, ⏎ to insert. Works in zsh tabs Studio starts; over SSH, in tmux "
                            + "and in other shells Tab behaves as before.") {
                switchFor(.tab, label: "Tab menu")
            }
            SettingsRow(id: "suggestions.ghost", name: "Ghost text",
                        detail: "As you type, the rest of the command you most likely mean shows in grey: from your "
                            + "history in this folder and what you usually run next, else a command or file name. → "
                            + "takes it, ⌥→ one word.") {
                switchFor(.ghost, label: "Ghost text")
            }
            SettingsRow(id: "suggestions.next", name: "Predict the next command",
                        detail: "After a command, an empty prompt shows what you usually run next, once you've done it "
                            + "a few times (git commit after git add). A message that changes each time comes empty, "
                            + "the cursor in its quotes.") {
                switchFor(.next, label: "Predict the next command")
            }
        }
        SettingsGroup(title: "Mistakes") {
            SettingsRow(id: "suggestions.marks", name: "Error marks while typing",
                        detail: "A command name your shell doesn't know turns red and underlined once you move on "
                            + "from it, and so does an opening quote, $( or backtick that never closes. Off when "
                            + "zsh-syntax-highlighting is loaded, which marks the line itself.") {
                switchFor(.marks, label: "Error marks while typing")
            }
            SettingsRow(id: "suggestions.fixes", name: "Fixes after a failed command",
                        detail: "When a command fails, the next prompt offers the corrected one as ghost text: a "
                            + "mistyped command or branch, git push without an upstream, a missing script, sudo for "
                            + "a permission error. → takes it; nothing runs on its own.") {
                switchFor(.fixes, label: "Fixes after a failed command")
            }
        }
        SettingsGroup(title: "Claude") {
            SettingsRow(id: "suggestions.claude", name: "Claude in the terminal", detail: claudeLine) {
                switchFor(.claude, label: "Claude in the terminal")
            }
        }
        SettingsGroup(title: "History") {
            SettingsRow(id: "suggestions.up", name: "↑ history list",
                        detail: "↑ on the prompt lists your commands above it: this tab's first, then this folder's, "
                            + "then the rest. Keep typing to narrow it; ⏎ runs one, Tab puts it on the line to edit.") {
                switchFor(.up, label: "↑ history list")
            }
            SettingsRow(id: "suggestions.search", name: "⌃R history search",
                        detail: "⌃R searches every command you've run, by any words in any order. Tab switches "
                            + "between all of them, this folder's and this tab's; ⌘⌫ forgets one.") {
                switchFor(.search, label: "⌃R history search")
            }
            SettingsRow(id: "suggestions.record", name: "Record history",
                        detail: "Studio keeps each command you run with its folder, exit code and how long it took, on "
                            + "this Mac only. Commands that start with a space or hold a key or password are never "
                            + "kept. Your ~/.zsh_history is left as it is.") {
                SettingsSwitch(label: "Record history",
                               isOn: Binding(get: { model.suggestions.recordHistory }, set: { model.setRecordHistory($0) }))
            }
            SettingsRow(id: "suggestions.import", name: "zsh history",
                        detail: historyLine) {
                HStack(spacing: 8) {
                    StudioButton(title: "Import again", height: 26) { ShellAssist.shared.reimportHistory() }
                    StudioButton(title: "Clear…", height: 26) { confirmClear() }
                }
            }
        }
    }

    private var claudeLine: String {
        let base = "Type # and what you want, then ⏎ or Tab, for commands to run; after a failure, ⌘I (or the Ask "
            + "Claude pill) says what went wrong. Claude Haiku answers through your Claude Code, only when you ask, "
            + "with the folder, this tab's last commands and the error, never your files or environment."
        switch ShellAssist.shared.claudePath {
        case nil: return base
        case "": return base + " Claude Code isn't installed: install it and sign in with `claude` to use this."
        case let path?: return base + " Using \(ShellFormat.folder(path))."
        }
    }

    private var historyLine: String {
        let assist = ShellAssist.shared
        if let problem = assist.historyProblem { return problem }
        let count = assist.historyCount
        guard count > 0 else { return "No commands yet. Your ~/.zsh_history comes in the first time a Studio tab opens." }
        return "\(count) distinct command\(count == 1 ? "" : "s"), \(assist.importedCount) of them only from your "
            + "~/.zsh_history. Import again reads that file anew; Clear forgets everything Glance kept."
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear Glance's command history?"
        alert.informativeText = "Every command Studio recorded and imported is forgotten. Your ~/.zsh_history isn't "
            + "touched."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { ShellAssist.shared.clearHistory() }
    }

    private func switchFor(_ feature: SuggestionFeature, label: String) -> some View {
        SettingsSwitch(label: label, isOn: Binding(get: { model.suggestions.isOn(feature) },
                                                   set: { model.setSuggestion(feature, $0) }))
    }
}
