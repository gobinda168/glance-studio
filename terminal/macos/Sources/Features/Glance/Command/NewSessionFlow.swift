import AppKit
import GlanceCore

/// Command's "New session" (spec §5, "The board"): asks which project, and whether the session gets a worktree of its
/// own; then opens a tab there with Claude running, in Glance mode. Claude starts only because this was clicked.
@MainActor
enum NewSessionFlow {
    /// Finds the repository of `window`'s folder (git runs off the main thread), then asks.
    static func start(from window: NSWindow?) {
        Task { @MainActor in
            ask(current: await NewWorktreeFlow.repository(of: window), near: window)
        }
    }

    private static func ask(current: RepoLocation?, near window: NSWindow?) {
        guard let (roots, selected) = NewWorktreeFlow.choices(current: current, emptyTitle: "No project to start a session in")
        else { return }
        let alert = NSAlert()
        alert.messageText = "New Claude session"
        alert.informativeText = "Pick the project. A new worktree gets its own folder and branch, named after the task."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        picker.addItems(withTitles: roots.map { ($0 as NSString).abbreviatingWithTildeInPath })
        if let selected { picker.selectItem(at: selected) }
        picker.setAccessibilityLabel("Project")
        let box = NSButton(checkboxWithTitle: "Make a new worktree", target: nil, action: nil)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "What's the task? Fix the shell tests"
        field.setAccessibilityLabel("Task, names the worktree and its branch")
        field.isEnabled = false
        // The task is asked for only when there is a worktree to name.
        let toggle = TaskToggle(field: field)
        box.target = toggle
        box.action = #selector(TaskToggle.changed(_:))
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 24 * 3 + 16))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [picker, box, field] { stack.addArrangedSubview(view) }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = picker
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        // The box's target is weak: `toggle` must outlive the modal.
        let response = withExtendedLifetime(toggle) { alert.runModal() }
        guard response == .alertFirstButtonReturn, picker.indexOfSelectedItem >= 0 else { return }
        let root = roots[picker.indexOfSelectedItem]
        guard box.state == .on else {
            if !SessionInput.newSessionTab(folder: root, beside: window) {
                NewWorktreeFlow.report("Couldn't start the session", "That folder isn't there any more.")
            }
            return
        }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        NewWorktreeFlow.create(in: root, task: name) { SessionInput.newSessionTab(folder: $0, beside: window) }
    }
}

/// Ticking "Make a new worktree" enables the task field and moves the cursor into it.
@MainActor
private final class TaskToggle: NSObject {
    private let field: NSTextField

    init(field: NSTextField) { self.field = field }

    @objc func changed(_ box: NSButton) {
        field.isEnabled = box.state == .on
        if box.state == .on { field.window?.makeFirstResponder(field) }
    }
}
