import AppKit
import GlanceCore
import GlanceKit

/// What an ended session's card, or a closed worktree row, opens: its recap, in a tab with the Glance view (spec §5
/// "Clicking a worktree"). Nothing here runs Claude or creates anything: a removed worktree is only recreated by the
/// recap's own button.
@MainActor
enum BoardRecap {
    /// An ended card opens its worktree's recap; a session outside any worktree has none, so its transcript opens.
    static func open(_ card: BoardCard, from window: NSWindow?) {
        guard let path = card.worktree,
              let row = BoardWorktrees.rows(trees: WorktreesModel.shared.repos).first(where: { BoardWorktrees.key($0.path) == BoardWorktrees.key(path) })
                ?? mainCheckoutRow(path) else {
            BoardActions.openTranscript(card, from: window)
            return
        }
        open(worktree: row, from: window)
    }

    /// The main checkout has no Closed row, but its ended cards still have a recap.
    private static func mainCheckoutRow(_ path: String) -> BoardWorktree? {
        for repo in WorktreesModel.shared.repos {
            guard let tree = repo.worktrees.first(where: { BoardWorktrees.key($0.path) == BoardWorktrees.key(path) }) else { continue }
            let newestFirst = tree.sessions.sorted { ($0.ended ?? $0.started, $1.id) > ($1.ended ?? $1.started, $0.id) }
            return BoardWorktree(path: tree.path, branch: tree.branch, project: repo.name, repo: repo.repo, main: repo.main,
                                 live: !tree.live.isEmpty, exists: true, lastActive: newestFirst.first.map { $0.ended ?? $0.started },
                                 sessions: newestFirst.map(\.id))
        }
        return nil
    }

    /// One recap tab per worktree: an open one comes forward. A removed worktree's tab opens in the main checkout.
    static func open(worktree row: BoardWorktree, from window: NSWindow?) {
        let key = BoardWorktrees.key(row.path)
        if let open = TerminalController.all.first(where: { $0.existingGlanceSession?.recap.map { BoardWorktrees.key($0.worktree) } == key }),
           let tab = open.window {
            // Select, then makeKey: ordering a tab front in native full screen sends the window off its Space.
            tab.tabGroup?.selectedWindow = tab
            tab.makeKey()
            GlanceMode.set(true, in: open)
            return
        }
        let cards = BoardModel.shared.cards
        let newest = row.sessions.first.flatMap { id in cards.first { $0.id == id } }
        let input = RecapLoader.Input(worktree: row.path, exists: row.exists, branch: row.branch, main: row.main, sessions: row.sessions,
                                      title: newest?.title ?? row.branch ?? URL(fileURLWithPath: row.path).lastPathComponent,
                                      // The newest session that has a PR: a later one on the branch may not have looked it up.
                                      pr: row.sessions.lazy.compactMap { id in cards.first { $0.id == id }?.pr }.first)
        guard let controller = SessionInput.blankTab(folder: row.exists ? row.path : row.main, beside: window) else {
            BoardModel.shared.notice = "Couldn't open a tab there."
            return
        }
        // The tab shows straight away; what is slow (git, `gh`, summaries, the transcripts' spend) fills in.
        let model = controller.glanceSessionModel()
        // Seeded with what the row already knows, so the proof panel can find the session and a removed worktree its branch
        // while the rest is read.
        var placeholder = WorktreeRecap(worktree: row.path, title: input.title, exists: row.exists)
        placeholder.sessions = Array(row.sessions.prefix(RecapText.sessionsRead))
        placeholder.branch = row.branch
        placeholder.main = row.main
        placeholder.pr = input.pr
        model.showRecap(placeholder)
        GlanceMode.set(true, in: controller)
        // It came to the front before it showed a recap, so its strip item is worked out again now that it does.
        if let tab = controller.window { TabSidebarModel.shared.frontChanged(tab) }
        model.loadRecap(input)
    }
}
