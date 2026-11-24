import AppKit
import GlanceCore
import SwiftUI

/// The Worktrees side bar (spec 2026-10-22-multi-session-worktrees-design.md §3): repository → worktree → session.
/// A worktree row opens its page; ⚠ marks one that mixes work; idle worktrees are dimmed.
struct WorktreesSidebarView: View {
    @ObservedObject private var model = WorktreesModel.shared
    /// Observed so the pull request labels refresh when the lists load.
    @ObservedObject private var pullRequests = PullRequestsModel.shared
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(title: "Worktrees") {
                Button { NewWorktreeFlow.start(from: window) } label: {
                    StudioIcon(.plus).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("New Claude session in a new worktree (⌥⌘N)")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.repos.isEmpty {
                        Text("Worktrees show here once a Claude session runs in a git repository.")
                            .font(.system(size: 12)).foregroundStyle(StudioColors.muted).padding(12)
                    }
                    ForEach(model.repos, id: \.repo) { repo in
                        repoSection(repo)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { window = $0 })
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func repoSection(_ repo: RepoTree) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(repo.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioColors.muted)
                Spacer()
                if repo.worktrees.contains(where: \.merged) {
                    Button("Remove merged…") { RemoveMergedFlow.start(repo: repo, from: window) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(StudioColors.coralInk)
                }
            }
            .padding(.horizontal, 8).padding(.top, 4)
            ForEach(repo.worktrees, id: \.path) { tree in
                JournalSidebarRow(icon: tree.warning ? .alert : .branch, title: title(tree), detail: detail(tree),
                                  dot: tree.live.isEmpty ? nil : StudioColors.ok, selected: false) {
                    WorktreeTabController.open(path: tree.path, from: window)
                }
                .opacity(tree.live.isEmpty && tree.files.isEmpty ? 0.6 : 1)
                ForEach(tree.sessions.filter { tree.live.contains($0.id) }, id: \.id) { session in
                    Text("● \(SessionName.of(session.id, task: session.task)) · \(WorktreeWarnings.place(session.terminal))")
                        .font(.system(size: 11)).foregroundStyle(StudioColors.body).lineLimit(1)
                        .padding(.leading, 34)
                }
            }
        }
    }

    private func title(_ tree: WorktreeInfo) -> String {
        "\(tree.name) · \(tree.branch ?? "detached")"
    }

    private func detail(_ tree: WorktreeInfo) -> String {
        if tree.tooMany { return "too many changes to track" }
        var parts = ["\(tree.files.count) uncommitted"]
        if tree.added + tree.removed > 0 { parts[0] += " +\(tree.added) −\(tree.removed)" }
        if !tree.live.isEmpty { parts.append("\(tree.live.count) live") }
        if let pr = tree.branch.flatMap(WorktreePullRequest.label(branch:)) { parts.append(pr) }
        if tree.merged { parts.append("can be removed") }
        return parts.joined(separator: " · ")
    }
}

/// A worktree branch's pull request, from the pull request lists Glance already loaded (Pull Requests side bar):
/// "#123 open", "#123 draft" or "#123 merged"; nil when none is known.
@MainActor
enum WorktreePullRequest {
    static func label(branch: String) -> String? {
        for entry in PullRequestsModel.shared.entries.values {
            guard let board = entry.board else { continue }
            if let open = (board.yours + board.waitingOnYou).first(where: { $0.head == branch }) {
                return "#\(open.number) \(open.isDraft ? "draft" : "open")"
            }
            if let merged = board.recentlyMerged.first(where: { $0.head == branch }) {
                return "#\(merged.number) merged"
            }
        }
        return nil
    }
}
