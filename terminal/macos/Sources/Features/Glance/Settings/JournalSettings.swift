import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Settings → Journal (spec "The on/off switch and disclaimer"): the switch, the wrap-up time, the sources, export,
/// and delete everything.
struct JournalSettings: View {
    @ObservedObject private var journal = JournalService.shared
    @State private var confirmDelete = false
    @State private var exported: String?

    var body: some View {
        let on = journal.settings.enabled
        SettingsGroup(title: "Journal") {
            SettingsRow(id: "journal.enabled", name: "Journaling",
                        detail: "Glance collects your day and Claude drafts a recap of what you got done. "
                            + "Everything stays on this Mac.") {
                SettingsSwitch(label: "Journaling", isOn: Binding(get: { on }, set: { journal.setEnabled($0) }))
            }
            SettingsRow(id: "journal.wrapUp", name: "Wrap up my day",
                        detail: "At this time Claude drafts today's recap, and a nudge says it's ready.",
                        dimmed: !on) {
                HStack(spacing: 10) {
                    DatePicker("Wrap-up time", selection: wrapUpTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .disabled(!journal.settings.wrapUp)
                    SettingsSwitch(label: "Wrap up my day", isOn: Binding(get: { journal.settings.wrapUp },
                                                                          set: { journal.setWrapUp($0) }))
                }
            }
        }
        SettingsGroup(title: "Sources") {
            SettingsRow(id: "journal.sources", name: "Sources",
                        detail: "Switch off anything Journal shouldn't read. What's already kept stays until you "
                            + "delete it.", dimmed: !on, stacked: true) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(JournalSource.allCases, id: \.self) { source in
                        Toggle(isOn: Binding(get: { !journal.settings.sourcesOff.contains(source) },
                                             set: { journal.setSource(source, on: $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.title)
                                    .font(.studio(13))
                                    .foregroundStyle(StudioColors.ink)
                                Text(source.detail)
                                    .font(.studio(11.5))
                                    .foregroundStyle(StudioColors.muted)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        SettingsGroup(title: "Your data") {
            SettingsRow(id: "journal.export", name: "Export",
                        detail: exported ?? "Every day, event and entry as JSON, and your recaps as Markdown, a file "
                            + "per month.") {
                StudioButton(title: "Export…") { export() }
            }
            SettingsRow(id: "journal.delete", name: "Delete all journal data",
                        detail: movedAsideLine ?? "Removes every day, recap, entry and note from this Mac. This "
                            + "can't be undone.") {
                StudioButton(title: "Delete All…") { confirmDelete = true }
            }
        }
        .confirmationDialog("Delete all journal data?", isPresented: $confirmDelete) {
            Button("Delete All", role: .destructive) { journal.deleteAll() }
        } message: {
            Text("Every day, recap, entry and note is removed from this Mac.")
        }
    }

    private var movedAsideLine: String? {
        journal.movedAside.map { "The journal couldn't be read, so it was moved to \($0.lastPathComponent) and a new "
            + "one started. Delete All removes the new one only." }
    }

    /// The wrap-up time as a date today, for the picker.
    private var wrapUpTime: Binding<Date> {
        Binding(
            get: {
                let minutes = journal.settings.wrapUpMinutes
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())
                    ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                journal.setWrapUpMinutes((parts.hour ?? 19) * 60 + (parts.minute ?? 0))
            })
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to put the Glance Journal folder."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        journal.export(to: folder) { result in
            switch result {
            case .success(let target): exported = "Exported to \(target.path)."
            case .failure(let error): exported = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }
}
