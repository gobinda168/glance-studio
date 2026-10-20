import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// A New pull request tab (board 3): the side bar column, the page above its create bar, the Glance pane and the status
/// bar. It reads the branch when the tab opens and whenever a menu picks another branch.
struct NewPullRequestTabView: View {
    @ObservedObject var controller: NewPullRequestWindowController
    @ObservedObject private var store = NewPullRequestStore.shared
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        let entry = store.entry(controller.root)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if tabSidebar.isOpen {
                    SidebarColumn()
                }
                HSplitView {
                    VStack(spacing: 0) {
                        NewPullRequestPage(controller: controller, entry: entry)
                        CreateBar(controller: controller, entry: entry)
                    }
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    .background(StudioColors.background)
                    .overlay(alignment: .bottomTrailing) {
                        if controller.glancePaneOpen && controller.glancePlacement == .floating {
                            GlanceFloatView()
                        }
                    }
                    if controller.glancePaneOpen && controller.glancePlacement == .sidebar {
                        GlancePaneView()
                            .glanceSidebar()
                    }
                }
            }
            .glancePlacement($controller.glancePlacement)
            .activityStrip()
            NewPullRequestStatusBar(controller: controller, entry: entry)
        }
        .task(id: "\(controller.base ?? "")\u{0}\(controller.branch ?? "")") {
            store.load(root: controller.root, base: controller.base, branch: controller.branch)
        }
        .task { ReviewInboxStore.shared.checkClaude() }
        .onChange(of: entry.compare.commits) { _, commits in
            controller.prefill(title: BranchCompare.defaultTitle(commits))
        }
        .onChange(of: entry.loading) { _, loading in
            // Claude's first draft, once the branch is read (spec: it fills empty fields when the tab opens).
            guard loading == .ready, ReviewInboxStore.shared.claudeInstalled != false else { return }
            controller.draft(store.entry(controller.root).compare, redraft: false)
        }
    }
}

/// The canvas's status bar under a New pull request tab: the project's branch, how it stands against GitHub's copy
/// (↑ to push, ↓ to pull), and Claude's state.
struct NewPullRequestStatusBar: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let entry: NewPullRequestStore.Entry
    @ObservedObject private var agents = AgentsActivity.shared
    @ObservedObject private var inbox = ReviewInboxStore.shared

    var body: some View {
        HStack(spacing: 14) {
            if let branch = GitHead.branch(inFolder: controller.root) {
                BranchChip(branch, size: 11)
            }
            if !entry.compare.branch.isEmpty {
                Text(Self.sync(entry.compare.pushed))
            }
            Spacer(minLength: 8)
            if inbox.claudeInstalled == false {
                Text("Claude Code isn't installed")
            } else if agents.isRunning {
                HStack(spacing: 6) {
                    TealDot(size: 8)
                    Text("Claude working").foregroundStyle(StudioColors.tealInk)
                }
            } else {
                HStack(spacing: 6) {
                    CoralDot(size: 8)
                    Text("Claude ready")
                }
            }
        }
        .font(.studio(11.5))
        .foregroundStyle(StudioColors.muted)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(StudioColors.bar)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line).frame(height: 1) }
    }

    /// "↑2 ↓0", or "Not on GitHub yet".
    static func sync(_ pushed: BranchCompare.Pushed) -> String {
        switch pushed {
        case .current: "↑0 ↓0"
        case .ahead(let ahead, behind: let behind): "↑\(ahead) ↓\(behind)"
        case .notPushed: "Not on GitHub yet"
        }
    }
}

/// The New pull request page (board 3): "Raise a pull request", the compare bar, then the form beside the reviewers,
/// the labels and what happens after creating.
struct NewPullRequestPage: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let entry: NewPullRequestStore.Entry

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Raise a pull request")
                    .font(.studio(22, .bold))
                    .tracking(-0.22)
                    .foregroundStyle(StudioColors.ink)
                    .padding(.bottom, 14)
                if case .failed(let message) = entry.loading {
                    InlineError(message: message) {
                        NewPullRequestStore.shared.load(root: controller.root, base: controller.base,
                                                        branch: controller.branch)
                    }
                    .padding(.bottom, 12)
                }
                if entry.compare.branch.isEmpty {
                    if entry.loading == .loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading the branch…").font(.studio(12)).foregroundStyle(StudioColors.muted)
                        }
                    }
                } else {
                    CompareBar(controller: controller, entry: entry)
                    if controller.showingDiff {
                        ReadOnlyDiff(controller: controller, files: entry.compare.diff,
                                     subject: .branch(head: entry.compare.branch, base: entry.compare.base),
                                     repository: entry.compare.repository)
                            .padding(.top, 20)
                    } else {
                        OverviewColumns {
                            NewPullRequestForm(controller: controller, entry: entry)
                            NewPullRequestMeta(controller: controller, entry: entry)
                        }
                        .padding(.top, 20)
                    }
                }
            }
            .frame(maxWidth: 1060, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The compare bar (board 3): the base and compare branch menus, whether it merges, and what the branch adds.
struct CompareBar: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let entry: NewPullRequestStore.Entry

    var body: some View {
        let compare = entry.compare
        let totals = BranchCompare.totals(compare.files)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 10) {
            StudioIcon(.pullRequest, size: 16).foregroundStyle(StudioColors.muted)
            BranchMenu(label: "base", branch: compare.base, branches: compare.bases) { controller.base = $0 }
            StudioIcon(.arrowLeft, size: 14).foregroundStyle(StudioColors.muted)
            BranchMenu(label: "compare", branch: compare.branch, branches: compare.branches) { controller.branch = $0 }
            mergeState(compare.merge)
            Spacer(minLength: 8)
            if entry.loading == .loading { ProgressView().controlSize(.mini) }
            HStack(spacing: 4) {
                Text(BranchCompare.countsLine(commits: compare.commits.count, files: compare.files.count) + " ·")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                Text("+\(totals.additions)").font(.studioMono(11.5)).foregroundStyle(StudioColors.ok)
                Text("−\(totals.deletions)").font(.studioMono(11.5)).foregroundStyle(StudioColors.danger)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(shape.fill(StudioColors.card))
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.rim).frame(height: 1).padding(.horizontal, 10) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(StudioColors.line, lineWidth: 1))
    }

    @ViewBuilder private func mergeState(_ merge: BranchCompare.Merge) -> some View {
        switch merge {
        case .clean:
            HStack(spacing: 5) {
                StudioIcon(.check, size: 13, weight: 2.2)
                Text("Able to merge")
            }
            .font(.studio(12, .semibold))
            .foregroundStyle(StudioColors.ok)
        case .conflicts(let files):
            HStack(spacing: 5) {
                StudioIcon(.close, size: 13, weight: 2.2)
                Text(files.count == 1 ? "Conflicts in 1 file" : "Conflicts in \(files.count) files")
            }
            .font(.studio(12, .semibold))
            .foregroundStyle(StudioColors.danger)
        case .unknown:
            EmptyView()
        }
    }
}

/// A branch menu (the canvas's `.btn`): "base" or "compare" in DM Sans, the branch in mono, and a chevron.
struct BranchMenu: View {
    let label: String
    let branch: String
    let branches: [String]
    let choose: (String) -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            if branches.isEmpty { Text("No other branches") }
            ForEach(branches, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { name == branch }, set: { _ in choose(name) }))
            }
        } label: {
            HStack(spacing: 6) {
                Text(label).font(.studio(11.5)).foregroundStyle(StudioColors.muted)
                Text(branch).font(.studioMono(11.5)).foregroundStyle(StudioColors.ink).lineLimit(1)
                StudioIcon(.chevronDown, size: 12).foregroundStyle(StudioColors.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel("\(label.capitalized) branch: \(branch)")
    }
}

/// The form (board 3): the title, and the description rendered as it's typed (`LiveMarkdownEditor`).
struct NewPullRequestForm: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let entry: NewPullRequestStore.Entry
    @ObservedObject private var inbox = ReviewInboxStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Caption("Title")
                StudioField(placeholder: "Title", text: $controller.title, height: 38, font: .studio(14, .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Caption("Description")
                    Spacer(minLength: 8)
                    redraft
                }
                description
                if let error = controller.draftError {
                    InlineError(message: "Claude couldn't draft it: \(error)") {
                        controller.draft(entry.compare, redraft: true)
                    }
                }
            }
            FilesChangedList(controller: controller, files: entry.compare.files)
        }
        .confirmationDialog("Replace your title and description?", isPresented: Binding(
            get: { controller.waitingDraft != nil }, set: { if !$0 { controller.waitingDraft = nil } })) {
            Button("Replace") {
                if let draft = controller.waitingDraft { controller.apply(draft, replacing: true) }
            }
            Button("Keep Mine", role: .cancel) { controller.waitingDraft = nil }
        } message: {
            Text("Claude has a new draft. What you wrote goes if you replace it.")
        }
    }

    /// Redraft with Claude (⌘I, the page's glow ring).
    private var redraft: some View {
        let claude = inbox.claudeInstalled != false
        return GlowPill(title: "Redraft with Claude", hint: "⌘I", busy: controller.drafting,
                        enabled: claude && !controller.drafting && !entry.compare.commits.isEmpty) {
            controller.draft(entry.compare, redraft: true)
        }
        .keyboardShortcut("i", modifiers: .command)
        .help(claude ? "Claude drafts the title and description again from the commits and the diff (⌘I)"
              : "Install Claude Code to draft with Claude")
    }

    /// The canvas's note under a drafted description: the note's tint, the dot, the words.
    private func note<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(.studio(12))
            .foregroundStyle(StudioColors.noteInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioColors.note)
            .overlay(alignment: .top) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
    }

    private var description: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            LiveMarkdownEditor(placeholder: "What this pull request does, and how to test it — Markdown",
                               text: $controller.body, minHeight: 300) {
                PullRequestLinkRouter.open($0, repository: entry.compare.repository, root: controller.root,
                                           from: controller.window)
            }
            if controller.drafting {
                note {
                    Spinner(size: 12)
                    Text("Claude is drafting the title and description…")
                }
            } else if controller.drafted {
                note {
                    CoralDot(size: 9)
                    Text(PullRequestClaude.draftNote(commits: controller.draftCommits))
                }
            }
        }
        .background(shape.fill(StudioColors.background))
        .clipShape(shape)
        .overlay(shape.strokeBorder(StudioColors.line3, lineWidth: 1))
    }
}

/// The canvas's `.field`: a text field on the page's background with the `line3` edge, coral while it has the keys.
struct StudioField: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 30
    var font: Font = .studio(12)
    var submit: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(StudioColors.ink)
            .focused($focused)
            .onSubmit { submit?() }
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? StudioColors.coral : StudioColors.line3, lineWidth: 1))
    }
}

/// The canvas's side column (board 3): reviewers, labels with the assignee and a linked issue, and what happens after
/// creating.
struct NewPullRequestMeta: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let entry: NewPullRequestStore.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ReviewersPicker(controller: controller, repository: entry.compare.repository)
            LabelsAndIssue(controller: controller, entry: entry)
            AfterCreating(controller: controller, entry: entry)
        }
    }
}

/// Reviewers (board 3): chips, "Add a reviewer…" with the repository's assignable users, and Claude Code Review (an
/// automation for the repository; only a build with Automations shows it).
private struct ReviewersPicker: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let repository: String
    @ObservedObject private var features = StudioFeatures.shared
    @State private var search = ""
    @State private var people: [String] = []

    var body: some View {
        let typed = search.lowercased()
        let matches = people.filter { !controller.reviewers.contains($0) && $0.lowercased().contains(typed) }
        StudioCard {
            VStack(alignment: .leading, spacing: 8) {
                Caption("Reviewers")
                if !controller.reviewers.isEmpty {
                    FlowRow(spacing: 6) {
                        ForEach(controller.reviewers, id: \.self) { login in
                            PersonChip(login: login) { controller.reviewers.removeAll { $0 == login } }
                        }
                    }
                }
                StudioField(placeholder: "Add a reviewer…", text: $search) { add(search) }
                if !search.isEmpty {
                    ForEach(Array(matches.prefix(6)), id: \.self) { person in
                        Button { add(person) } label: {
                            HStack(spacing: 8) {
                                Avatar(login: person, size: 18)
                                Text(person).font(.studio(12)).foregroundStyle(StudioColors.ink)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if features.isOn(.automations) {
                    Rectangle().fill(StudioColors.line2).frame(height: 1).padding(.top, 2)
                    AutomationPRSwitch(kit: .review, repository: repository, folder: controller.root,
                                       layout: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .task(id: repository) { load() }
    }

    private func load() {
        guard !repository.isEmpty else { return }
        PullRequestStore.shared.lookup(PullRequestActions.assignableUsersArguments(repository: repository),
                                       parse: PullRequestActions.parseAssignableUsers) { people = $0 ?? [] }
    }

    private func add(_ person: String) {
        let login = person.trimmingCharacters(in: .whitespaces)
        guard !login.isEmpty, !controller.reviewers.contains(login) else { return }
        controller.reviewers.append(login)
        search = ""
    }
}

/// A reviewer chip (the canvas's): their initials, their login, and × to take them off.
private struct PersonChip: View {
    let login: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Avatar(login: login, size: 18)
            Text(login).font(.studio(12)).foregroundStyle(StudioColors.ink)
            Button(action: remove) {
                StudioIcon(.close, size: 10)
                    .foregroundStyle(StudioColors.muted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(login)")
        }
        .padding(.horizontal, 4)
        .frame(height: 26)
        .background(Capsule().fill(StudioColors.chip))
    }
}

/// Labels (the repository's: + to add, × to take off), the assignee (the viewer), and a linked issue ("Closes #N" goes
/// into the description on Create).
private struct LabelsAndIssue: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let entry: NewPullRequestStore.Entry
    @State private var available: [PullRequestPage.Label] = []
    @State private var search = ""
    @State private var issues: [PullRequestActions.Issue] = []

    var body: some View {
        let repository = entry.compare.repository
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Labels")
                    FlowRow(spacing: 6) {
                        ForEach(controller.labels, id: \.self) { name in
                            LabelChip(label: PullRequestPage.Label(name: name, color: ""),
                                      remove: { controller.labels.removeAll { $0 == name } })
                        }
                        Menu {
                            let unused = available.filter { !controller.labels.contains($0.name) }
                            if unused.isEmpty { Text("No other labels") }
                            ForEach(unused, id: \.name) { label in
                                Button(label.name) { controller.labels.append(label.name) }
                            }
                        } label: {
                            StudioIcon(.plus, size: 12)
                                .foregroundStyle(StudioColors.muted)
                                .frame(width: 22, height: 22)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Add a Label")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Assignee")
                    if let viewer = entry.compare.settings?.viewer, !viewer.isEmpty {
                        HStack(spacing: 8) {
                            Avatar(login: viewer, size: 20)
                            Text(viewer).font(.studio(12.5)).foregroundStyle(StudioColors.ink)
                                + Text(" (you)").font(.studio(12.5)).foregroundStyle(StudioColors.muted)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Linked issue")
                    if let issue = controller.issue {
                        HStack(spacing: 8) {
                            Text("#\(issue.number)").font(.studioMono(12)).foregroundStyle(StudioColors.coralInk)
                            Text(issue.title).font(.studio(12)).foregroundStyle(StudioColors.ink).lineLimit(1)
                            Spacer(minLength: 4)
                            SmallIconButton(icon: .close, label: "Unlink the Issue") { controller.issue = nil }
                        }
                    } else {
                        StudioField(placeholder: "Search issues or type #", text: $search) { find(repository) }
                        ForEach(issues, id: \.number) { issue in
                            Button { link(issue) } label: {
                                HStack(spacing: 8) {
                                    Text("#\(issue.number)").font(.studioMono(11.5)).foregroundStyle(StudioColors.muted)
                                    Text(issue.title).font(.studio(12)).foregroundStyle(StudioColors.ink).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .task(id: repository) { loadLabels(repository) }
    }

    /// "#12" or "12" links that issue (its title looked up); words search the repository's issues.
    private func find(_ repository: String) {
        let text = search.trimmingCharacters(in: .whitespaces)
        if let number = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text) {
            PullRequestStore.shared.lookup(PullRequestActions.issueView(number, repository: repository),
                                           parse: PullRequestActions.parseIssue) { issue in
                if let issue { link(issue) }
            }
            return
        }
        guard !text.isEmpty else { return }
        PullRequestStore.shared.lookup(PullRequestActions.issueSearch(text, repository: repository),
                                       parse: PullRequestActions.parseIssues) { issues = $0 ?? [] }
    }

    private func link(_ issue: PullRequestActions.Issue) {
        controller.issue = issue
        search = ""
        issues = []
    }

    private func loadLabels(_ repository: String) {
        guard !repository.isEmpty else { return }
        PullRequestStore.shared.lookup(PullRequestActions.labelList(repository: repository),
                                       parse: PullRequestActions.parseLabels) { available = $0 ?? [] }
    }
}

/// After creating (board 3): auto-merge when approved and green (when the repository allows it). Watching for CI and
/// review comments, and Claude fixing red CI, are automations for the repository; only a build with Automations shows
/// them.
private struct AfterCreating: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let entry: NewPullRequestStore.Entry
    @ObservedObject private var features = StudioFeatures.shared

    var body: some View {
        let allowed = entry.compare.settings?.autoMergeAllowed == true
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                Caption("After creating")
                if features.isOn(.automations) {
                    AutomationPRSwitch(kit: .watch, repository: entry.compare.repository, folder: controller.root)
                    AutomationPRSwitch(kit: .fixCI, repository: entry.compare.repository, folder: controller.root)
                }
                checkbox("Auto-merge when approved and green", isOn: $controller.autoMerge, enabled: allowed,
                         help: allowed ? "GitHub merges it once it's approved and its checks pass"
                             : "Auto-merge is off for this repository")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func checkbox(_ title: String, isOn: Binding<Bool>, enabled: Bool, help: String) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.studio(12.5)).foregroundStyle(enabled ? StudioColors.ink : StudioColors.muted)
        }
        .toggleStyle(.checkbox)
        .disabled(!enabled)
        .help(help)
    }
}

/// The create bar (board 3): Create as draft and what it means for reviewers; Cancel (Esc; it asks once edited) and
/// Create pull request ⌘↩. Create pushes the branch first when GitHub doesn't have it as it is here.
struct CreateBar: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let entry: NewPullRequestStore.Entry
    @State private var confirming = false

    var body: some View {
        let compare = entry.compare
        let titled = !controller.title.trimmingCharacters(in: .whitespaces).isEmpty
        let ready = entry.loading == .ready && titled && compare.ahead > 0 && compare.base != compare.branch
        VStack(alignment: .leading, spacing: 8) {
            if let error = entry.createError { InlineError(message: error) }
            HStack(spacing: 12) {
                Toggle(isOn: $controller.draft) {
                    Text("Create as draft").font(.studio(12.5, .medium)).foregroundStyle(StudioColors.ink)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioColors.coral)
                Text(controller.draft ? "Reviewers aren’t notified until you mark it ready."
                     : "Reviewers are notified right away.")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                Spacer(minLength: 8)
                StudioButton(title: "Cancel", hint: "Esc", style: .quiet) { cancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                StudioButton(title: controller.draft ? "Create draft PR" : "Create pull request", hint: "⌘↩",
                             style: .primary, busy: entry.creating, enabled: ready) {
                    create(compare)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help(tooltip(compare, titled: titled))
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
        .background(StudioColors.bar)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line).frame(height: 1) }
        .confirmationDialog("Discard this pull request?", isPresented: $confirming) {
            Button("Discard", role: .destructive) { controller.window?.close() }
        } message: {
            Text("Its title, description, reviewers and labels go.")
        }
    }

    private func cancel() {
        if controller.edited { confirming = true } else { controller.window?.close() }
    }

    private func create(_ compare: NewPullRequestStore.Compare) {
        let form = NewPullRequestStore.Form(
            base: compare.base, branch: compare.branch, title: controller.title.trimmingCharacters(in: .whitespaces),
            body: controller.body, draft: controller.draft, reviewers: controller.reviewers, labels: controller.labels,
            issue: controller.issue?.number, autoMerge: controller.autoMerge)
        let repository = compare.repository
        NewPullRequestStore.shared.create(root: controller.root, form: form) { number in
            controller.created(number, repository: repository)
        }
    }

    private func tooltip(_ compare: NewPullRequestStore.Compare, titled: Bool) -> String {
        if compare.base == compare.branch { return "Compare a branch other than the base" }
        if compare.ahead == 0 { return "\(compare.branch) has nothing \(compare.base) doesn't" }
        if !titled { return "Give it a title" }
        if compare.pushed != .current { return "Pushes \(compare.branch) to GitHub first, then creates it (⌘↩)" }
        return "Creates the pull request on GitHub (⌘↩)"
    }
}
