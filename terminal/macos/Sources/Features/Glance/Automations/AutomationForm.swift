import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The form Studio makes for an automation without ui/ (spec 2026-10-09-automations-design.md, "The UI": "generated
/// from inputs (+ Run and the last result)"): a field per input with its label above, its description under the
/// label and what's wrong under the field; Run (⌘↩); Save, which keeps the edits as the automation's settings (its
/// triggers and watchers use them, AutomationSettings); and the newest run's answer.
struct AutomationForm: View {
    @ObservedObject var controller: AutomationTabController
    let manifest: AutomationManifest
    @ObservedObject private var engine = AutomationEngine.shared
    @State private var saveNote: String?

    var body: some View {
        let fields = AutomationFormModel.fields(manifest)
        let running = engine.live.contains { $0.ref.automation == manifest.id }
        let asking = controller.pendingRun != nil
            || engine.live.contains { $0.ref.automation == manifest.id && $0.parked }
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                if fields.isEmpty {
                    Text("\(manifest.name) takes no inputs.")
                        .font(.studio(13))
                        .foregroundStyle(StudioColors.muted)
                } else {
                    StudioCard(rim: true) {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(fields) { field in
                                AutomationFieldView(field: field, value: binding(field),
                                                    error: controller.formErrors[field.name])
                            }
                        }
                        .padding(18)
                    }
                }
                HStack(spacing: 10) {
                    StudioButton(title: running ? "Running" : "Run", icon: .play, hint: asking ? nil : "⌘↩",
                                 style: asking ? .secondary : .primary, busy: running, enabled: !asking) {
                        // Blocked while an input is wrong: each error shows under its field.
                        controller.run(AutomationFormModel.inputs(fields, values: controller.formValues))
                    }
                    .keyboardShortcut(asking ? nil : KeyboardShortcut(.return, modifiers: .command))
                    StudioButton(title: "Save", style: .secondary, enabled: !controller.formValues.isEmpty) {
                        save(fields)
                    }
                    StudioButton(title: "Reset", style: .quiet) {
                        controller.formValues = [:]
                        controller.formErrors = [:]
                        saveNote = nil
                    }
                    if let saveNote {
                        Text(saveNote)
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                    }
                }
                AutomationLastResult(id: manifest.id) { run in
                    controller.selectedRun = run
                    controller.mode = .runs
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func binding(_ field: AutomationFormField) -> Binding<String> {
        Binding(get: { controller.formValues[field.name] ?? field.initial },
                set: { value in
                    controller.formValues[field.name] = value
                    controller.formErrors[field.name] = nil
                    saveNote = nil
                })
    }

    /// Blocked while an edited field is wrong: each error shows under its field. The saved values then show as the
    /// fields' own (the manifest's defaults are replaced), so the edits are cleared.
    private func save(_ fields: [AutomationFormField]) {
        let edited = controller.formValues
        let typed = AutomationFormModel.inputs(fields.filter { edited[$0.name] != nil }, values: edited)
        let errors = AutomationFormModel.errors(manifest, inputs: typed).filter { edited[$0.key] != nil }
        guard errors.isEmpty else {
            controller.formErrors = errors
            return
        }
        if engine.saveSettings(manifest.id, edited: edited) {
            controller.formValues = [:]
            controller.formErrors = [:]
            saveNote = "Saved. Its triggers use these from now on."
        } else {
            saveNote = "Couldn't save the settings."
        }
    }
}

/// One input: label (and "Required"), its description, its control, and what's wrong with it.
private struct AutomationFieldView: View {
    let field: AutomationFormField
    @Binding var value: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(field.label)
                    .font(.studio(12.5, .semibold))
                    .foregroundStyle(StudioColors.ink)
                if field.required {
                    Text("Required")
                        .font(.studio(11))
                        .foregroundStyle(StudioColors.muted)
                }
            }
            if let help = field.help {
                Text(help)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control
            if let error {
                Text(error)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.danger)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(field.label)
    }

    @ViewBuilder private var control: some View {
        switch field.control {
        case .line:
            StudioField(placeholder: "", text: $value)
        case .number:
            StudioField(placeholder: "0", text: $value, font: .studioMono(12))
        case .path:
            HStack(spacing: 8) {
                StudioField(placeholder: "~/folder/or/file", text: $value, font: .studioMono(12))
                StudioButton(title: "Choose…", style: .secondary) { choose() }
            }
        case .multiline:
            StudioTextEditor(placeholder: "", text: $value, minHeight: 96)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(StudioColors.line3, lineWidth: 1))
        case .toggle:
            SettingsSwitch(label: field.label,
                           isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" }))
        case .choice(let options):
            Picker(field.label, selection: $value) {
                if !field.required || value.isEmpty { Text("None").tag("") }
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            value = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// Under the form: the newest run, its status, its answer, and Open run.
private struct AutomationLastResult: View {
    let open: (String) -> Void
    @StateObject private var model: AutomationRunsModel

    init(id: String, open: @escaping (String) -> Void) {
        self.open = open
        _model = StateObject(wrappedValue: AutomationRunsModel(id: id, limit: 1))
    }

    var body: some View {
        if let record = model.records.first {
            VStack(alignment: .leading, spacing: 10) {
                Caption("Last run")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    AutomationStatusGlyph(tone: AutomationRunText.tone(record.status))
                    Text(AutomationRunText.status(record.status))
                        .font(.studio(13, .semibold))
                        .foregroundStyle(StudioColors.ink)
                    Text(AutomationText.ago(record.startedAt, now: Date()))
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                    Spacer(minLength: 8)
                    Button("Open run") { open(record.id) }
                        .buttonStyle(.plain)
                        .font(.studio(12, .medium))
                        .foregroundStyle(StudioColors.coralInk)
                }
                if let result = AutomationRunText.result(record) {
                    AutomationTextBlock(text: result, failed: record.status == .failed)
                }
            }
            .padding(.top, 6)
        }
    }
}
