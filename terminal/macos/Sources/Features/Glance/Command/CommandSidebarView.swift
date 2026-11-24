import AppKit
import GlanceCore
import SwiftUI

/// The Command side bar (spec 2026-11-01-command-center-design.md §5 "Where"; the replica's `side(side)`): project
/// filters for the board, then the worktrees Claude runs in, live ones first and the closed ones after with their age.
struct CommandSidebarView: View {
    @ObservedObject private var model = BoardModel.shared
    @ObservedObject private var worktrees = WorktreesModel.shared
    @State private var window: NSWindow?
    @State private var watching = false

    var body: some View {
        let rows = BoardWorktrees.rows(trees: worktrees.repos)
        let live = rows.filter(\.live)
        let closed = rows.filter { !$0.live }
        // By comparable path: the ledger's folder may carry a trailing slash or /private where the row's doesn't.
        let byWorktree = Dictionary(grouping: model.cards.filter { $0.worktree != nil }, by: { BoardWorktrees.key($0.worktree ?? "") })
        let cardsByID = Dictionary(model.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projects = model.projects
        let mergeable = worktrees.repos.filter { $0.worktrees.contains { $0.merged && !$0.isMain } }
        VStack(spacing: 0) {
            SidebarHeader(title: "Command") {
                SidebarIconButton(icon: .plus, label: "New Claude session (⌥⌘N)") { NewSessionFlow.start(from: window) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SidebarSectionHead(title: "Projects", count: nil)
                    ProjectRow(icon: .layers, title: "All projects", count: model.cards.count, selected: model.filter == nil) {
                        model.filter = nil
                    }
                    ForEach(projects, id: \.name) { project in
                        ProjectRow(icon: .folder, title: project.name, count: project.count, selected: model.filter == project.name) {
                            model.filter = project.name
                        }
                    }
                    SidebarSectionHead(title: "Worktrees", count: live.count)
                    ForEach(mergeable, id: \.repo) { repo in
                        RemoveMergedRow(repo: repo, window: window)
                    }
                    if rows.isEmpty {
                        Text("Worktrees show here once a Claude session runs in a git repository.")
                            .font(.studio(12)).foregroundStyle(StudioColors.muted)
                            .padding(.horizontal, 18).padding(.vertical, 8)
                    }
                    ForEach(live) { row in
                        let cards = byWorktree[BoardWorktrees.key(row.path)] ?? []
                        let status = WorktreeStatus.of(cards)
                        WorktreeRow(row: row, status: status, sub: "\(status.words) · \(Self.shortened(row.path))", age: nil,
                                    outcome: .none, removable: removable(row), window: window) { open(row, cards: cards) }
                    }
                    if !closed.isEmpty {
                        SidebarSectionHead(title: "Closed", count: closed.count).padding(.top, 8)
                        ForEach(closed) { row in
                            let last = row.sessions.first.flatMap { cardsByID[$0] }
                            WorktreeRow(row: row, status: .closed, sub: last?.title ?? Self.shortened(row.path),
                                        age: row.lastActive.map { ClaudeProjectFolder.ago($0) },
                                        outcome: BoardWorktrees.outcome(of: last),
                                        removable: removable(row), window: window) { BoardRecap.open(worktree: row, from: window) }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            NewSessionButton { NewSessionFlow.start(from: window) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { found in
            window = found
            // Not inside the layout pass that reported the window; skipped if the bar left that window meanwhile.
            DispatchQueue.main.async { if window === found { syncWatching(found) } }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if let window, (note.object as AnyObject?) === window { syncWatching(window) }
        }
        .onDisappear { setWatching(false) }
    }

    /// A live row opens its session (what clicking its card does); with no card yet, it says so.
    private func open(_ row: BoardWorktree, cards: [BoardCard]) {
        if let card = SessionBoard.ordered(cards).first(where: { !$0.isEnded }) ?? SessionBoard.ordered(cards).first {
            BoardActions.open(card, from: window)
        } else {
            model.notice = "That session isn't on the board yet."
        }
    }

    /// A worktree git lists and has merged, other than the main checkout and one a session runs in: the repository cut
    /// down to it, so `RemoveMergedFlow` asks about this one only.
    private func removable(_ row: BoardWorktree) -> RepoTree? {
        guard row.exists, !row.live, var repo = worktrees.repos.first(where: { $0.repo == row.repo }),
              let info = repo.worktrees.first(where: { $0.path == row.path }), info.merged, !info.isMain else { return nil }
        repo.worktrees = [info]
        return repo
    }

    private static func shortened(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    // The model runs only while this bar is really on screen: a tab behind others is a window SwiftUI still calls shown.
    private func syncWatching(_ window: NSWindow?) {
        setWatching(window?.occlusionState.contains(.visible) == true)
    }

    private func setWatching(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        if on { model.start() } else { model.stop() }
    }
}

/// What a worktree row's mark says. Each state has its own shape and its word in the row: a ring waits, a filled dot
/// works, a dash is idle.
private enum WorktreeStatus {
    case waiting, working, quiet, closed

    static func of(_ cards: [BoardCard]) -> WorktreeStatus {
        let live = cards.filter { !$0.isEnded }
        if live.contains(where: \.isWaiting) { return .waiting }
        if live.contains(where: \.isWorking) { return .working }
        return .quiet
    }

    var words: String {
        switch self {
        case .waiting: "waiting for you"
        case .working: "working"
        case .quiet: "idle"
        case .closed: "closed"
        }
    }
}

// MARK: Sections and rows

/// The replica's `.open-head`: a small-caps name and, when there is one, a count.
private struct SidebarSectionHead: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack {
            Caption(title)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)").font(.studioMono(11, .medium)).foregroundStyle(StudioColors.muted)
            }
        }
        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The replica's `.cx-frow`: 30 pt, 7 pt corners; the selected one carries the selection fill and a trailing mark.
private struct ProjectRow: View {
    let icon: StudioIcons.Name
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StudioIcon(icon, size: 14).foregroundStyle(StudioColors.muted)
                Text(title)
                    .font(.studio(13, selected ? .semibold : .medium))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.studioMono(11, .medium)).foregroundStyle(StudioColors.muted)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(selected ? "Showing \(title)" : "Show only \(title)")
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "session" : "sessions")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color { selected ? StudioColors.selection : hovering ? StudioColors.hover : .clear }
}

/// A repository's merged worktrees: the old Worktrees side bar's "Remove merged…", as a row of its own.
private struct RemoveMergedRow: View {
    let repo: RepoTree
    let window: NSWindow?
    @State private var hovering = false

    var body: some View {
        let count = repo.worktrees.filter { $0.merged && !$0.isMain }.count
        Button { RemoveMergedFlow.start(repo: repo, from: window) } label: {
            HStack(spacing: 10) {
                StudioIcon(.trash, size: 14)
                Text("Remove merged… \(repo.name)").font(.studio(12, .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.studioMono(11, .medium))
            }
            .foregroundStyle(StudioColors.coralInk)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Remove the merged, clean worktrees of \(repo.name)")
        .accessibilityLabel("Remove merged worktrees of \(repo.name), \(count)")
    }
}

/// The replica's `.cx-wrow`: a status mark, the branch in mono over a sub-line (the folder, or for a closed one its last
/// session's title), and a closed one's age. Show changes and Remove sit in its menu.
private struct WorktreeRow: View {
    let row: BoardWorktree
    let status: WorktreeStatus
    let sub: String
    let age: String?
    let outcome: BoardWorktrees.Outcome
    let removable: RepoTree?
    let window: NSWindow?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                mark.frame(width: 14, height: 14).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.branch ?? "detached")
                        .font(.studioMono(12, .medium))
                        .foregroundStyle(status == .closed ? StudioColors.body : StudioColors.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(sub)
                        .font(.studio(11))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let age {
                    Text(age).font(.studioMono(11, .medium)).foregroundStyle(StudioColors.muted).padding(.top, 1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(row.branch ?? "detached"), \(helpWords)\n\(row.path)")
        .contextMenu { if row.exists { menu } }
        .accessibilityLabel("\(row.branch ?? "detached"), \(helpWords)\(age.map { ", \($0) ago" } ?? ""), \(sub)")
        .accessibilityAddTraits(.isButton)
        .accessibilityActions { if row.exists { menu } }
    }

    @ViewBuilder private var menu: some View {
        Button("Show changes") { WorktreeTabController.open(path: row.path, from: window) }
        if let removable { Button("Remove worktree…") { RemoveMergedFlow.start(repo: removable, only: row.path, from: window) } }
    }

    /// The state in words, and a closed worktree's last proof.
    private var helpWords: String {
        switch outcome {
        case .passed: status.words + ", its checks passed"
        case .failed: status.words + ", a check failed"
        case .none: status.words
        }
    }

    /// A closed worktree's last proof: a green check in a circle when its checks passed, a red cross in a square when one
    /// failed, and nothing when there is no proof.
    @ViewBuilder private var closedBadge: some View {
        switch outcome {
        case .passed:
            ZStack {
                Circle().fill(StudioColors.okFill)
                StudioIcon(.check, size: 9, weight: 3).foregroundStyle(StudioColors.ok)
            }
            .frame(width: 14, height: 14)
        case .failed:
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(StudioColors.dangerFill)
                StudioIcon(.close, size: 9, weight: 3).foregroundStyle(StudioColors.danger)
            }
            .frame(width: 14, height: 14)
        case .none:
            Color.clear.frame(width: 14, height: 14)
        }
    }

    /// A ring while a card waits, a teal dot while one works, a muted dash when idle; once closed, its last proof.
    @ViewBuilder private var mark: some View {
        switch status {
        case .waiting: Circle().strokeBorder(StudioColors.amber, lineWidth: 2).frame(width: 8, height: 8)
        case .working: Circle().fill(StudioColors.tealInk).frame(width: 8, height: 8)
        case .quiet: Capsule().fill(StudioColors.muted).frame(width: 8, height: 3)
        case .closed: closedBadge
        }
    }
}

/// The foot's coral button across the bottom over a hairline: the shared `SidebarPrimaryButton`, with its key hint at
/// 11 pt (the shared one is 10.5).
private struct NewSessionButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                StudioIcon(.plus, size: 16)
                Text("New session").font(.studio(12, .semibold))
                Spacer(minLength: 4)
                Text("⌥⌘N")
                    .font(.studioMono(11, .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(StudioColors.onCoral.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(StudioColors.onCoral.opacity(0.2), lineWidth: 1))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(StudioColors.onCoral)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? StudioColors.coralHover : StudioColors.coral))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New Claude session (⌥⌘N)")
        .accessibilityLabel("New session")
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line).frame(height: 1) }
    }
}
