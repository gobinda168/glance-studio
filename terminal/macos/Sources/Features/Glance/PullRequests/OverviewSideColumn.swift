import AppKit
import GlanceCore
import SwiftUI

/// Board 1's two columns: the main one, and the 300 pt side column beside it, or under it when there's no room (the
/// canvas's flex-wrap at 460 + 24 + 300 pt). One layout, so the columns keep their state when they move.
struct OverviewColumns: Layout {
    var side: CGFloat = 300
    var spacing: CGFloat = 24
    var minimumMain: CGFloat = 460

    private func sideBySide(_ width: CGFloat) -> Bool { width >= minimumMain + spacing + side }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? (minimumMain + spacing + side)
        if sideBySide(width) {
            let main = subviews[0].sizeThatFits(ProposedViewSize(width: width - spacing - side, height: nil))
            let column = subviews[1].sizeThatFits(ProposedViewSize(width: side, height: nil))
            return CGSize(width: width, height: max(main.height, column.height))
        }
        let main = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let column = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: main.height + spacing + column.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if sideBySide(bounds.width) {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width - spacing - side, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX - side, y: bounds.minY),
                              proposal: ProposedViewSize(width: side, height: nil))
        } else {
            let main = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + main.height + spacing),
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// Board 1's side column: merge readiness, reviewers, checks, details.
struct OverviewSideColumn: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MergeReadinessCard(controller: controller, page: page, entry: entry)
            ReviewersCard(controller: controller, page: page, entry: entry)
            ChecksCard(controller: controller, page: page, entry: entry)
            DetailsCard(controller: controller, page: page, entry: entry)
        }
    }
}

// MARK: - Merge readiness

/// Merge readiness (board 1): the rows and the pill; the merge button with the repository's methods; auto-merge; Ready
/// for review or Update branch when they apply. When only Glance's blocking threads stand in the way, merging asks
/// first.
struct MergeReadinessCard: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    @State private var chosen: PullRequestPage.MergeMethod?
    @State private var confirming = false

    var body: some View {
        let blocking = entry.extras?.blocking.count ?? 0
        let readiness = PullRequestPage.readiness(page, blockingThreads: blocking,
                                                  requiredApprovals: entry.extras?.requiredApprovals)
        let methods = entry.settings?.methods ?? [.merge]
        let method = chosen ?? page.autoMerge ?? entry.settings?.preferred ?? methods.first ?? .merge
        StudioCard(rim: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Merge readiness").font(.studio(14, .bold)).foregroundStyle(StudioColors.ink)
                    Spacer(minLength: 8)
                    pill(readiness.pill)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Rectangle().fill(StudioColors.line2).frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(readiness.rows.enumerated()), id: \.offset) { _, row in
                        if row.kind == .threads {
                            // The blocking threads, in the Review comments tab (spec, "Merge readiness").
                            Button {
                                ReviewInboxWindowController.open(repository: controller.key.repository,
                                                                 root: controller.root, filter: .blocking,
                                                                 from: controller.window)
                            } label: {
                                ReadinessRow(row: row).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show Them in Review Comments")
                        } else {
                            ReadinessRow(row: row)
                        }
                    }
                }
                .padding(8)
                if page.state == .open {
                    Rectangle().fill(StudioColors.line2).frame(height: 1)
                    VStack(alignment: .leading, spacing: 10) {
                        if page.isDraft {
                            StudioButton(title: "Ready for review", style: .primary, busy: entry.busy.contains("ready")) {
                                perform(.markReady)
                            }
                        } else {
                            MergeButton(method: method, methods: methods, enabled: readiness.canMerge,
                                        busy: entry.busy.contains("merge"),
                                        merge: { if readiness.asksFirst { confirming = true } else { perform(.merge(method)) } },
                                        choose: { chosen = $0 })
                            if readiness.canUpdateBranch {
                                StudioButton(title: "Update branch", icon: .refresh, busy: entry.busy.contains("update")) {
                                    perform(.updateBranch)
                                }
                            }
                            if entry.settings?.autoMergeAllowed == true && (!readiness.canMerge || page.autoMerge != nil) {
                                autoMerge(method)
                            }
                        }
                        ForEach(["merge", "ready", "update"], id: \.self) { name in
                            if let error = entry.errors[name] { InlineError(message: error) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                }
            }
        }
        .confirmationDialog(blocking == 1 ? "1 blocking thread is unresolved. Merge anyway?"
                                          : "\(blocking) blocking threads are unresolved. Merge anyway?",
                            isPresented: $confirming) {
            Button(method.title, role: .destructive) { perform(.merge(method)) }
        }
    }

    /// "Auto-merge when ready": GitHub merges by the method once the blockers clear.
    private func autoMerge(_ method: PullRequestPage.MergeMethod) -> some View {
        let on = page.autoMerge != nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto-merge when ready").font(.studio(12.5)).foregroundStyle(StudioColors.ink)
                Text("\(Self.verb(page.autoMerge ?? method)) once blockers clear")
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
            }
            Spacer(minLength: 8)
            Toggle("Auto-merge when ready", isOn: Binding(get: { on }, set: { perform(.autoMerge($0 ? method : nil)) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(entry.busy.contains("merge"))
        }
    }

    private static func verb(_ method: PullRequestPage.MergeMethod) -> String {
        switch method {
        case .merge: "Merge"
        case .squash: "Squash"
        case .rebase: "Rebase"
        }
    }

    private func perform(_ action: PullRequestStore.Action) {
        PullRequestStore.shared.perform(action, key: controller.key, root: controller.root)
    }

    @ViewBuilder private func pill(_ pill: PullRequestPage.Readiness.Pill) -> some View {
        switch pill {
        case .ready: StatePill(text: "Ready", tone: .ok)
        case .pending: StatePill(text: "Pending", tone: .amber)
        case .draft: StatePill(text: "Draft", tone: .neutral)
        case .merged: StatePill(text: "Merged", icon: .merge, tone: .coral)
        case .closed: StatePill(text: "Closed", tone: .danger)
        case .blocked(let count): StatePill(text: "Blocked · \(count)", tone: .danger)
        }
    }
}

/// A readiness row: a check, a clock or a cross, its title and detail; blocking threads on the danger tint.
private struct ReadinessRow: View {
    let row: PullRequestPage.Readiness.Row

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.studio(13)).foregroundStyle(StudioColors.ink)
                Text(row.detail).font(.studio(11.5)).foregroundStyle(StudioColors.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(row.kind == .threads ? StudioColors.dangerFill : .clear))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch row.tone {
        case .ok: StudioIcon(.check, size: 16, weight: 2.2).foregroundStyle(StudioColors.ok)
        case .pending: StudioIcon(.clock, size: 16).foregroundStyle(StudioColors.amber)
        case .blocked: StudioIcon(.close, size: 16, weight: 2.2).foregroundStyle(StudioColors.danger)
        }
    }
}

/// The canvas's split merge button: the method's words, and a menu of the repository's methods. Coral when GitHub
/// would merge now; outlined and dimmed when it wouldn't.
private struct MergeButton: View {
    let method: PullRequestPage.MergeMethod
    let methods: [PullRequestPage.MergeMethod]
    let enabled: Bool
    let busy: Bool
    let merge: () -> Void
    let choose: (PullRequestPage.MergeMethod) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 0) {
            Button(action: merge) {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.mini) } else { StudioIcon(.merge, size: 14) }
                    Text(method.title).font(.studio(12, .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled || busy)
            Rectangle()
                .fill(enabled ? StudioColors.onCoral.opacity(0.2) : StudioColors.line3)
                .frame(width: 1, height: 30)
            Menu {
                ForEach(methods, id: \.self) { item in
                    Button(item.title) { choose(item) }
                }
            } label: {
                StudioIcon(.chevronDown, size: 14).frame(width: 34, height: 30)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 34, height: 30)
            .disabled(methods.count < 2)
            .accessibilityLabel("Merge Method")
        }
        .foregroundStyle(enabled ? StudioColors.onCoral : StudioColors.ink)
        .background(shape.fill(enabled ? StudioColors.coral : .clear))
        .overlay { if !enabled { shape.strokeBorder(StudioColors.line3, lineWidth: 1) } }
        .opacity(enabled ? 1 : 0.5)
    }
}

// MARK: - Reviewers

/// Reviewers (board 1): each with their state; + to ask someone (the repository's assignable people, or any login).
struct ReviewersCard: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    @State private var asking = false
    @State private var login = ""
    @State private var people: [String] = []

    var body: some View {
        let reviewers = PullRequestPage.reviewers(page)
        let blockers = Set((entry.extras?.blocking ?? []).compactMap { $0.comments.first?.author })
        StudioCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Caption("Reviewers")
                    Spacer(minLength: 4)
                    if page.state == .open {
                        SidebarIconButton(icon: .plus, label: "Request a Reviewer") {
                            asking = true
                            loadPeople()
                        }
                        .popover(isPresented: $asking, arrowEdge: .bottom) { requestPopover }
                    }
                }
                if reviewers.isEmpty {
                    Text("No reviewers yet.").font(.studio(12)).foregroundStyle(StudioColors.muted)
                }
                ForEach(reviewers, id: \.login) { reviewer in
                    HStack(spacing: 10) {
                        Avatar(login: reviewer.login, size: 22)
                        Text(reviewer.login).font(.studio(13)).foregroundStyle(StudioColors.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        ReviewerStateLabel(state: reviewer.state, blocking: blockers.contains(reviewer.login))
                    }
                }
                if let error = entry.errors["reviewers"] { InlineError(message: error) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var requestPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Add a reviewer…", text: $login)
                .textFieldStyle(.roundedBorder)
                .font(.studio(12))
                .frame(width: 220)
                .onSubmit { request(login) }
            ForEach(Array(people.filter { login.isEmpty || $0.lowercased().contains(login.lowercased()) }.prefix(6)),
                    id: \.self) { person in
                Button { request(person) } label: {
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
        .padding(12)
    }

    private func loadPeople() {
        PullRequestStore.shared.lookup(PullRequestActions.assignableUsersArguments(repository: controller.key.repository),
                                       parse: PullRequestActions.parseAssignableUsers) { people = $0 ?? [] }
    }

    private func request(_ person: String) {
        let name = person.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        asking = false
        login = ""
        PullRequestStore.shared.perform(.requestReview(name), key: controller.key, root: controller.root)
    }
}

/// A reviewer's state as the canvas words and colours it; a comment that left blocking threads is red.
private struct ReviewerStateLabel: View {
    let state: PullRequestPage.Reviewer.State
    let blocking: Bool

    var body: some View {
        HStack(spacing: 4) {
            StudioIcon(icon, size: 13, weight: state == .approved ? 2.2 : StudioIcons.strokeWidth)
            Text(word).font(.studio(11.5, .semibold))
        }
        .foregroundStyle(color)
    }

    private var icon: StudioIcons.Name {
        switch state {
        case .approved: .check
        case .changesRequested: .close
        case .commented: .chats
        case .pending: .clock
        }
    }

    private var word: String {
        switch state {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .commented: "Commented"
        case .pending: "Pending"
        }
    }

    private var color: Color {
        switch state {
        case .approved: StudioColors.ok
        case .changesRequested: StudioColors.danger
        case .commented: blocking ? StudioColors.danger : StudioColors.muted
        case .pending: StudioColors.amber
        }
    }
}

// MARK: - Checks and details

/// Checks (board 1): the first three in the Checks page's order, failing first, and "All N" to the Checks page.
struct ChecksCard: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry

    var body: some View {
        let checks = entry.shownChecks(page)
        let first = PullRequestChecks.ordered(checks).prefix(3)
        StudioCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Caption("Checks")
                    Spacer(minLength: 4)
                    if !checks.isEmpty {
                        Button("All \(checks.count)") { controller.section = .checks }
                            .buttonStyle(.plain)
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.coralInk)
                    }
                }
                if first.isEmpty {
                    Text("None on this branch.").font(.studio(12)).foregroundStyle(StudioColors.muted)
                }
                ForEach(Array(first.enumerated()), id: \.offset) { _, check in
                    HStack(spacing: 8) {
                        CheckOutcomeIcon(outcome: check.outcome)
                        Text(check.name).font(.studioMono(12)).foregroundStyle(StudioColors.ink).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

/// Details (board 1): labels (+ from the repository's, × to take one off) and the issues it closes (Link an issue…
/// adds "Closes #N" to the description).
struct DetailsCard: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    @State private var labels: [PullRequestPage.Label] = []
    @State private var linking = false
    @State private var search = ""
    @State private var issues: [PullRequestActions.Issue] = []

    private var editable: Bool { page.state == .open }

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Labels")
                    FlowRow(spacing: 6) {
                        ForEach(page.labels, id: \.name) { label in
                            LabelChip(label: label, remove: editable ? { perform(.removeLabel(label.name)) } : nil)
                        }
                        if editable {
                            Menu {
                                let unused = labels.filter { candidate in !page.labels.contains { $0.name == candidate.name } }
                                if unused.isEmpty { Text("No other labels") }
                                ForEach(unused, id: \.name) { label in
                                    Button(label.name) { perform(.addLabel(label.name)) }
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
                            .onAppear(perform: loadLabels)
                        }
                    }
                    if page.labels.isEmpty && !editable {
                        Text("None").font(.studio(12)).foregroundStyle(StudioColors.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Caption("Linked issue")
                    ForEach(page.closingIssues, id: \.self) { number in
                        Button("#\(number)") {
                            PullRequestWindowController.open(repository: controller.key.repository, number: number,
                                                             root: controller.root, from: controller.window)
                        }
                        .buttonStyle(.plain)
                        .font(.studioMono(12.5))
                        .foregroundStyle(StudioColors.coralInk)
                    }
                    if editable {
                        Button("Link an issue…") { linking = true }
                            .buttonStyle(.plain)
                            .font(.studio(12.5))
                            .foregroundStyle(StudioColors.coralInk)
                            .popover(isPresented: $linking, arrowEdge: .bottom) { linkPopover }
                    }
                }
                ForEach(["labels", "issue"], id: \.self) { name in
                    if let error = entry.errors[name] { InlineError(message: error) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var linkPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search issues or type #", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.studio(12))
                .frame(width: 260)
                .onSubmit(find)
            ForEach(issues, id: \.number) { issue in
                Button { link(issue.number) } label: {
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
        .padding(12)
    }

    /// "#12" or "12" links that issue; words search the repository's issues.
    private func find() {
        let text = search.trimmingCharacters(in: .whitespaces)
        if let number = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text) {
            link(number)
            return
        }
        guard !text.isEmpty else { return }
        PullRequestStore.shared.lookup(PullRequestActions.issueSearch(text, repository: controller.key.repository),
                                       parse: PullRequestActions.parseIssues) { issues = $0 ?? [] }
    }

    private func link(_ number: Int) {
        linking = false
        search = ""
        issues = []
        perform(.linkIssue(number))
    }

    private func loadLabels() {
        PullRequestStore.shared.lookup(PullRequestActions.labelList(repository: controller.key.repository),
                                       parse: PullRequestActions.parseLabels) { labels = $0 ?? [] }
    }

    private func perform(_ action: PullRequestStore.Action) {
        PullRequestStore.shared.perform(action, key: controller.key, root: controller.root)
    }
}

/// A label as the canvas sets it: a chip, with × under the pointer to take it off (the New pull request page's too).
struct LabelChip: View {
    let label: PullRequestPage.Label
    let remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label.name).font(.studio(11.5, .semibold)).foregroundStyle(StudioColors.body)
            if let remove, hovering {
                Button(action: remove) {
                    StudioIcon(.close, size: 10).foregroundStyle(StudioColors.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(label.name)")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(StudioColors.chip))
        .onHover { hovering = $0 }
    }
}
