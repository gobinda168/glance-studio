import GlanceCore
import GlanceKit
import SwiftUI

/// A to-do's tick: ticking sends it to Done, unticking back to To do.
struct TodoTick: View {
    @ObservedObject private var captures = CaptureStore.shared
    let todo: Captures.Todo
    var size: CGFloat = 15

    var body: some View {
        Button { captures.toggle(todo) } label: {
            Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size))
                .foregroundStyle(todo.done ? StudioColors.ok : StudioColors.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(todo.done ? "Mark not done" : "Mark done")
    }
}

/// High coral, Medium amber, Low muted; None draws nothing.
struct TodoPriorityMark: View {
    let priority: Captures.Todo.Priority

    var body: some View {
        if priority != .none {
            HStack(spacing: 4) {
                Image(systemName: "flag.fill").font(.system(size: 9))
                Text(priority.title).font(.studio(11, .medium))
            }
            .foregroundStyle(color)
            .accessibilityLabel("\(priority.title) priority")
        }
    }

    private var color: Color {
        switch priority {
        case .high: StudioColors.coralInk
        case .medium: StudioColors.amber
        case .low, .none: StudioColors.muted
        }
    }
}

/// What is set on a to-do, in one line: priority, due, tags (3, then +N), sub-items "2/5" with a bar, a link glyph.
struct TodoMetaLine: View {
    let todo: Captures.Todo
    let now: Date
    /// Its group's name, shown under All.
    var group: String?

    var body: some View {
        let progress = todo.progress
        if group != nil || todo.priority != .none || todo.due != nil || !todo.tags.isEmpty || progress.total > 0
            || todo.link != nil {
            HStack(spacing: 8) {
                if let group {
                    HStack(spacing: 3) {
                        Image(systemName: "folder").font(.system(size: 9))
                        Text(group).font(.studio(10.5, .medium))
                    }
                    .foregroundStyle(StudioColors.muted)
                    .accessibilityLabel("In \(group)")
                }
                TodoPriorityMark(priority: todo.priority)
                if let due = todo.due {
                    let late = Captures.isOverdue(todo, now: now)
                    Text(late ? "Overdue" : Captures.dueLabel(due, now: now))
                        .font(.studioMono(10.5, late ? .medium : .regular))
                        .foregroundStyle(late ? StudioColors.danger : StudioColors.muted)
                }
                ForEach(todo.tags.prefix(3), id: \.self) { tag in
                    Text(tag)
                        .font(.studio(10.5, .medium))
                        .foregroundStyle(StudioColors.body)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Capsule().fill(StudioColors.chip))
                }
                if todo.tags.count > 3 {
                    Text("+\(todo.tags.count - 3)").font(.studio(10.5)).foregroundStyle(StudioColors.muted)
                }
                if progress.total > 0 {
                    HStack(spacing: 5) {
                        Text("\(progress.done)/\(progress.total)").font(.studioMono(10.5)).foregroundStyle(StudioColors.muted)
                        Capsule().fill(StudioColors.line)
                            .frame(width: 28, height: 3)
                            .overlay(alignment: .leading) {
                                Capsule().fill(StudioColors.ok)
                                    .frame(width: 28 * CGFloat(progress.done) / CGFloat(progress.total), height: 3)
                            }
                    }
                    .accessibilityLabel("\(progress.done) of \(progress.total) sub-items done")
                }
                if todo.link != nil {
                    Image(systemName: "link").font(.system(size: 10)).foregroundStyle(StudioColors.muted)
                        .accessibilityLabel("Has a link")
                }
            }
            .lineLimit(1)
        }
    }
}

/// The list's status: a pill (To do muted, Doing amber, Done green) that sets the status from its menu.
struct TodoStatusMenu: View {
    @ObservedObject private var captures = CaptureStore.shared
    let todo: Captures.Todo

    var body: some View {
        Menu {
            ForEach(Captures.Todo.Status.allCases, id: \.self) { status in
                Button(status.title) { captures.setStatus(todo.id, status) }.disabled(status == todo.status)
            }
        } label: {
            StatePill(text: todo.status.title, tone: tone, height: 20)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Status")
        .accessibilityLabel("Status: \(todo.status.title)")
    }

    private var tone: StatePill.Tone {
        switch todo.status {
        case .todo: .neutral
        case .doing: .amber
        case .done: .ok
        }
    }
}

/// A to-do's right-click menu.
struct TodoMenu: View {
    @ObservedObject private var captures = CaptureStore.shared
    let todo: Captures.Todo

    var body: some View {
        Button("Open") { CapturesNavigation.shared.select(todo.id) }
        Menu("Move to") {
            ForEach(Captures.Todo.Status.allCases, id: \.self) { status in
                Button(status.title) { captures.setStatus(todo.id, status) }.disabled(status == todo.status)
            }
        }
        Menu("Group") {
            Button("No Group") { captures.setGroup(todo.id, nil) }.disabled(todo.group == nil)
            ForEach(captures.groups) { group in
                Button(group.name) { captures.setGroup(todo.id, group.id) }.disabled(todo.group == group.id)
            }
        }
        Menu("Priority") {
            ForEach(Captures.Todo.Priority.allCases, id: \.self) { priority in
                Button(priority.title) { captures.update(todo.id) { $0.priority = priority } }
                    .disabled(priority == todo.priority)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { captures.remove(todo) }
    }
}

/// A board card: tick, title (two lines), the meta line. Click selects it, drag moves it.
struct TodoCard: View {
    @ObservedObject private var navigation = CapturesNavigation.shared
    let todo: Captures.Todo
    let now: Date
    /// Its group's name, shown under All.
    var group: String?
    @State private var hovering = false

    private var selected: Bool { navigation.selectedTodo == todo.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TodoTick(todo: todo, size: 13)
                Text(todo.text)
                    .font(.studio(12.5, .semibold))
                    .foregroundStyle(todo.done ? StudioColors.muted : StudioColors.ink)
                    .strikethrough(todo.done)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TodoMetaLine(todo: todo, now: now, group: group).padding(.leading, 21)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(todo.done ? 0.7 : 1)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card)
            .shadow(color: .black.opacity(hovering || selected ? 0.14 : 0.06), radius: hovering ? 4 : 2, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? StudioColors.coral : hovering ? StudioColors.line3 : StudioColors.line2,
                          lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onTapGesture { navigation.select(todo.id) }
        .draggable(todo.id.uuidString)
        .contextMenu { TodoMenu(todo: todo) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(todo.text), \(todo.status.title)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
