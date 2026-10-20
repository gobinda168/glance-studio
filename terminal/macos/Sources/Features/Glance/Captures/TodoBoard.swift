import GlanceCore
import GlanceKit
import SwiftUI

/// To do · Doing · Done side by side. Drag a card onto another card to go just above it, or onto a column's free space
/// to go to its end; "+ Add" adds to the end of that column.
struct TodoBoard: View {
    @ObservedObject private var captures = CaptureStore.shared
    @ObservedObject private var navigation = CapturesNavigation.shared
    let now: Date

    var body: some View {
        let shown = Captures.inGroup(captures.todos, navigation.todoGroup)
        HStack(alignment: .top, spacing: 12) {
            ForEach(Captures.Todo.Status.allCases, id: \.self) { status in
                TodoColumn(status: status, todos: Captures.column(shown, status), group: navigation.todoGroup, now: now)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TodoColumn: View {
    @ObservedObject private var captures = CaptureStore.shared
    let status: Captures.Todo.Status
    let todos: [Captures.Todo]
    /// The group the board shows: new cards go in it, and a drop's index counts only its cards.
    let group: UUID?
    let now: Date
    @State private var targeted = false
    @State private var adding = false
    @State private var newText = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Caption(status.title).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(todos.count)")
                    .font(.studioMono(11, .medium))
                    .foregroundStyle(StudioColors.muted)
                    .monospacedDigit()
            }
            .frame(height: 26)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if todos.isEmpty && !adding {
                        Text(targeted ? "Drop to move here" : "Nothing here")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(StudioColors.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    ForEach(Array(todos.enumerated()), id: \.element.id) { index, todo in
                        TodoCard(todo: todo, now: now, group: group == nil ? captures.group(todo.group)?.name : nil)
                            .dropDestination(for: String.self) { ids, _ in
                                drop(ids, at: index)
                            }
                    }
                    addRow
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(targeted ? StudioColors.selection : StudioColors.chip.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(targeted ? StudioColors.coral : StudioColors.line2, lineWidth: 1))
        .animation(.easeOut(duration: 0.14), value: targeted)
        .dropDestination(for: String.self) { ids, _ in drop(ids, at: todos.count) } isTargeted: { targeted = $0 }
    }

    @ViewBuilder private var addRow: some View {
        if adding {
            TextField("New to-do", text: $newText)
                .textFieldStyle(.plain)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.ink)
                .focused($addFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.coral))
                .onSubmit {
                    try? captures.addTodo(newText, source: nil, status: status, atEnd: true, group: group)
                    newText = ""
                    addFocused = true
                }
                .onExitCommand { adding = false; newText = "" }
                .onChange(of: addFocused) { if !addFocused && newText.isEmpty { adding = false } }
                .onAppear { addFocused = true }
        } else {
            Button { adding = true } label: {
                HStack(spacing: 6) {
                    StudioIcon(.plus, size: 12)
                    Text("Add").font(.studio(12, .medium))
                }
                .foregroundStyle(StudioColors.muted)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a to-do to \(status.title)")
        }
    }

    /// Dropped ids (a card's UUID string) go to `index` in this column.
    private func drop(_ ids: [String], at index: Int) -> Bool {
        guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
        // Counted without the card itself when it moves down its own column.
        let from = todos.firstIndex { $0.id == id }
        let at = from.map { $0 < index ? index - 1 : index } ?? index
        captures.move(id, to: status, index: at, group: group)
        return true
    }
}
