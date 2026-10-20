import GlanceCore
import GlanceKit
import SwiftUI

/// The To-dos page for the side bar's group (or All): Board (To do · Doing · Done) or List, and the selected to-do's
/// details on the right.
struct TodosPage: View {
    enum Layout: String { case board, list }

    @ObservedObject private var captures = CaptureStore.shared
    @ObservedObject private var navigation = CapturesNavigation.shared
    @AppStorage("glance.todos.view") private var layout = Layout.board

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    JournalPageHeader(title: captures.group(navigation.todoGroup)?.name ?? "To-dos",
                                      subtitle: "Kept on this Mac. Add them here, or from selected text with Ask Claude.") {
                        SegmentedTabs(items: [SegmentItem(value: Layout.board, title: "Board", count: nil),
                                              SegmentItem(value: .list, title: "List", count: nil)],
                                      selection: $layout)
                            .fixedSize()
                    }
                    switch layout {
                    case .board: TodoBoard(now: context.date)
                    case .list: TodoList(now: context.date)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let id = navigation.selectedTodo, captures.todo(id) != nil {
                    Divider().overlay(StudioColors.line)
                    TodoDetails(id: id)
                        .frame(width: 340)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(StudioColors.bar)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: navigation.selectedTodo)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            guard navigation.selectedTodo != nil else { return .ignored }
            navigation.select(nil)
            return .handled
        }
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .onChange(of: captures.todos) {
            // The selected to-do was deleted somewhere: close its panel.
            if let id = navigation.selectedTodo, captures.todo(id) == nil { navigation.select(nil) }
        }
    }

    /// ↑/↓ while a to-do is open: the one above or below it in its column (Board) or in the list.
    private func step(_ delta: Int) -> KeyPress.Result {
        guard let id = navigation.selectedTodo, let todo = captures.todo(id) else { return .ignored }
        let shown = Captures.inGroup(captures.todos, navigation.todoGroup)
        let list = layout == .board ? Captures.column(shown, todo.status) : Captures.ordered(shown)
        guard let index = list.firstIndex(where: { $0.id == id }), list.indices.contains(index + delta) else {
            return .handled
        }
        navigation.select(list[index + delta].id)
        return .handled
    }
}

/// The list: add field, then open to-dos newest first and done ones after, each with its status and meta line.
struct TodoList: View {
    @ObservedObject private var captures = CaptureStore.shared
    @ObservedObject private var navigation = CapturesNavigation.shared
    let now: Date
    @State private var newTodo = ""

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    StudioIcon(.plus, size: 14).foregroundStyle(StudioColors.coralInk)
                    TextField("Add a to-do", text: $newTodo)
                        .textFieldStyle(.plain)
                        .font(.studio(13))
                        .foregroundStyle(StudioColors.ink)
                        .onSubmit {
                            try? captures.addTodo(newTodo, source: nil, group: navigation.todoGroup)
                            newTodo = ""
                        }
                        .accessibilityLabel("Add a to-do")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(StudioColors.field))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(StudioColors.line))

                let list = Captures.ordered(Captures.inGroup(captures.todos, navigation.todoGroup))
                if list.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No to-dos yet.").font(.studio(14, .semibold)).foregroundStyle(StudioColors.ink)
                        Text("Select text anywhere, right-click → Ask Glance…, and add one.")
                            .font(.studio(12.5)).foregroundStyle(StudioColors.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line))
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { todo in
                            row(todo)
                            if todo.id != list.last?.id { Divider().overlay(StudioColors.line) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line))
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private func row(_ todo: Captures.Todo) -> some View {
        let selected = navigation.selectedTodo == todo.id
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            TodoTick(todo: todo)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(todo.text)
                        .font(.studio(13.5))
                        .foregroundStyle(todo.done ? StudioColors.muted : StudioColors.ink)
                        .strikethrough(todo.done)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TodoMetaLine(todo: todo, now: now, group: navigation.todoGroup == nil ? captures.group(todo.group)?.name : nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TodoStatusMenu(todo: todo)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(selected ? StudioColors.selection.padding(.horizontal, -12) : nil)
        .onTapGesture { navigation.select(todo.id) }
        .contextMenu { TodoMenu(todo: todo) }
    }
}
