import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The To-dos & Notes side bar: Notes and To-dos tabs that follow the page. Notes lists every note, newest first, under
/// New note; To-dos lists All and the groups (Work, Personal…), then the chosen group's to-dos to add and tick in place.
/// A tab or a row opens the window's tab on it.
struct CapturesSidebarView: View {
    @ObservedObject private var captures = CaptureStore.shared
    @ObservedObject private var navigation = CapturesNavigation.shared
    @ObservedObject private var diagrams = NoteDiagrams.shared
    @State private var window: NSWindow?
    @State private var newTodo = ""
    @State private var addingGroup = false
    @State private var newGroup = ""
    @FocusState private var newGroupFocused: Bool
    @State private var renaming: Captures.TodoGroup?
    @State private var renameText = ""
    @State private var deleting: Captures.TodoGroup?

    private enum Tab: Hashable { case notes, todos }

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(title: "To-dos & Notes") { EmptyView() }
            SegmentedTabs(items: [
                SegmentItem(value: Tab.notes, title: "Notes", count: captures.notes.isEmpty ? nil : captures.notes.count),
                SegmentItem(value: .todos, title: "To-dos", count: captures.openCount == 0 ? nil : captures.openCount),
            ], selection: tab, fill: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    if navigation.isNotes { notes } else { todos }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { window = $0 })
        .alert("Rename group", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let group = renaming { captures.renameGroup(group.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Group", role: .destructive) {
                if let group = deleting {
                    if navigation.todoGroup == group.id { navigation.showGroup(nil) }
                    captures.deleteGroup(group.id)
                }
                deleting = nil
            }
        } message: {
            Text("Its to-dos stay, under All.")
        }
    }

    private var tab: Binding<Tab> {
        Binding(get: { navigation.isNotes ? .notes : .todos }, set: { tab in
            guard tab != (navigation.isNotes ? .notes : .todos) else { return }
            CapturesTabController.open(tab == .notes ? .notes(nil) : .todos, from: window)
        })
    }

    // MARK: Notes

    @ViewBuilder private var notes: some View {
        CapturesAddRow(title: "New note") {
            let note = captures.newNote()
            CapturesTabController.open(.notes(note.id), from: window)
        }
        if captures.notes.isEmpty {
            hint("Select text anywhere and right-click → Ask Glance…, or start one here.")
        }
        ForEach(captures.notes) { note in
            JournalSidebarRow(icon: nil, title: note.displayTitle, detail: detail(note),
                              dot: diagrams.working[note.id] != nil ? StudioColors.coral : nil,
                              selected: isSelected(note)) {
                CapturesTabController.open(.notes(note.id), from: window)
            }
        }
    }

    private func detail(_ note: NoteDoc) -> String {
        let date = note.updated.formatted(.dateTime.day().month(.abbreviated))
        guard !note.diagrams.isEmpty else { return date }
        return "\(date) · \(note.diagrams.count) diagram\(note.diagrams.count == 1 ? "" : "s")"
    }

    private func isSelected(_ note: NoteDoc) -> Bool {
        guard case .notes(let id) = navigation.page else { return false }
        return (id ?? captures.notes.first?.id) == note.id
    }

    // MARK: To-dos

    @ViewBuilder private var todos: some View {
        HStack(spacing: 8) {
            StudioIcon(.plus, size: 13).foregroundStyle(StudioColors.coralInk).frame(width: 16)
            TextField("Add a to-do", text: $newTodo)
                .textFieldStyle(.plain)
                .font(.studio(13))
                .foregroundStyle(StudioColors.ink)
                .onSubmit {
                    try? captures.addTodo(newTodo, source: nil, group: navigation.todoGroup)
                    newTodo = ""
                }
                .accessibilityLabel(groupName.map { "Add a to-do to \($0)" } ?? "Add a to-do")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line))
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        groups
        Caption(groupName ?? "All")
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
        let list = Captures.ordered(Captures.inGroup(captures.todos, navigation.todoGroup))
        if list.isEmpty {
            hint(navigation.todoGroup == nil ? "Nothing to do. Add one here, or from selected text with Ask Claude."
                                             : "Nothing in \(groupName ?? "this group"). Add one above.")
        }
        ForEach(list) { todo in
            CapturesTodoRow(todo: todo) {
                CapturesNavigation.shared.select(todo.id)
                CapturesTabController.open(.todos, from: window)
            }
        }
    }

    private var groupName: String? { captures.group(navigation.todoGroup)?.name }

    /// All, each group with its open count, then + New group (named in place).
    @ViewBuilder private var groups: some View {
        TodoGroupRow(icon: "tray.2", title: "All", count: captures.openCount,
                     selected: navigation.todoGroup == nil) { showGroup(nil) }
        ForEach(captures.groups) { group in
            TodoGroupRow(icon: "folder", title: group.name, count: captures.openCount(in: group.id),
                         selected: navigation.todoGroup == group.id) { showGroup(group.id) }
                .contextMenu {
                    Button("Rename…") {
                        renameText = group.name
                        renaming = group
                    }
                    Button("Delete…", role: .destructive) { deleting = group }
                }
        }
        if addingGroup {
            HStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(StudioColors.muted).frame(width: 16)
                TextField("Group name", text: $newGroup)
                    .textFieldStyle(.plain)
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.ink)
                    .focused($newGroupFocused)
                    .onSubmit {
                        if let id = captures.addGroup(newGroup) { showGroup(id) }
                        newGroup = ""
                        addingGroup = false
                    }
                    .onExitCommand { newGroup = ""; addingGroup = false }
                    .onChange(of: newGroupFocused) { if !newGroupFocused && newGroup.isEmpty { addingGroup = false } }
                    .onAppear { newGroupFocused = true }
                    .accessibilityLabel("New group name")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        } else {
            CapturesAddRow(title: "New group") { addingGroup = true }
        }
    }

    private func showGroup(_ group: UUID?) {
        navigation.showGroup(group)
        if let id = navigation.selectedTodo, captures.todo(id)?.group != group, group != nil { navigation.select(nil) }
        CapturesTabController.open(.todos, from: window)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.studio(11.5))
            .foregroundStyle(StudioColors.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}

/// All or a group: its glyph, name and open count; the chosen one is plated.
private struct TodoGroupRow: View {
    let icon: String
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(selected || hovering ? StudioColors.ink : StudioColors.muted)
                    .frame(width: 16)
                Text(title)
                    .font(.studio(13, selected ? .semibold : .medium))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.studioMono(11, .medium))
                        .foregroundStyle(StudioColors.muted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background { SettingsRowPlate(selected: selected, hovering: hovering) }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel("\(title), \(count) open")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A side bar row that makes something: a + and its title.
private struct CapturesAddRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StudioIcon(.plus, size: 13).frame(width: 16)
                Text(title).font(.studio(13, .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background { SettingsRowPlate(selected: false, hovering: hovering) }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel(title)
    }
}

/// A to-do in the side bar: its tick, its text and sub-item count; clicking opens it on the To-dos page.
private struct CapturesTodoRow: View {
    let todo: Captures.Todo
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TodoTick(todo: todo, size: 13).frame(width: 16)
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(todo.text)
                        .font(.studio(13))
                        .foregroundStyle(todo.done ? StudioColors.muted : StudioColors.ink)
                        .strikethrough(todo.done)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    let progress = todo.progress
                    if progress.total > 0 {
                        Text("\(progress.done)/\(progress.total)")
                            .font(.studioMono(10.5))
                            .foregroundStyle(StudioColors.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background { SettingsRowPlate(selected: false, hovering: hovering) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}
