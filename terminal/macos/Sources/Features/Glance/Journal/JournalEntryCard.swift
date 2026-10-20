import GlanceCore
import GlanceKit
import SwiftUI

/// An accomplishment on a day page: kind, project, title, summary, impact, skills, and its story under a disclosure.
/// Edit turns the fields into text fields; Save keeps the change (and marks the entry so a redraft keeps it). The star
/// marks a highlight.
struct JournalEntryCard: View {
    let entry: JournalEntry
    @ObservedObject private var journal = JournalService.shared
    @State private var editing = false
    @State private var draft: JournalEntry
    @State private var skills = ""
    @State private var showStory = false

    init(entry: JournalEntry) {
        self.entry = entry
        _draft = State(initialValue: entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(editing ? "Editing" : entry.title)
                    .font(.studio(15, .semibold))
                    .foregroundStyle(editing ? StudioColors.muted : StudioColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                iconButton(.star, lit: entry.highlight, label: entry.highlight ? "Unstar" : "Star") {
                    var starred = entry
                    starred.highlight.toggle()
                    journal.save(starred)
                }
                iconButton(.pencil, lit: editing, label: editing ? "Stop editing" : "Edit") { toggleEditing() }
                iconButton(.trash, lit: false, label: "Delete entry") { journal.deleteEntry(entry) }
            }
            if editing { editor } else { reader }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(entry.highlight ? StudioColors.coral.opacity(0.6) : StudioColors.line, lineWidth: 1))
        .onChange(of: entry) { _, latest in if !editing { draft = latest } }
    }

    private var reader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meta)
                .font(.studio(11.5, .medium))
                .foregroundStyle(StudioColors.muted)
                .padding(.top, -6)
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !entry.impact.isEmpty {
                Text(entry.impact)
                    .font(.studioMono(12, .medium))
                    .foregroundStyle(StudioColors.tealInk)
            }
            if !entry.skills.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.skills, id: \.self) { skill in
                        Text(skill)
                            .font(.studio(11, .medium))
                            .foregroundStyle(StudioColors.body)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Capsule().fill(StudioColors.chip))
                    }
                }
            }
            if hasStory {
                DisclosureGroup(isExpanded: $showStory) {
                    VStack(alignment: .leading, spacing: 6) {
                        story("Challenge", entry.challenge)
                        story("Approach", entry.approach)
                        story("Outcome", entry.outcome)
                        story("Lesson", entry.lesson)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("The story")
                        .font(.studio(12, .semibold))
                        .foregroundStyle(StudioColors.muted)
                }
            }
        }
    }

    /// "Fixed · api · 1 h 35 min", under the title.
    private var meta: String {
        ([entry.kind.title] + (entry.project.map { [FolderLabel.name(forPath: $0)] } ?? [])
            + (entry.minutes > 0 ? [JournalFormat.duration(entry.minutes)] : [])).joined(separator: " · ")
    }

    private var hasStory: Bool {
        ![entry.challenge, entry.approach, entry.outcome, entry.lesson].allSatisfy(\.isEmpty)
    }

    @ViewBuilder
    private func story(_ name: String, _ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.studio(11, .semibold)).foregroundStyle(StudioColors.muted)
                Text(text)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Kind", selection: $draft.kind) {
                ForEach(JournalEntry.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
            field("Title", text: $draft.title)
            field("Summary", text: $draft.summary, lines: 3)
            field("Impact (a measured result)", text: $draft.impact)
            field("Challenge", text: $draft.challenge, lines: 2)
            field("Approach", text: $draft.approach, lines: 2)
            field("Outcome", text: $draft.outcome, lines: 2)
            field("Lesson", text: $draft.lesson, lines: 2)
            field("Skills, separated by commas", text: $skills)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                StudioButton(title: "Cancel", style: .quiet) { toggleEditing() }
                StudioButton(title: "Save", style: .primary,
                             enabled: !draft.title.trimmingCharacters(in: .whitespaces).isEmpty) { save() }
            }
        }
    }

    private func field(_ prompt: String, text: Binding<String>, lines: Int = 1) -> some View {
        TextField(prompt, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.studio(13))
            .foregroundStyle(StudioColors.ink)
            .lineLimit(1...max(1, lines))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
    }

    private func iconButton(_ icon: StudioIcons.Name, lit: Bool, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            StudioIcon(icon, size: 14)
                .foregroundStyle(lit ? StudioColors.coral : StudioColors.muted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func toggleEditing() {
        if !editing {
            draft = entry
            skills = entry.skills.joined(separator: ", ")
        }
        editing.toggle()
    }

    private func save() {
        var edited = draft
        edited.title = JournalText.clean(draft.title, limit: 80)
        edited.skills = skills.split(separator: ",").map { JournalText.clean($0.lowercased(), limit: 24) }
            .filter { !$0.isEmpty }
        journal.save(edited)
        editing = false
    }
}
