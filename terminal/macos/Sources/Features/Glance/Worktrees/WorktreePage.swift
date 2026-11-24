import AppKit
import GlanceCore
import SwiftUI

/// A worktree's uncommitted changes grouped by who made them, with the actions on them (spec §3).
struct WorktreePage: View {
    let path: String
    @ObservedObject private var model = WorktreesModel.shared
    @State private var window: NSWindow?
    @State private var message: String?
    /// A commit, move or remove is running: the action buttons wait for it.
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Outside the `if let`: a failure that leaves the worktree gone must still be seen.
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(StudioColors.danger) }
                if let tree = model.worktree(path) {
                    header(tree)
                    ForEach(groups(tree)) { group in groupView(group, tree: tree) }
                    if tree.files.isEmpty { Text("No uncommitted changes.").foregroundStyle(StudioColors.muted) }
                } else {
                    Text("This worktree is gone.").foregroundStyle(StudioColors.muted)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .background(StudioColors.background)
        .background(WindowAccessor { window = $0 })
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    struct ChangeGroup: Identifiable {
        /// Stable across refreshes and unique even when two sessions have the same name.
        var id: String
        var title: String
        var files: [AttributedFile]
        var session: String?
    }

    private func groups(_ tree: WorktreeInfo) -> [ChangeGroup] {
        var order: [Author] = []
        var files: [Author: [AttributedFile]] = [:]
        for file in tree.files {
            if files[file.author] == nil { order.append(file.author) }
            files[file.author, default: []].append(file)
        }
        return order.map { author in
            switch author {
            case .session(let id):
                let task = tree.sessions.first { $0.id == id }?.task
                return ChangeGroup(id: id, title: SessionName.of(id, task: task), files: files[author] ?? [], session: id)
            case .outside:
                return ChangeGroup(id: "outside", title: "Outside Claude", files: files[author] ?? [], session: nil)
            case .ambiguous(let ids):
                return ChangeGroup(id: "ambiguous:" + ids.joined(separator: ","), title: "Ambiguous (sessions at once)", files: files[author] ?? [], session: nil)
            }
        }
    }

    private func header(_ tree: WorktreeInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tree.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(StudioColors.ink)
            Text("\(tree.branch ?? "detached") · \(tree.path)").font(.system(size: 12)).foregroundStyle(StudioColors.muted)
            HStack(spacing: 8) {
                Button("Open a terminal here") { WorktreeTerminal.open(in: tree.path, claude: false, near: window) }
                Button("Start Claude here") { WorktreeTerminal.open(in: tree.path, claude: true, near: window) }
                if tree.merged, !tree.isMain {
                    Button("Remove worktree") { remove(tree) }.disabled(busy)
                }
            }
        }
    }

    private func groupView(_ group: ChangeGroup, tree: WorktreeInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(group.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioColors.ink)
                Text(Self.count(group.files.count)).font(.system(size: 12)).foregroundStyle(StudioColors.muted)
                Spacer()
                if group.session != nil {
                    Button("Commit these…") { commit(group, tree: tree) }.disabled(busy)
                    Button("Move to a new worktree") { move(group, tree: tree) }.disabled(busy)
                }
            }
            ForEach(group.files, id: \.path) { file in
                Button {
                    EditorTabs.open(.razor, root: tree.path, from: window)?.openFile(file.path, line: nil, column: nil)
                } label: {
                    HStack(spacing: 8) {
                        Text(file.status).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioColors.muted)
                        Text(file.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(StudioColors.body)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioColors.card))
    }

    private static func count(_ files: Int) -> String { files == 1 ? "1 file" : "\(files) files" }

    /// Runs `work` (git, which can take a while on a big worktree) off the main thread with the action buttons
    /// disabled, then hands its result to `done` on the main actor and refreshes the worktrees.
    private func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value,
                                      done: @escaping @MainActor (Value) -> Void) {
        busy = true
        Task { @MainActor in
            let value = await Task.detached(priority: .userInitiated) { work() }.value
            busy = false
            done(value)
            model.refresh()
        }
    }

    private func commit(_ group: ChangeGroup, tree: WorktreeInfo) {
        let alert = NSAlert()
        alert.messageText = "Commit \(group.title)'s \(Self.count(group.files.count))"
        alert.informativeText = group.files.map(\.path).joined(separator: "\n")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Commit message"
        alert.accessoryView = field
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            message = "Enter a commit message."
            return
        }
        let worktree = tree.path
        let files = group.files.map(\.path)
        run({ WorktreeActions.commit(worktree: worktree, files: files, message: text)?.message }) { message = $0 }
    }

    private func move(_ group: ChangeGroup, tree: WorktreeInfo) {
        let alert = NSAlert()
        alert.messageText = "Move \(group.title)'s changes to a new worktree?"
        alert.informativeText = "A new worktree is made from this one's HEAD, the changes to \(Self.count(group.files.count)) go there, and they're restored here."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let files = group.files
        let worktree = tree.path
        let task = group.title
        let session = group.session
        run({ WorktreeActions.move(files: files, from: worktree, task: task) }) { result in
            switch result {
            case .success(let made):
                message = nil
                WorktreeTerminal.open(in: made.path, claude: true, resume: session, near: window)
            case .failure(let failure):
                message = failure.message
            }
        }
    }

    private func remove(_ tree: WorktreeInfo) {
        guard let repo = model.repos.first(where: { $0.worktrees.contains { $0.path == tree.path } }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the worktree \(tree.name)?"
        alert.informativeText = "\(tree.path)\nBranch: \(tree.branch ?? "detached")\n\n"
            + "Its folder is deleted, including ignored files such as .env, build output and node_modules. "
            + "The local branch is deleted only if it's merged."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let worktree = tree.path
        let branch = tree.branch
        let mainRoot = repo.main
        run({ WorktreeActions.remove(worktree: worktree, branch: branch, mainRoot: mainRoot) }) { failure in
            message = failure?.message
            // A page for a removed worktree is of no use; on a failure it stays so the message can be read.
            if failure == nil { window?.close() }
        }
    }
}
