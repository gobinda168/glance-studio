import GlanceCore
import SwiftUI

/// The Proof card on the Overview page, after the description (Command Center): the checks, gaps, captures, verdict and
/// pending items of the Claude session that worked on this PR's branch, and "Publish summary", which writes them into
/// the description between the proof markers. Hidden with Command Center off.
struct ProofCard: View {
    let page: PullRequestPage.Page
    let root: String?
    let key: PullRequestStore.Key
    @ObservedObject private var features = StudioFeatures.shared

    var body: some View {
        if features.isOn(.commandCenter) { ProofCardContent(page: page, root: root, key: key) }
    }

    // MARK: Shared with the card's content

    /// What the page knows (PR checks failing, merged) and what the session's worktree says (uncommitted changes). A
    /// worktree git couldn't read (`nil`) counts as having changes, so nothing reads Ready on a guess.
    static func facts(_ page: PullRequestPage.Page, uncommitted: Bool?) -> ProofFacts {
        ProofFacts(uncommitted: uncommitted ?? true, prChecksFailing: page.checks.failed > 0, prMerged: page.state == .merged)
    }

    /// The page as `ProofPR` knows a PR (the base repository is the key's), for preview scripts and deployments.
    static func info(_ page: PullRequestPage.Page, key: PullRequestStore.Key) -> ProofPR.Info {
        ProofPR.Info(number: page.number, url: "", state: page.state.rawValue, merged: page.state == .merged,
                     checksFailing: page.checks.failed > 0, head: page.head, repository: key.repository, base: page.base)
    }

    /// The records of the PR's branch in the repository at `root`, newest first. A PR from a fork has none: its branch
    /// lives in another repository, and a local branch of the same name is not its work. Blocking (decodes the records,
    /// asks git about those of the branch): off the main thread.
    nonisolated static func find(branch: String, root: String?, fromFork: Bool) -> [WorkRecord] {
        guard !fromFork, let root, !branch.isEmpty, let common = RepoLocation.find(cwd: root)?.commonDir else { return [] }
        return ProofRecords.match(WorkStore().records(), branch: branch, commonDir: common) { ProofRecords.home(of: $0) }
    }
}

private struct ProofCardContent: View {
    let page: PullRequestPage.Page
    let root: String?
    let key: PullRequestStore.Key
    @ObservedObject private var store = PullRequestStore.shared
    /// The records read, and the folder they were read for; nil until read.
    @State private var found: Found?
    @State private var selected: String?
    @State private var setup: SetupState?
    @State private var preparing = false
    /// A publish was started here, so the store's body error is this card's to show.
    @State private var attempted = false
    @State private var notice: Notice?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Found {
        var root: String?
        var records: [WorkRecord]
    }
    private struct SetupState {
        var session: String
        var load: ProofSetupLoad
        /// Every folder the record names is gone.
        var gone: Bool
        /// The session's worktree has changes not committed: false when its folder is gone, nil when git couldn't say.
        var uncommitted: Bool?
    }
    private enum Notice: Equatable {
        case done(String)
        case failed(String)
    }
    private struct LoadKey: Hashable {
        var branch: String
        var root: String?
        var oid: String
    }
    private struct SetupKey: Hashable {
        var session: String
        var updated: Date
    }

    /// Nil while the records are being read, and for another folder's: its proof is not this repository's.
    private var matches: [WorkRecord]? { found.flatMap { $0.root == root ? $0.records : nil } }
    private var selectedRecord: WorkRecord? { matches?.first { $0.session == selected } ?? matches?.first }
    private var loadKey: LoadKey { LoadKey(branch: page.head, root: root, oid: page.headOid) }
    private var setupKey: SetupKey? { selectedRecord.map { SetupKey(session: $0.session, updated: $0.updated) } }
    private var entry: PullRequestStore.Entry { store.entry(key) }

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(StudioColors.line2).frame(height: 1)
                content
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
            }
        }
        .task(id: loadKey) { await load() }
        .task(id: setupKey) { await loadSetup() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Proof").font(.studio(12, .semibold)).foregroundStyle(StudioColors.ink)
                .accessibilityAddTraits(.isHeader)
            if let record = selectedRecord, let state = setupState(of: record) {
                ProofPillView(pill: ProofReview.pill(record, setup: state.load.setup, facts: ProofCard.facts(page, uncommitted: state.uncommitted)))
            }
            Spacer(minLength: 4)
            if let matches, matches.count > 1 { sessions(matches) }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 40)
    }

    private func sessions(_ matches: [WorkRecord]) -> some View {
        Menu {
            ForEach(matches, id: \.session) { record in
                let text = "\(ProofFormat.ago(record.updated)) · \(record.session.prefix(8))"
                Button { selected = record.session } label: {
                    if record.session == selectedRecord?.session { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(matches.count) sessions").font(.studio(12, .medium))
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(StudioColors.body)
            .frame(minHeight: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Claude sessions that worked on this branch")
        .accessibilityLabel("\(matches.count) sessions. Choose which one's proof to show")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if root == nil {
            quiet("Proof is read from this repository's folder on this Mac. Open or link the folder to see it.")
        } else if matches == nil {
            HStack(spacing: 6) {
                if !reduceMotion { ProgressView().controlSize(.small) }
                Text("Looking for proof…").font(.studio(12.5)).foregroundStyle(StudioColors.muted)
            }
            .frame(minHeight: 28)
            .accessibilityElement(children: .combine)
        } else if let record = selectedRecord {
            if let state = setupState(of: record) {
                detail(record, state)
            } else {
                quiet("Reading the setup…")
            }
        } else {
            quiet("No proof recorded for this branch")
        }
    }

    /// The setup read for `record`, once it has been (a stale one for another session doesn't count).
    private func setupState(of record: WorkRecord) -> SetupState? {
        setup.flatMap { $0.session == record.session ? $0 : nil }
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.studio(12.5)).foregroundStyle(StudioColors.muted)
            .fixedSize(horizontal: false, vertical: true).frame(minHeight: 28, alignment: .leading)
    }

    @ViewBuilder private func detail(_ record: WorkRecord, _ state: SetupState) -> some View {
        let facts = ProofCard.facts(page, uncommitted: state.uncommitted)
        let setup = state.load.setup
        VStack(alignment: .leading, spacing: 0) {
            gaps(record, state, facts: facts)
            checks(record, setup: setup)
            summary(record)
            footer(record, state)
        }
    }

    // MARK: Gaps and checks

    /// The gaps of the record; without a setup nothing says what must pass, which is a warning of its own, never a
    /// quiet "all clear".
    private func allGaps(_ record: WorkRecord, _ state: SetupState, facts: ProofFacts) -> [ProofGap] {
        let gaps = ProofReview.gaps(record, setup: state.load.setup, facts: facts)
        return state.load.setup == nil ? [ProofGap(level: .warn, text: Self.missingSetup(state))] + gaps : gaps
    }

    @ViewBuilder private func gaps(_ record: WorkRecord, _ state: SetupState, facts: ProofFacts) -> some View {
        let setup = state.load.setup
        // Unknown is not "changes": the caption below says so, the facts only keep Ready closed.
        let all = allGaps(record, state, facts: facts).filter { state.uncommitted != nil || $0.text != ProofReview.uncommittedText }
        if record.checks.isEmpty {
            quiet("No checks recorded yet")
            GapList(gaps: all.filter { $0.level != .warn || setup == nil }, allClear: nil).padding(.top, 4)
        } else {
            GapList(gaps: all, allClear: setup.map { $0.required.isEmpty ? "No required checks" : "Every required check passed" })
        }
        if state.uncommitted == nil { quiet("Couldn't read the folder's state") }
    }

    /// Why the setup isn't there, and what that means.
    private static func missingSetup(_ state: SetupState) -> String {
        if state.gone { return "The session's folder is gone, so its proof setup can't be read. Required checks can't be verified." }
        switch state.load {
        case .invalid(let issues, _):
            return "\(ProofSetupFile.relativePath) has a problem" + (issues.first.map { " (\($0.message))" } ?? "")
                + ". Required checks can't be verified."
        default:
            return "No \(ProofSetupFile.relativePath) found. Required checks can't be verified."
        }
    }

    @ViewBuilder private func checks(_ record: WorkRecord, setup: ProofSetup?) -> some View {
        if let setup {
            if !setup.checks.isEmpty {
                ProofSubhead(title: "Checks") { ProofBadge(source: .glance) }
                ChecksGrid(record: record, setup: setup)
            }
        } else if !record.checks.isEmpty {
            // The runs Glance saw, with nothing to match them against: each is what it was, no more.
            ProofSubhead(title: "Checks") { ProofBadge(source: .glance) }
            VStack(spacing: 4) {
                ForEach(ProofReview.latestRuns(record), id: \.id) { run in ProofCheckStrip(run: run).help(run.command) }
            }
        }
    }

    // MARK: Captures, verdict, pending

    private func summary(_ record: WorkRecord) -> some View {
        let open = record.pending.filter { !$0.done }.count
        return FlowRow(spacing: 6) {
            chip(symbol: "photo", text: "\(record.captures.count) \(record.captures.count == 1 ? "capture" : "captures")")
            chip(symbol: "list.bullet", text: "\(open) pending")
            verdict(record.verdict)
        }
        .padding(.top, 12)
    }

    private func chip(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
            Text(text).font(.studio(11.5)).lineLimit(1)
        }
        .foregroundStyle(StudioColors.muted)
        .padding(.horizontal, 8).frame(minHeight: 22)
        .overlay(Capsule().stroke(StudioColors.line3, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func verdict(_ verdict: ProofVerdict?) -> some View {
        if let verdict {
            let (symbol, word): (String, String) = switch verdict.verdict {
            case .merge: ("checkmark", "Merge")
            case .hold: ("pause", "Hold")
            case .notReady: ("xmark", "Not ready")
            }
            HStack(spacing: 6) {
                chip(symbol: symbol, text: "Verdict: \(word)")
                ProofBadge(source: .claude)
            }
            .help(verdict.reasons.joined(separator: "\n"))
        } else {
            chip(symbol: "minus", text: "No verdict")
        }
    }

    // MARK: Footer

    @ViewBuilder private func footer(_ record: WorkRecord, _ state: SetupState) -> some View {
        let busy = preparing || entry.busy.contains("body")
        VStack(alignment: .leading, spacing: 8) {
            if page.state == .open {
                if let setup = state.load.setup {
                    HStack(spacing: 10) {
                        StudioButton(title: "Publish summary", icon: .checklist, style: .secondary, busy: busy) {
                            publish(record, state.load, setup)
                        }
                        .help("Writes this summary into the description, between its proof markers")
                        if busy { Text(preparing ? "Preparing the summary…" : "Writing the description…")
                            .font(.studio(12)).foregroundStyle(StudioColors.muted) }
                    }
                } else {
                    quiet("Publishing needs the setup, so the summary doesn't claim more than was checked.")
                }
            }
            if !busy {
                switch notice {
                case .done(let text)?:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy))
                        Text(text).font(.studio(12, .medium))
                    }
                    .foregroundStyle(StudioColors.ok)
                    .accessibilityElement(children: .combine)
                case .failed(let text)?:
                    InlineError(message: text)
                case nil:
                    if attempted, let error = entry.errors["body"] { InlineError(message: error) }
                }
            }
        }
        .padding(.top, 14)
    }

    // MARK: Loading

    private func load() async {
        let (branch, root, fromFork) = (page.head, root, page.isCrossRepository)
        let records = await Task.detached(priority: .utility) {
            ProofCard.find(branch: branch, root: root, fromFork: fromFork)
        }.value
        guard !Task.isCancelled else { return }
        // A push to the same branch keeps what is shown; another folder's records never do (see `matches`).
        found = Found(root: root, records: records)
        if !records.contains(where: { $0.session == selected }) { selected = records.first?.session }
    }

    private func loadSetup() async {
        guard let record = selectedRecord else { setup = nil; return }
        let loaded = await Task.detached(priority: .utility) { () -> SetupState in
            let folder = ProofRecords.folder(of: record)
            let load = folder.map { ProofSetupFile.load(cwd: $0) } ?? .missing
            return SetupState(session: record.session, load: load, gone: ProofRecords.isGone(record),
                              uncommitted: folder.map { ProofRecords.hasUncommittedChanges(inFolder: $0) } ?? false)
        }.value
        guard !Task.isCancelled else { return }
        setup = loaded
    }

    // MARK: Publish

    /// Off the main thread (git, a preview script and gh can take a while): reads the session's record again for runs
    /// made since the card loaded, builds the summary, and reads the description from GitHub as it is now. Then it is
    /// written through the store, which shows the busy state and any error and reads the page again. A description
    /// that GitHub didn't send is never rewritten from nothing.
    private func publish(_ record: WorkRecord, _ load: ProofSetupLoad, _ setup: ProofSetup) {
        guard !preparing, !entry.busy.contains("body") else { return }
        preparing = true
        attempted = false
        notice = nil
        let (info, branch, root) = (ProofCard.info(page, key: key), page.head, root)
        let pageFacts = ProofCard.facts(page, uncommitted: false)
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, ProofPR.Failure> in
                let fresh = WorkStore().record(session: record.session) ?? record
                var facts = pageFacts
                // A state git couldn't report isn't written into the description as if it were known.
                if let folder = ProofRecords.folder(of: fresh) {
                    guard let dirty = ProofRecords.hasUncommittedChanges(inFolder: folder) else {
                        return .failure(ProofPR.Failure("Couldn't read the folder's state, so nothing was published. Try again."))
                    }
                    facts.uncommitted = dirty
                }
                let previews = ProofModel.previewList(setup: load, info: info, branch: branch, worktree: fresh.worktree)
                let summary = ProofModel.summary(fresh, setup: setup, facts: facts, previews: previews)
                return ProofPR.description(with: summary, info: info, folder: root)
            }.value
            preparing = false
            switch result {
            case .failure(let failure):
                notice = .failed(failure.message)
            case .success(let body):
                attempted = true
                store.perform(.editBody(body), key: key, root: root) {
                    notice = .done("Summary written to the description")
                }
            }
        }
    }
}
