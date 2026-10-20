import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The selected to-do: title, status, group, priority, due, tags, link, sub-items, notes, then where it came from.
/// Every edit goes through `CaptureStore.update`, which writes a moment after the typing stops.
struct TodoDetails: View {
    @ObservedObject private var captures = CaptureStore.shared
    let id: UUID
    @State private var window: NSWindow?

    var body: some View {
        if let todo = captures.todo(id) {
            VStack(spacing: 0) {
                HStack {
                    Caption("To-do")
                    Spacer()
                    Button { CapturesNavigation.shared.select(nil) } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StudioColors.muted)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                    .accessibilityLabel("Close details")
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        TextField("Title", text: binding(\.text, todo), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.studio(16, .semibold))
                            .foregroundStyle(StudioColors.ink)
                            .accessibilityLabel("Title")
                        fields(todo)
                        TodoSubitems(todo: todo)
                        VStack(alignment: .leading, spacing: 6) {
                            Caption("Notes")
                            StudioTextEditor(placeholder: "Add notes (Markdown)", text: binding(\.notes, todo), minHeight: 96)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(StudioColors.field))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(StudioColors.line))
                        }
                        footer(todo)
                    }
                    .padding(16)
                }
            }
            .background(WindowAccessor { window = $0 })
        }
    }

    // MARK: Fields

    private func fields(_ todo: Captures.Todo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Status") {
                SegmentedTabs(items: Captures.Todo.Status.allCases.map { SegmentItem(value: $0, title: $0.title, count: nil) },
                              selection: Binding(get: { todo.status }, set: { captures.setStatus(id, $0) }),
                              fill: true)
            }
            field("Group") {
                Picker("", selection: Binding(get: { todo.group }, set: { captures.setGroup(id, $0) })) {
                    Text("No group").tag(UUID?.none)
                    ForEach(captures.groups) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            field("Priority") {
                Picker("", selection: binding(\.priority, todo)) {
                    ForEach(Captures.Todo.Priority.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            field("Due") {
                if todo.due != nil {
                    HStack(spacing: 6) {
                        DatePicker("", selection: Binding(get: { todo.due ?? Date() },
                                                          set: { date in captures.update(id) { $0.due = date } }),
                                   displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                        Button { captures.update(id) { $0.due = nil } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(StudioColors.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear due date")
                    }
                } else {
                    Button("Add a due date") { captures.update(id) { $0.due = Calendar.current.startOfDay(for: Date()) } }
                        .buttonStyle(.link)
                        .font(.studio(12.5))
                }
            }
            field("Tags") { TodoTagsField(todo: todo) }
            field("Link") {
                HStack(spacing: 6) {
                    TextField("URL or file path", text: Binding(get: { todo.link ?? "" }, set: { text in
                        captures.update(id) { $0.link = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text }
                    }))
                    .textFieldStyle(.plain)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.ink)
                    if let link = todo.link {
                        Button("Open") { _ = AutomationLinkOpener.open(link, from: window) }
                            .buttonStyle(.link)
                            .font(.studio(12.5, .medium))
                    }
                }
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
                .frame(width: 58, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func footer(_ todo: Captures.Todo) -> some View {
        HStack {
            let date = todo.created.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            Text(todo.source.map { "Added \(date) · from \($0)" } ?? "Added \(date)")
                .font(.studio(11.5))
                .foregroundStyle(StudioColors.muted)
            Spacer()
            Button("Delete", role: .destructive) { captures.remove(todo) }
                .buttonStyle(.link)
                .font(.studio(12, .medium))
                .foregroundStyle(StudioColors.danger)
        }
        .padding(.top, 4)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Captures.Todo, Value>, _ todo: Captures.Todo) -> Binding<Value> {
        Binding(get: { (captures.todo(id) ?? todo)[keyPath: keyPath] },
                set: { value in captures.update(id) { $0[keyPath: keyPath] = value } })
    }
}

/// Chips, then a field: Enter adds, × or Backspace in the empty field removes; suggestions from tags already used.
private struct TodoTagsField: View {
    @ObservedObject private var captures = CaptureStore.shared
    let todo: Captures.Todo
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowRow(spacing: 5) {
                ForEach(todo.tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text(tag).font(.studio(11, .medium))
                        Button { captures.update(todo.id) { $0.removeTag(tag) } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(tag)")
                    }
                    .foregroundStyle(StudioColors.body)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(StudioColors.chip))
                }
                TextField(todo.tags.isEmpty ? "Add a tag" : "", text: $text)
                    .textFieldStyle(.plain)
                    .font(.studio(12.5))
                    .frame(minWidth: 70)
                    .onSubmit { add(text) }
                    .onKeyPress(.delete) {
                        guard text.isEmpty, let last = todo.tags.last else { return .ignored }
                        captures.update(todo.id) { $0.removeTag(last) }
                        return .handled
                    }
            }
            let suggestions = Captures.allTags(captures.todos)
                .filter { !todo.tags.contains($0) && !text.isEmpty && $0.localizedCaseInsensitiveContains(text) }
                .prefix(5)
            if !suggestions.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(suggestions), id: \.self) { tag in
                        Button(tag) { add(tag) }.buttonStyle(.link).font(.studio(11.5))
                    }
                }
            }
        }
    }

    private func add(_ tag: String) {
        captures.update(todo.id) { $0.addTag(tag) }
        text = ""
    }
}

/// The checklist: "2 of 5", rows (tick, click to rename, ×, drag to reorder), then the add field.
private struct TodoSubitems: View {
    @ObservedObject private var captures = CaptureStore.shared
    let todo: Captures.Todo
    @State private var newText = ""
    @State private var renaming: UUID?
    @State private var renameText = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Sub-items")
                Spacer()
                let progress = todo.progress
                if progress.total > 0 {
                    Text("\(progress.done) of \(progress.total)").font(.studioMono(11)).foregroundStyle(StudioColors.muted)
                }
            }
            ForEach(todo.subitems) { item in
                row(item)
                    .draggable(item.id.uuidString)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let moved = ids.first.flatMap(UUID.init(uuidString:)),
                              let from = todo.subitems.firstIndex(where: { $0.id == moved }),
                              let to = todo.subitems.firstIndex(where: { $0.id == item.id }) else { return false }
                        captures.update(todo.id) { $0.moveSubitems(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
                        return true
                    }
            }
            HStack(spacing: 8) {
                StudioIcon(.plus, size: 12).foregroundStyle(StudioColors.coralInk).frame(width: 15)
                TextField("Add a sub-item", text: $newText)
                    .textFieldStyle(.plain)
                    .font(.studio(12.5))
                    .focused($addFocused)
                    .onSubmit {
                        captures.update(todo.id) { $0.addSubitem(newText) }
                        newText = ""
                        addFocused = true
                    }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ item: Captures.Todo.Subitem) -> some View {
        HStack(spacing: 8) {
            Button { captures.update(todo.id) { $0.toggleSubitem(item.id) } } label: {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? StudioColors.ok : StudioColors.muted)
                    .frame(width: 15)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Mark sub-item not done" : "Mark sub-item done")
            if renaming == item.id {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.studio(12.5))
                    .onSubmit { commitRename(item) }
                    .onExitCommand { renaming = nil }
            } else {
                Text(item.text)
                    .font(.studio(12.5))
                    .foregroundStyle(item.done ? StudioColors.muted : StudioColors.ink)
                    .strikethrough(item.done)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { renaming = item.id; renameText = item.text }
            }
            Button { captures.update(todo.id) { $0.removeSubitem(item.id) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(StudioColors.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete sub-item")
        }
        .padding(.vertical, 3)
    }

    private func commitRename(_ item: Captures.Todo.Subitem) {
        captures.update(todo.id) { $0.renameSubitem(item.id, to: renameText) }
        renaming = nil
    }
}
