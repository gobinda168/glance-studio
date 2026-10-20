import GlanceCore
import SwiftUI

/// The side bar beside a New pull request tab (board 3): "New pull request" selected; this branch against its base;
/// the pre-flight checks; and the commits.
struct NewPullRequestSidebar: View {
    @ObservedObject var controller: NewPullRequestWindowController
    @ObservedObject private var store = NewPullRequestStore.shared

    var body: some View {
        let entry = store.entry(controller.root)
        let compare = entry.compare
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(title: "Pull requests")
            BackToPullRequestsRow { controller.sidebarShowsList = true }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    selected(compare)
                        .padding(.horizontal, 6)
                    if !compare.branch.isEmpty {
                        section("This branch", rule: true) {
                            HStack(spacing: 8) {
                                StudioIcon(.branch, size: 14).foregroundStyle(StudioColors.coralInk)
                                Text(compare.branch)
                                    .font(.studioMono(12, .semibold))
                                    .foregroundStyle(StudioColors.ink)
                                    .lineLimit(1)
                            }
                            Text(BranchCompare.aheadLine(ahead: compare.ahead, behind: compare.behind, base: compare.base))
                                .font(.studio(12))
                                .foregroundStyle(StudioColors.muted)
                        }
                        section("Pre-flight") {
                            PreflightList(controller: controller, entry: entry)
                        }
                        section("Commits · \(compare.commits.count)") {
                            ForEach(compare.commits, id: \.hash) { commit in
                                HStack(spacing: 8) {
                                    Text(commit.hash).font(.studioMono(11)).foregroundStyle(StudioColors.coralInk)
                                    Text(commit.subject)
                                        .font(.studio(12))
                                        .foregroundStyle(StudioColors.body)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The canvas's selected row: the pull request to be, its branches, and "unsaved" once edited.
    private func selected(_ compare: NewPullRequestStore.Compare) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(alignment: .top, spacing: 10) {
            StudioIcon(.pullRequest, size: 16).foregroundStyle(StudioColors.ok).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("New pull request").font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink)
                if !compare.branch.isEmpty {
                    Text("\(compare.branch) → \(compare.base)\(controller.edited ? " · unsaved" : "")")
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shape.fill(StudioColors.selection)
            .overlay(alignment: .leading) { Rectangle().fill(StudioColors.coral).frame(width: 2) }
            .clipShape(shape))
    }

    private func section<Content: View>(_ title: String, rule: Bool = false,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(title).padding(.bottom, 2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, rule ? 14 : 0)
        .overlay(alignment: .top) {
            if rule { Rectangle().fill(StudioColors.line2).frame(height: 1) }
        }
        .padding(.horizontal, 16)
        .padding(.top, rule ? 16 : 18)
    }
}

/// Pre-flight (board 3): pushed to origin, no conflicts with the base, no secrets in the diff, and the tests on this
/// commit. ▶ runs the project's test command in the background, and a failure shows the end of its output.
struct PreflightList: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let entry: NewPullRequestStore.Entry

    private enum Mark { case ok, warning, problem, idle }

    var body: some View {
        let compare = entry.compare
        VStack(alignment: .leading, spacing: 8) {
            pushed(compare)
            merge(compare)
            secrets(compare)
            tests(compare)
        }
    }

    private func row<Detail: View>(_ mark: Mark, _ title: String, @ViewBuilder detail: () -> Detail) -> some View {
        HStack(alignment: .top, spacing: 8) {
            icon(mark).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                detail()
            }
        }
    }

    @ViewBuilder private func icon(_ mark: Mark) -> some View {
        switch mark {
        case .ok: StudioIcon(.check, size: 15, weight: 2.2).foregroundStyle(StudioColors.ok)
        case .warning: StudioIcon(.alert, size: 15).foregroundStyle(StudioColors.amber)
        case .problem: StudioIcon(.close, size: 15, weight: 2.2).foregroundStyle(StudioColors.danger)
        case .idle: StudioIcon(.clock, size: 15).foregroundStyle(StudioColors.muted)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.studio(11.5))
            .foregroundStyle(StudioColors.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func pushed(_ compare: NewPullRequestStore.Compare) -> some View {
        switch compare.pushed {
        case .current:
            row(.ok, "Pushed to origin") { note("origin/\(compare.branch) is current") }
        case .ahead(let ahead, behind: let behind):
            row(.warning, ahead == 1 ? "1 commit not pushed" : "\(ahead) commits not pushed") {
                note(behind > 0 ? "origin/\(compare.branch) has \(behind) you don't: pull first"
                     : "Create pushes it first")
            }
        case .notPushed:
            row(.warning, "Not on GitHub yet") { note("Create pushes \(compare.branch) to origin first") }
        }
    }

    @ViewBuilder private func merge(_ compare: NewPullRequestStore.Compare) -> some View {
        switch compare.merge {
        case .clean:
            row(.ok, "No conflicts with \(compare.base)") { EmptyView() }
        case .conflicts(let files):
            row(.problem, files.count == 1 ? "Conflicts with \(compare.base) in 1 file"
                : "Conflicts with \(compare.base) in \(files.count) files") {
                ForEach(Array(files.prefix(3)), id: \.self) { note($0) }
            }
        case .unknown:
            row(.idle, "Couldn't check for conflicts") { EmptyView() }
        }
    }

    @ViewBuilder private func secrets(_ compare: NewPullRequestStore.Compare) -> some View {
        if compare.secrets.isEmpty {
            row(.ok, "No secrets in the diff") { EmptyView() }
        } else {
            row(.problem, compare.secrets.count == 1 ? "1 possible secret in the diff"
                : "\(compare.secrets.count) possible secrets in the diff") {
                ForEach(Array(compare.secrets.prefix(3).enumerated()), id: \.offset) { _, secret in
                    note("\(secret.path):\(secret.line) · \(secret.kind)")
                }
            }
        }
    }

    @ViewBuilder private func tests(_ compare: NewPullRequestStore.Compare) -> some View {
        if let command = compare.testCommand {
            let onBranch = GitHead.branch(inFolder: controller.root) == compare.branch
            switch entry.tests[compare.commit] {
            case .running?:
                HStack(alignment: .top, spacing: 8) {
                    Spinner(size: 15)
                    Text("Running \(command)…").font(.studio(12.5)).foregroundStyle(StudioColors.ink)
                }
            case .passed?:
                row(.ok, "Tests pass on this commit") { run(command, onBranch: onBranch, branch: compare.branch) }
            case .failed(let output)?:
                row(.problem, "Tests fail on this commit") {
                    ScrollView(.vertical) {
                        Text(output)
                            .font(.studioMono(10.5))
                            .foregroundStyle(StudioColors.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
                    run(command, onBranch: onBranch, branch: compare.branch)
                }
            case nil:
                row(.idle, "Tests not run on this commit") { run(command, onBranch: onBranch, branch: compare.branch) }
            }
        } else {
            row(.idle, "No test command found") { note("swift test, npm test, cargo test, go test or make test") }
        }
    }

    /// ▶ and the command (the canvas's 26 pt button). Tests run in the project folder, so only on the branch checked out.
    private func run(_ command: String, onBranch: Bool, branch: String) -> some View {
        StudioButton(title: command, icon: .play, enabled: onBranch, height: 26) {
            NewPullRequestStore.shared.runTests(root: controller.root)
        }
        .help(onBranch ? "Runs \(command) in the project, in the background" : "Check out \(branch) to run its tests")
        .padding(.top, 4)
    }
}
