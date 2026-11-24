import AppKit
import GlanceCore

/// Lists a repository's merged, clean worktrees with checkboxes and removes the ticked ones (`git worktree remove`
/// refuses a dirty tree, `git branch -d` an unmerged branch). Remote branches are untouched.
@MainActor
enum RemoveMergedFlow {
    /// Asks which of `repo`'s merged worktrees to remove (none ticked to start with, except `only`, the one the user chose
    /// from its own row, which the title names), then removes those off the main thread and reports any failure. Either
    /// way nothing goes until the user presses Remove.
    static func start(repo: RepoTree, only: String? = nil, from window: NSWindow?) {
        let merged = repo.worktrees.filter { $0.merged && !$0.isMain }
        guard !merged.isEmpty else { return }
        let alert = NSAlert()
        let chosen = merged.first { $0.path == only }
        alert.messageText = chosen.map { "Remove the merged worktree \($0.name) of \(repo.name)" }
            ?? "Remove merged worktrees of \(repo.name)"
        alert.informativeText = "Tick the ones to remove. Each is merged and has no uncommitted changes. Its folder "
            + "and local branch go; the folder's ignored files, such as .env, build output and node_modules, are "
            + "deleted too."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let boxes = merged.map { tree -> NSButton in
            let box = NSButton(checkboxWithTitle: "\(tree.name) (\(tree.branch ?? "detached"))", target: nil, action: nil)
            box.state = tree.path == only ? .on : .off
            stack.addArrangedSubview(box)
            return box
        }
        let fitting = stack.fittingSize
        stack.setFrameSize(NSSize(width: max(360, fitting.width), height: fitting.height))
        alert.accessoryView = stack
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ticked = zip(merged, boxes).filter { $0.1.state == .on }.map { (path: $0.0.path, branch: $0.0.branch) }
        guard !ticked.isEmpty else { return }
        let mainRoot = repo.main
        Task { @MainActor in
            // Deleting the folders can take a while (node_modules): off the main thread.
            let failures = await Task.detached(priority: .userInitiated) {
                ticked.compactMap { WorktreeActions.remove(worktree: $0.path, branch: $0.branch, mainRoot: mainRoot)?.message }
            }.value
            WorktreesModel.shared.refresh()
            guard !failures.isEmpty else { return }
            let error = NSAlert()
            error.messageText = "Some worktrees weren't removed"
            error.informativeText = failures.joined(separator: "\n")
            error.runModal()
        }
    }
}
