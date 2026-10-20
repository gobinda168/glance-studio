import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Pull Requests side bar (spec 2026-10-08-pr-repositories-design.md, on 2026-10-07-pr-manager-design.md; tabs,
/// 2026-10-12-pr-sidebar-tabs-design.md):
/// - a repository's pull requests, one list at a time under the To review · Yours · Merged tabs: the repository picked
///   in the repository picker, for every window and across launches, else the tab's project on GitHub;
/// - the repository button with the picker (every repository on the account), the filter field and menu;
/// - with nothing picked and no project on GitHub, the picker's list at full height; signed out, the sign-in card;
/// - "Raise a pull request" at the bottom.
///
/// A click opens a pull request in its own tab here (nothing opens github.com), and the one in front is selected, its
/// list's tab shown. The lists and their "N blocking" counts come from `PullRequestsModel`: when the side bar shows, on
/// ↻, and every minute while it's open.
struct PullRequestsSidebarView: View {
    @ObservedObject private var model = PullRequestsModel.shared
    @ObservedObject private var account = GitHubAccountModel.shared
    @ObservedObject private var folders = RepositoryFoldersModel.shared
    @ObservedObject private var tabs = TabSidebarModel.shared
    @ObservedObject private var rowsChange = TabSidebarModel.shared.rowsChange // this tab's folder may have changed
    @State private var window: NSWindow?
    @State private var text = ""
    @AppStorage("pullRequestsShowsDrafts") private var showsDrafts = true
    @AppStorage("pullRequestsFailingOnly") private var failingOnly = false

    /// The project of this window's tab: a terminal's folder, an editor's root, or the terminal Home follows.
    private var ownRoot: String? {
        _ = tabs.revision
        guard let folder = (window?.windowController as? GlancePaneOwner)?.glanceDirectory, !folder.isEmpty else {
            return nil
        }
        return ProjectRoot.find(from: folder)
    }

    private var filter: PullRequests.Filter {
        PullRequests.Filter(text: text, showsDrafts: showsDrafts, failingOnly: failingOnly)
    }

    var body: some View {
        // A ZStack, not a Group: a Group's modifiers go to whichever side bar it holds, so swapping the side bar made a
        // new window accessor, and the old one's "no window" on its way out left the PR tabs without theirs.
        ZStack(alignment: .top) {
            if let tab = window?.windowController as? PullRequestWindowController {
                ReviewAwareSidebar(controller: tab) { list }
            } else if let inbox = window?.windowController as? ReviewInboxWindowController {
                InboxAwareSidebar(controller: inbox) { list }
            } else if let draft = window?.windowController as? NewPullRequestWindowController {
                DraftAwareSidebar(controller: draft) { list }
            } else {
                list
            }
        }
        .background(WindowAccessor { window = $0 })
    }

    /// The pull requests of the repository shown.
    @ViewBuilder private var list: some View {
        let ownRoot = self.ownRoot
        let thisTab = ownRoot.flatMap { folders.repository(ofFolder: $0) }
        let shown = PullRequests.shownRepository(picked: model.picked, tabProject: thisTab)
        let entry = shown.map { model.entry(for: $0) } ?? PullRequestsModel.Entry()
        let all = shown == PullRequests.allRepositories
        // Where its pull requests check out and raise: the tab's own project when it is that repository; for All
        // repositories, the tab's project when it's on GitHub.
        let root = all ? ownRoot.flatMap { thisTab == nil ? nil : $0 }
            : shown.flatMap { folders.folder(for: $0, preferring: ownRoot) }
        VStack(spacing: 0) {
            SidebarHeader(title: "Pull requests") {
                SidebarIconButton(icon: .plus, label: "Raise a Pull Request (⌥⌘P)") {
                    raise(all ? thisTab : shown, root: root)
                }
                SidebarIconButton(icon: .refresh, label: "Refresh") {
                    if let shown { model.load(shown, force: true) }
                    account.loadRepositories(force: true)
                }
                FilterMenu(showsDrafts: $showsDrafts, failingOnly: $failingOnly)
            }
            if account.state == .noGh || entry.failure == .notInstalled {
                Notice(title: "Install the GitHub CLI", detail: "The Pull Requests side bar reads GitHub with gh.",
                       command: "brew install gh") {
                    account.refresh(force: true)
                    if let shown { model.load(shown, force: true) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else if account.state == .signedOut || account.signIn != nil {
                GitHubSignInCard()
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if let shown {
                VStack(alignment: .leading, spacing: 8) {
                    RepositoryButton(shown: shown, thisTab: thisTab, window: window) { model.pick($0) }
                    if let board = entry.board {
                        FilterField(text: $text)
                        ListTabs(tabs: PullRequests.tabs(board, filter: filter), selection: $model.tab)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                if let board = entry.board {
                    let list = model.tab
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            if !all, list != .recentlyMerged, let reviews = entry.reviews {
                                let counts = ReviewInbox.counts(board.waitingOnYou + board.yours,
                                                                threads: reviews.threads, viewer: reviews.viewer)
                                ReviewCommentsRow(unresolved: counts[.unresolved] ?? 0,
                                                  blocking: counts[.blocking] ?? 0) {
                                    openInbox(board: board, root: root)
                                }
                            }
                            Rows(list: list,
                                 pullRequests: PullRequests.visible(board.pullRequests(list), in: list, filter: filter),
                                 filter: filter, threads: entry.reviews?.threads ?? [:], selected: selected(),
                                 showsRepository: all) {
                                open($0, ownRoot: ownRoot)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 12)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    if case .failed(let message) = entry.failure {
                        Notice(title: "Couldn't refresh", detail: message, command: nil) {
                            model.load(shown, force: true)
                        }
                    }
                } else {
                    Status(repository: shown, entry: entry) { model.load(shown, force: true) }
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            } else {
                // Nothing picked, and the tab's project isn't on GitHub: the picker's list, at full height.
                VStack(alignment: .leading, spacing: 0) {
                    Caption("Choose a repository")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 2)
                    RepositoryPickerList(shown: nil, thisTab: thisTab, window: window) { model.pick($0) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            if let shown, folders.work[RepositoryFolders.key(shown)] != nil {
                // Raise's clone or link of the repository: its progress, or why it failed.
                LocalFolderNotice(repository: shown, window: window)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            SidebarPrimaryButton(icon: .pullRequest, title: "Raise a pull request", hint: "⌥⌘P") {
                raise(all ? thisTab : shown, root: root)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: shown) {
            // While this side bar is on screen: now, then every minute (the model skips a load that's still fresh).
            guard let shown else { return }
            await ActivePolling.run(every: 60) { model.load(shown) }
        }
        .task(id: ownRoot) {
            // The tab's project and the recent ones, each looked up once; the account, once per launch.
            folders.find([ownRoot].compactMap { $0 } + Prefs.recentProjects.entries.map(\.path))
            account.refresh()
        }
        .onChange(of: followed(loaded: entry.board != nil), initial: true) { _, followed in
            // A pull request opened from anywhere (a link, the inbox, a notification): its list's tab. Only when the
            // pull request in front or the lists' arrival changes, so picking another tab by hand holds.
            guard let followed, let board = entry.board else { return }
            let tab = PullRequests.tab(model.tab, showing: followed.number, of: followed.repository, in: board)
            if tab != model.tab { model.tab = tab }
        }
    }

    /// What the tab shown follows: the pull request in front, and whether the lists have come.
    private struct Followed: Equatable {
        let repository: String
        let number: Int
        let loaded: Bool
    }

    private func followed(loaded: Bool) -> Followed? {
        selected().map { Followed(repository: $0.repository, number: $0.number, loaded: loaded) }
    }

    /// The pull request of this window's tab: its repository key and number.
    private func selected() -> (repository: String, number: Int)? {
        guard let tab = window?.windowController as? PullRequestWindowController else { return nil }
        return (RepositoryFolders.key(tab.key.repository), tab.key.number)
    }

    /// Opens the repository's Review comments tab in this window.
    private func openInbox(board: PullRequests.Board, root: String?) {
        ReviewInboxWindowController.open(repository: board.repository, root: root, from: window)
    }

    /// Opens a pull request in its tab in this window, with its repository's folder on this Mac.
    private func open(_ pullRequest: PullRequests.PullRequest, ownRoot: String?) {
        let repository = pullRequest.repository
        PullRequestWindowController.open(repository: repository, number: pullRequest.number,
                                         root: folders.folder(for: repository, preferring: ownRoot), from: window)
    }

    /// The repository's New pull request tab in this window (spec, "Raise"): in its folder, or once Clone… or Choose
    /// Folder… gives it one.
    private func raise(_ repository: String?, root: String?) {
        let window = self.window
        if let root {
            NewPullRequestWindowController.open(root: root, from: window)
        } else if let repository {
            folders.offerFolder(for: repository, from: window) { folder in
                NewPullRequestWindowController.open(root: folder, from: window)
            }
        } else {
            NSSound.beep()
        }
    }
}

// MARK: - Menus and the filter field

/// The header's filter button (the canvas's `.ib` funnel): a menu of what the lists show. It's coral while a choice
/// hides something.
private struct FilterMenu: View {
    @Binding var showsDrafts: Bool
    @Binding var failingOnly: Bool
    @State private var hovering = false

    var body: some View {
        let narrowed = !showsDrafts || failingOnly
        Menu {
            Toggle("Show Drafts", isOn: $showsDrafts)
            Toggle("Failing Checks Only", isOn: $failingOnly)
        } label: {
            StudioIcon(.filter, size: 16)
                .foregroundStyle(narrowed ? StudioColors.coralInk : hovering ? StudioColors.ink : StudioColors.muted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? StudioColors.hover : .clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help("Filter")
        .accessibilityLabel("Filter")
        .accessibilityValue(narrowed ? "Some pull requests hidden" : "Showing all")
    }
}

/// The filter field: title, number or author.
private struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            StudioIcon(.search, size: 14)
                .foregroundStyle(StudioColors.muted)
            TextField("Filter by title, #, author", text: $text)
                .textFieldStyle(.plain)
                .font(.studio(12))
                .foregroundStyle(StudioColors.ink)
                .accessibilityLabel("Filter pull requests")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }
}

// MARK: - The tabs and the list

/// To review · Yours · Merged, each with what the filter leaves it: the canvas's segmented track (`SegmentedTabs`)
/// across the side bar, the tab shown raised. A tab is as wide as its name and count plus an even share of the room
/// left, so no name truncates at the side bar's narrowest.
private struct ListTabs: View {
    let tabs: [PullRequests.Tab]
    @Binding var selection: PullRequests.List

    var body: some View {
        EvenRow(spacing: 2) {
            ForEach(tabs, id: \.list) { tab($0) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(StudioColors.field))
        .animation(.easeOut(duration: 0.24), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pull request lists")
    }

    private func tab(_ tab: PullRequests.Tab) -> some View {
        let selected = tab.list == selection
        // To review's count is coral while something waits on you, as the strip's badge is.
        let waiting = tab.list == .waitingOnYou && tab.count > 0
        return Button { selection = tab.list } label: {
            HStack(spacing: 5) {
                Text(tab.list.title)
                    .font(.studio(12, selected ? .semibold : .medium))
                    .lineLimit(1)
                Text("\(tab.count)")
                    .font(.studioMono(11, selected ? .semibold : .regular))
                    .foregroundStyle(waiting ? StudioColors.coralInk : selected ? StudioColors.ink : StudioColors.muted)
                    .contentTransition(.numericText())
            }
            .foregroundStyle(selected ? StudioColors.ink : StudioColors.muted)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? StudioColors.solid : .clear)
                .shadow(color: .black.opacity(selected ? 0.16 : 0), radius: 1, y: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(tab.list))
        .accessibilityLabel("\(tab.list.title), \(tab.count)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func help(_ list: PullRequests.List) -> String {
        switch list {
        case .waitingOnYou: "Waiting on your review"
        case .yours: "Your open pull requests"
        case .recentlyMerged: "Yours, merged recently"
        }
    }
}

/// Side by side across the width offered: each subview at its own width plus an even share of what's left.
private struct EvenRow: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = naturalWidth(sizes)
        let width = proposal.width.map { $0.isFinite ? max($0, natural) : natural } ?? natural
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let extra = sizes.isEmpty ? 0 : max(0, bounds.width - naturalWidth(sizes)) / CGFloat(sizes.count)
        var x = bounds.minX
        for (subview, size) in zip(subviews, sizes) {
            let width = size.width + extra
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func naturalWidth(_ sizes: [CGSize]) -> CGFloat {
        sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
    }
}

/// The tab's pull requests, or what it says with none.
private struct Rows: View {
    let list: PullRequests.List
    /// What the filter lets through.
    let pullRequests: [PullRequests.PullRequest]
    let filter: PullRequests.Filter
    /// The open pull requests' threads, by number.
    let threads: [Int: [ReviewThreads.Thread]]
    /// The pull request in front (its repository key and number), highlighted.
    let selected: (repository: String, number: Int)?
    /// All repositories: each row says its repository.
    let showsRepository: Bool
    let open: (PullRequests.PullRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if pullRequests.isEmpty {
                Text(PullRequests.emptyText(list, filter: filter))
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            ForEach(pullRequests, id: \.id) { row($0) }
        }
    }

    private func row(_ pullRequest: PullRequests.PullRequest) -> some View {
        PullRequestRow(pullRequest: pullRequest, list: list, showsRepository: showsRepository,
                       blocking: ReviewThreads.summary(threads[pullRequest.number] ?? []).blocking,
                       isSelected: selected.map {
                           $0.number == pullRequest.number && $0.repository == RepositoryFolders.key(pullRequest.repository)
                       } ?? false) {
            open(pullRequest)
        }
    }
}

/// One pull request: its title, `PullRequests.subline`, and its size, checks and blocking threads.
private struct PullRequestRow: View {
    let pullRequest: PullRequests.PullRequest
    let list: PullRequests.List
    /// All repositories: the sub-line starts with the repository.
    let showsRepository: Bool
    /// Its unresolved blocking threads.
    let blocking: Int
    /// Its tab is the one in front.
    let isSelected: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                StudioIcon(list == .recentlyMerged ? .merge : pullRequest.isDraft ? .pullRequestDraft : .pullRequest,
                           size: 16)
                    .foregroundStyle(glyph)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pullRequest.title)
                        .font(.studio(13, isSelected ? .semibold : .medium))
                        .foregroundStyle(pullRequest.isDraft ? StudioColors.body : StudioColors.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(PullRequests.subline(pullRequest, in: list, showsRepository: showsRepository))
                        .font(.studio(11.5))
                        .foregroundStyle(changesRequested ? StudioColors.danger : StudioColors.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    details
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                if isSelected {
                    // The canvas's selected row: the selection's tint and a 2 pt coral edge.
                    shape.fill(StudioColors.selection)
                        .overlay(alignment: .leading) { Rectangle().fill(StudioColors.coral).frame(width: 2) }
                        .clipShape(shape)
                } else {
                    shape.fill(hovering ? StudioColors.hover : .clear)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help("Open #\(pullRequest.number)")
        .contextMenu {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pullRequest.url, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens it in a tab")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var changesRequested: Bool {
        list == .yours && !pullRequest.isDraft && pullRequest.review == .changesRequested
    }

    private var glyph: Color {
        if list == .recentlyMerged || pullRequest.isDraft { return StudioColors.muted }
        return StudioColors.ok
    }

    /// Waiting on you: how big it is, then its blocking threads. Yours: its checks and blocking threads. Merged:
    /// nothing more.
    @ViewBuilder private var details: some View {
        switch list {
        case .waitingOnYou:
            HStack(spacing: 6) {
                Text("+\(pullRequest.additions)").foregroundStyle(StudioColors.ok)
                Text("−\(pullRequest.deletions)").foregroundStyle(StudioColors.danger)
                Text("· \(pullRequest.changedFiles) \(pullRequest.changedFiles == 1 ? "file" : "files")")
                    .foregroundStyle(StudioColors.muted)
            }
            .font(.studioMono(10.5, .medium))
            .padding(.top, 1)
            if blocking > 0 {
                BlockingChip(count: blocking)
                    .padding(.top, 2)
            }
        case .yours:
            if pullRequest.checks.summary != nil || blocking > 0 {
                HStack(spacing: 6) {
                    if let summary = pullRequest.checks.summary {
                        ChecksChip(state: pullRequest.checks.state, summary: summary)
                    }
                    if blocking > 0 {
                        BlockingChip(count: blocking)
                    }
                }
                .padding(.top, 2)
            }
        case .recentlyMerged:
            EmptyView()
        }
    }
}

/// "✓ 14/14": a pull request's checks. Green when they pass, red when one fails, amber while some still run.
private struct ChecksChip: View {
    let state: PullRequests.Checks.State
    let summary: String

    var body: some View {
        HStack(spacing: 4) {
            StudioIcon(icon, size: 11, weight: state == .passing ? 2.4 : StudioIcons.strokeWidth)
            Text(summary)
                .font(.studio(11, .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(fill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Checks \(summary), \(word)")
    }

    private var icon: StudioIcons.Name {
        switch state {
        case .passing: .check
        case .failing: .close
        case .pending, .empty: .clock
        }
    }

    private var ink: Color {
        switch state {
        case .passing: StudioColors.ok
        case .failing: StudioColors.danger
        case .pending, .empty: StudioColors.amber
        }
    }

    private var fill: Color {
        switch state {
        case .passing: StudioColors.okFill
        case .failing: StudioColors.dangerFill
        case .pending, .empty: StudioColors.chip
        }
    }

    private var word: String {
        switch state {
        case .passing: "passing"
        case .failing: "failing"
        case .pending, .empty: "running"
        }
    }
}

/// "Review comments", the way into the inbox (spec, "Navigation"; not on the canvas): its unresolved threads, and the
/// blocking ones.
private struct ReviewCommentsRow: View {
    let unresolved: Int
    let blocking: Int
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                StudioIcon(.chats, size: 16)
                    .foregroundStyle(StudioColors.muted)
                Text("Review comments")
                    .font(.studio(13, .medium))
                    .foregroundStyle(StudioColors.ink)
                Spacer(minLength: 4)
                if blocking > 0 { BlockingChip(count: blocking) }
                if unresolved > 0 {
                    Text("\(unresolved)")
                        .font(.studioMono(11))
                        .foregroundStyle(StudioColors.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? StudioColors.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help("Open Review Comments")
        .accessibilityLabel("Review comments, \(unresolved) unresolved")
    }
}

/// "2 blocking", with the chat bubble: a pull request's unresolved blocking threads, in the danger tint (the canvas's
/// row chip).
private struct BlockingChip: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            StudioIcon(.chats, size: 11)
            Text("\(count) blocking")
                .font(.studio(11, .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(StudioColors.danger)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(StudioColors.dangerFill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) blocking \(count == 1 ? "thread" : "threads")")
    }
}

// MARK: - Empty and error states

/// What the side bar shows before a repository's lists come: loading, or why they didn't, with Retry.
private struct Status: View {
    let repository: String
    let entry: PullRequestsModel.Entry
    let retry: () -> Void

    var body: some View {
        if let failure = entry.failure {
            Notice(title: repository == PullRequests.allRepositories ? "Couldn't load your pull requests"
                       : "Couldn't load \(repository)",
                   detail: failure.message, command: nil, retry: retry)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading pull requests…")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }
}

/// A short message: a title, a line of detail, an optional command to copy, and Retry.
private struct Notice: View {
    let title: String
    let detail: String
    let command: String?
    let retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.studio(12.5, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text(detail)
                .font(.studio(12))
                .foregroundStyle(StudioColors.body)
                .fixedSize(horizontal: false, vertical: true)
            if let command {
                Text(command)
                    .font(.studioMono(11.5, .medium))
                    .foregroundStyle(StudioColors.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
            }
            if let retry {
                Button("Retry", action: retry)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The side bar follows the PR tab in front: its Files page puts the changed files here; its other pages, the list.
private struct ReviewAwareSidebar<Content: View>: View {
    @ObservedObject var controller: PullRequestWindowController
    @ViewBuilder let list: () -> Content

    var body: some View {
        if controller.section == .files {
            ChangedFilesSidebar(controller: controller)
        } else {
            list()
        }
    }
}

/// The side bar of the Review comments tab: its filters, with a back row to the pull requests list.
private struct InboxAwareSidebar<Content: View>: View {
    @ObservedObject var controller: ReviewInboxWindowController
    @ViewBuilder let list: () -> Content

    var body: some View {
        if controller.sidebarShowsList {
            list()
        } else {
            ReviewInboxSidebar(controller: controller)
        }
    }
}

/// The side bar of a New pull request tab: this branch, with a back row to the pull requests list.
private struct DraftAwareSidebar<Content: View>: View {
    @ObservedObject var controller: NewPullRequestWindowController
    @ViewBuilder let list: () -> Content

    var body: some View {
        if controller.sidebarShowsList {
            list()
        } else {
            NewPullRequestSidebar(controller: controller)
        }
    }
}

extension PullRequests.PullRequest {
    /// Unique on the All repositories board too: two repositories can both have a #12.
    var id: String { RepositoryFolders.key(repository) + "#\(number)" }
}
