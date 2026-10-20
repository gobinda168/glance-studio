import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Settings → Secrets' editor (replica: secrets.js, "The editor sheet"): name, note, the write-only value, hosts as
/// chips, how it's sent with a live preview, the folder fence and the approval; problems above Cancel / Save. The
/// value typed here goes only into the draft handed to `SecretsModel.add` / `update`; nothing logs or keeps it, and a
/// revealed value never comes back into this sheet (see `SecretRevealPanel`).
struct SecretEditorSheet: View {
    let target: SecretEditTarget
    @ObservedObject var model: SecretsModel
    /// The scrolling form's height, from the window the sheet drops from (`formHeight(in:)`).
    let formHeight: CGFloat
    let close: () -> Void
    @ObservedObject private var reveals = SecretRevealPanel.shared

    @State private var draft: SecretDraft
    @State private var chips: [String]
    @State private var hostText = ""
    @State private var onlyFolders: Bool
    @State private var folderList: [String]
    @State private var problems: [String] = []
    @State private var saving = false
    @State private var deleting = false
    @State private var revealing = false
    @FocusState private var hostFocused: Bool
    @FocusState private var valueFocused: Bool
    /// The saved name, for the title and the reveal panel (the Name field may be mid-edit).
    private let savedName: String

    init(target: SecretEditTarget, model: SecretsModel, formHeight: CGFloat, close: @escaping () -> Void) {
        self.target = target
        self.model = model
        self.formHeight = formHeight
        self.close = close
        let draft: SecretDraft
        switch target {
        case .new: draft = SecretDraft()
        case .existing(_, let saved): draft = saved
        }
        savedName = draft.name
        _draft = State(initialValue: draft)
        _chips = State(initialValue: draft.hostList)
        _onlyFolders = State(initialValue: !draft.folders.isEmpty)
        _folderList = State(initialValue: draft.folders)
    }

    /// The header (about 70pt), the footer (about 60pt), a problem box and the window's title bar fit around the form,
    /// so Save stays on screen in a short window.
    static func formHeight(in windowHeight: CGFloat) -> CGFloat {
        min(540, max(200, windowHeight - 260))
    }

    private var editingID: UUID? {
        if case .existing(let id, _) = target { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(StudioColors.line2).frame(height: 1)
            ScrollView(.vertical) {
                form
                    .padding(.top, 20)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 22)
            }
            .frame(height: formHeight)
            if !shownProblems.isEmpty { problemBox }
            footer
        }
        .frame(width: 600)
        .background(StudioColors.card)
        .onDisappear {
            draft.value = ""
            SecretRevealPanel.close()
        }
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if editingID != nil {
                    Text("Edit ").font(.studio(17, .bold)) + Text(savedName).font(.studioMono(16, .bold))
                } else {
                    Text("Add a secret").font(.studio(17, .bold))
                }
            }
            .foregroundStyle(StudioColors.ink)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            Text(editingID != nil ? "Your changes apply to Claude's next request."
                 : "Claude can use it through Glance, but never sees it.")
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 22)
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if editingID != nil {
                SecretsButton(title: "Delete…", symbol: "touchid", style: .danger, busy: deleting,
                              enabled: !saving, height: 28) { delete() }
                    .help("Deleting asks for Touch ID")
            }
            Spacer(minLength: 8)
            StudioButton(title: "Cancel", height: 28) { close() }
                .keyboardShortcut(.cancelAction)
            StudioButton(title: "Save", style: .primary, busy: saving, enabled: !deleting, height: 28) { save() }
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.top, 14)
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
    }

    private var problemBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shownProblems, id: \.self) { problem in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StudioIcon(.alert, size: 13).foregroundStyle(StudioColors.danger)
                    Text(problem)
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.dangerFill))
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    /// The save's problems, less the host ones already shown under the Hosts field.
    private var shownProblems: [String] {
        let shown = Set(hostProblems)
        return problems.filter { !shown.contains($0) }
    }

    // MARK: The form

    private var form: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 18) {
            GridRow {
                label("Name")
                VStack(alignment: .leading, spacing: 8) {
                    StudioField(placeholder: "GITHUB_TOKEN", text: $draft.name, height: 32, font: .studioMono(12.5))
                        .accessibilityLabel("Name")
                    hint("Capital letters, digits and _. Claude asks for it by this name.")
                }
            }
            GridRow {
                label("Note")
                StudioField(placeholder: "What it's for, so Claude picks the right one", text: $draft.note,
                            height: 32, font: .studio(13))
                    .accessibilityLabel("Note")
            }
            GridRow {
                label("Value")
                valueField
            }
            GridRow {
                label("Hosts")
                hostField
            }
            GridRow {
                label("Sent as")
                slotFields
            }
            GridRow {
                label("Folders", top: 1)
                folderFields
            }
            GridRow {
                label("Approval", top: 1)
                approvalFields
            }
        }
    }

    private func label(_ text: String, top: CGFloat = 8) -> some View {
        Text(text)
            .font(.studio(12.5, .medium))
            .foregroundStyle(StudioColors.ink)
            .padding(.top, top)
            .frame(width: 96, alignment: .leading)
    }

    private func hint(_ text: String, color: Color = StudioColors.muted) -> some View {
        Text(text)
            .font(.studio(11.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fieldFrame(focused: Bool, refused: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(refused ? StudioColors.danger.opacity(0.6) : focused ? StudioColors.coral : StudioColors.line3,
                          lineWidth: 1)
    }

    // MARK: Value

    private var valueField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SecureField(editingID != nil ? "Saved. Leave empty to keep it." : "Paste the token", text: $draft.value)
                    .textFieldStyle(.plain)
                    .font(.studioMono(12.5))
                    .foregroundStyle(StudioColors.ink)
                    .focused($valueFocused)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                    .overlay(fieldFrame(focused: valueFocused))
                    .accessibilityLabel("Value")
                if editingID != nil {
                    Button(action: reveal) {
                        HStack(spacing: 5) {
                            if revealing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "touchid").font(.system(size: 12)).accessibilityHidden(true)
                            }
                            Text("Reveal").font(.studio(12.5, .medium))
                        }
                        .foregroundStyle(StudioColors.coralInk)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(revealing)
                    .help("Reveal asks for Touch ID and shows the value for 15 seconds")
                    .accessibilityLabel("Reveal the value")
                }
            }
            hint(editingID != nil ? "Write-only: it's never shown again unless you reveal it with Touch ID."
                 : "Write-only: once saved it shows as ••••.")
        }
    }

    // MARK: Hosts

    private var hostProblems: [String] { chips.compactMap(SecretHostRule.problem(pattern:)) }

    private var hostField: some View {
        let refusals = hostProblems
        return VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 6) {
                ForEach(chips, id: \.self) { chip in
                    HostChip(host: chip, refused: SecretHostRule.problem(pattern: chip) != nil) {
                        chips.removeAll { $0 == chip }
                    }
                }
                TextField(chips.isEmpty ? "api.example.com" : "Add another", text: hostBinding)
                    .textFieldStyle(.plain)
                    .font(.studioMono(12))
                    .foregroundStyle(StudioColors.ink)
                    .focused($hostFocused)
                    .onSubmit(commitHostText)
                    .frame(width: 170, height: 24)
                    .padding(.leading, chips.isEmpty ? 7 : 4)
                    .accessibilityLabel("Add a host")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
            .overlay(fieldFrame(focused: hostFocused, refused: !refusals.isEmpty))
            .contentShape(Rectangle())
            .onTapGesture { hostFocused = true }
            if refusals.isEmpty {
                hint("HTTPS only. Exact names, or *.example.com for its subdomains. ⏎ adds one.")
            } else {
                ForEach(refusals, id: \.self) { problem in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        StudioIcon(.alert, size: 13).foregroundStyle(StudioColors.danger)
                        Text(problem)
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Typing a comma or a space ends a host, as ⏎ does.
    private var hostBinding: Binding<String> {
        Binding(get: { hostText }, set: { text in
            let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
            guard text.unicodeScalars.contains(where: separators.contains) else { hostText = text; return }
            var parts = text.components(separatedBy: separators)
            let rest = parts.removeLast()
            parts.forEach(addChip)
            hostText = rest
        })
    }

    private func commitHostText() {
        addChip(hostText)
        hostText = ""
    }

    /// "https://api.github.com/repos" → "api.github.com"; host names lowercased as the draft stores them. A refused one
    /// is kept, struck through, with its reason under the field.
    private func addChip(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        guard !text.isEmpty else { return }
        let host = SecretHostRule.normalize(text) ?? text
        if !chips.contains(host) { chips.append(host) }
    }

    // MARK: Sent as

    private var slotFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            SegmentedTabs(items: [SegmentItem(value: SecretDraft.SlotKind.bearer, title: "Bearer", count: nil),
                                  SegmentItem(value: .header, title: "Header", count: nil),
                                  SegmentItem(value: .basic, title: "Basic", count: nil)],
                          selection: $draft.slotKind)
                .fixedSize()
            switch draft.slotKind {
            case .bearer:
                EmptyView()
            case .header:
                HStack(alignment: .top, spacing: 10) {
                    labelled("Header name") {
                        StudioField(placeholder: "X-API-Key", text: $draft.headerName, height: 32,
                                    font: .studioMono(12.5))
                    }
                    labelled("Prefix", optional: true) {
                        StudioField(placeholder: "Token ", text: $draft.headerPrefix, height: 32,
                                    font: .studioMono(12.5))
                    }
                }
            case .basic:
                HStack(spacing: 10) {
                    labelled("Username") {
                        StudioField(placeholder: "username", text: $draft.username, height: 32, font: .studioMono(12.5))
                    }
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
            preview
            hint("Every request carries this header. Claude can't set it itself.")
        }
    }

    private func labelled<Field: View>(_ title: String, optional: Bool = false,
                                       @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            (Text(title).foregroundColor(StudioColors.body)
                + Text(optional ? " optional" : "").italic().foregroundColor(StudioColors.muted))
                .font(.studio(11.5))
            field().accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The header every request will carry, the value masked (the same words as a row's "sent as").
    private var preview: some View {
        let header = SecretsCopy.header(draft.slot)
        return (Text("\(header.name):").foregroundColor(StudioColors.muted)
            + Text(" \(header.value)").foregroundColor(StudioColors.ink))
            .font(.studioMono(12.5))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preview: \(header.name): \(header.value)")
    }

    // MARK: Folders and approval

    private var folderFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Folders", selection: $onlyFolders) {
                Text("Any folder").tag(false)
                Text("Only in these folders").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .font(.studio(13))
            if onlyFolders {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(folderList, id: \.self) { folder in
                        HStack(spacing: 8) {
                            StudioIcon(.folder, size: 13).foregroundStyle(StudioColors.muted)
                            Text(SecretsCopy.folder(folder))
                                .font(.studioMono(12))
                                .foregroundStyle(StudioColors.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { folderList.removeAll { $0 == folder } } label: {
                                StudioIcon(.close, size: 11)
                                    .foregroundStyle(StudioColors.muted)
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(SecretsCopy.folder(folder))")
                            .accessibilityLabel("Remove \(SecretsCopy.folder(folder))")
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 5)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
                        .help(folder)
                    }
                    // Disabled while a value is revealed: its modal panel would sit over the reveal.
                    StudioButton(title: "Add Folder…", icon: .plus, enabled: !reveals.showing, height: 26) {
                        addFolders()
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    private var approvalFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Approval", selection: $draft.approval) {
                ForEach(SecretApproval.allCases, id: \.self) { approval in
                    Text(SecretsCopy.choice(approval)).tag(approval)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .font(.studio(13))
            if draft.approval == .always {
                hint(onlyFolders && !folderList.isEmpty ? "A Claude started in another folder still can't use it."
                     : "Always needs a folder: choose Only in these folders and add a project.",
                     color: StudioColors.amber)
            }
        }
    }

    private func addFolders() {
        SecretRevealPanel.close()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Claude sessions started in these folders, or inside them, can use this secret."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !folderList.contains(path) { folderList.append(path) }
        }
    }

    // MARK: Save, delete, reveal

    private func save() {
        guard !saving, !deleting else { return }
        commitHostText()
        if onlyFolders && folderList.isEmpty {
            problems = ["Add a folder, or choose Any folder."]
            return
        }
        // The only copy of a typed value besides the field's: it goes to the model and nowhere else.
        var made = draft
        made.hosts = chips.joined(separator: ", ")
        made.folders = onlyFolders ? folderList : []
        saving = true
        Task { @MainActor in
            let result: [String]
            if let id = editingID {
                result = await model.update(made, id: id)
            } else {
                result = await model.add(made)
            }
            saving = false
            problems = result
            if result.isEmpty { close() }
        }
    }

    private func delete() {
        guard let id = editingID, !deleting, !saving else { return }
        deleting = true
        Task { @MainActor in
            let failure = await model.delete(id)
            deleting = false
            if let failure {
                problems = [failure]
            } else if !model.rows.contains(where: { $0.id == id }) {
                close()
            }
        }
    }

    /// Touch ID, then the value in its own panel; it never touches this sheet's fields.
    private func reveal() {
        guard let id = editingID, !revealing else { return }
        revealing = true
        let name = savedName
        Task { @MainActor in
            let value = await model.reveal(id)
            revealing = false
            guard let value else { return }
            SecretRevealPanel.show(name: name, value: value)
        }
    }
}

/// A host in the Hosts field: mono on the chip fill with ×; a refused one struck through in the danger tint.
private struct HostChip: View {
    let host: String
    let refused: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(host)
                .font(.studioMono(11.5, .medium))
                .strikethrough(refused, color: StudioColors.danger)
                .foregroundStyle(refused ? StudioColors.danger : StudioColors.ink)
                .lineLimit(1)
            Button(action: remove) {
                StudioIcon(.close, size: 9)
                    .foregroundStyle(refused ? StudioColors.danger : StudioColors.muted)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(host)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(refused ? StudioColors.dangerFill : StudioColors.chip))
    }
}
