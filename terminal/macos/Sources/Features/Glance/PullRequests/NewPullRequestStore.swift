import AppKit
import GlanceCore
import GlanceKit

/// The New pull request tabs' reads and writes (spec 2026-10-07-pr-manager-design.md, "New pull request" and "GitHub"),
/// per project folder, off the main thread:
/// - the repository, its settings (default branch, auto-merge, the viewer) and the branches;
/// - what the branch adds to its base, from local git: commits, files, the diff, conflicts, possible secrets, and
///   whether GitHub has it;
/// - the project's test command, run on a commit and kept;
/// - Create: push when needed, `gh pr create`, auto-merge when asked.
@MainActor
final class NewPullRequestStore: ObservableObject {
    static let shared = NewPullRequestStore()

    /// The branch against its base.
    struct Compare: Equatable {
        var repository = ""
        var settings: RepositorySettings.Settings?
        /// The branches compared: the base (the default branch at first) and the branch (the project's own at first).
        var base = ""
        var branch = ""
        /// The menus: GitHub's branches for the base, local ones to compare.
        var bases: [String] = []
        var branches: [String] = []
        var ahead = 0
        var behind = 0
        var commits: [BranchCompare.Commit] = []
        var files: [BranchCompare.FileStat] = []
        var diff: [PullRequestDiff.File] = []
        /// The diff as git printed it: Claude's draft reads it.
        var diffText = ""
        var merge: BranchCompare.Merge = .unknown
        var pushed: BranchCompare.Pushed = .notPushed
        var secrets: [BranchCompare.Secret] = []
        var testCommand: String?
        /// The branch's commit: what a test run is kept for.
        var commit = ""
    }

    enum Loading: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum TestRun: Equatable {
        case running
        case passed
        case failed(String)
    }

    /// What Create sends.
    struct Form: Sendable {
        let base: String
        let branch: String
        let title: String
        let body: String
        let draft: Bool
        let reviewers: [String]
        let labels: [String]
        let issue: Int?
        let autoMerge: Bool
    }

    struct Entry {
        var compare = Compare()
        var loading: Loading = .loading
        /// Test runs by commit.
        var tests: [String: TestRun] = [:]
        var creating = false
        var createError: String?
    }

    @Published private(set) var entries: [String: Entry] = [:]

    private init() {}

    func entry(_ root: String) -> Entry { entries[root] ?? Entry() }

    /// Reads `branch` against `base` in `root`; nil for the default branch, and the project's own.
    func load(root: String, base: String?, branch: String?) {
        if entries[root] == nil { entries[root] = Entry() }
        entries[root]?.loading = .loading
        let gh = PullRequests.executable()
        let known = RepositoryFoldersModel.shared.repository(ofFolder: root)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.read(root: root, base: base, branch: branch, repository: known, gh: gh)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = NewPullRequestStore.shared
                    switch result {
                    case .success(let compare):
                        store.entries[root]?.compare = compare
                        store.entries[root]?.loading = .ready
                    case .failure(let failure):
                        store.entries[root]?.loading = .failed(failure.message)
                    }
                }
            }
        }
    }

    /// Everything the page and the side bar show: git, and gh for the repository's settings.
    nonisolated private static func read(root: String, base: String?, branch: String?, repository known: String?,
                                         gh: String?) -> Result<Compare, PullRequests.Failure> {
        var compare = Compare()
        guard let repository = known ?? remoteRepository(root) else { return .failure(.notGitHub) }
        compare.repository = repository
        if let arguments = RepositorySettings.arguments(repository: repository) {
            compare.settings = (try? GitHubCLI.run(gh, arguments).get()).flatMap(RepositorySettings.parse)
        }
        guard let own = branch ?? GitHead.branch(inFolder: root) else {
            return .failure(.failed("The project isn't on a branch."))
        }
        compare.branch = own
        compare.base = base ?? compare.settings?.defaultBranch ?? "main"
        // Offline, the last fetch's copy of the base is what the branch is compared with.
        _ = git(BranchCompare.fetchArguments(base: compare.base), root)
        compare.bases = BranchCompare.branches(git(BranchCompare.remoteBranchesArguments(), root)?.output ?? "",
                                               remote: true)
        compare.branches = BranchCompare.branches(git(BranchCompare.localBranchesArguments(), root)?.output ?? "",
                                                  remote: false)
        if let result = git(BranchCompare.countArguments(base: compare.base, head: own), root), result.status == 0,
           let counts = BranchCompare.counts(result.output) {
            compare.behind = counts.left
            compare.ahead = counts.right
        }
        compare.commits = BranchCompare.commits(
            git(BranchCompare.logArguments(base: compare.base, head: own), root)?.output ?? "")
        compare.files = BranchCompare.fileStats(
            git(BranchCompare.numstatArguments(base: compare.base, head: own), root)?.output ?? "")
        compare.diffText = git(BranchCompare.diffArguments(base: compare.base, head: own), root)?.output ?? ""
        compare.diff = PullRequestDiff.parse(compare.diffText)
        if let merge = git(BranchCompare.mergeTreeArguments(base: compare.base, head: own), root) {
            compare.merge = BranchCompare.merge(status: merge.status, output: merge.output)
        }
        if let upstream = git(BranchCompare.upstreamArguments(branch: own), root) {
            compare.pushed = BranchCompare.pushed(status: upstream.status, output: upstream.output)
        }
        compare.secrets = BranchCompare.secrets(in: compare.diff)
        compare.testCommand = BranchCompare.testCommand { name in
            try? String(contentsOfFile: (root as NSString).appendingPathComponent(name), encoding: .utf8)
        }
        compare.commit = git(BranchCompare.headArguments(branch: own), root)?.output
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .success(compare)
    }

    /// git in `root`: its exit status, output and errors.
    nonisolated private static func git(_ arguments: [String], _ root: String, environment: [String: String] = [:])
        -> (status: Int32, output: String, error: String)? {
        guard let result = GitHubCLI.execute("/usr/bin/git", ["-C", root] + arguments, environment: environment) else {
            return nil
        }
        return (result.status, String(decoding: result.output, as: UTF8.self),
                String(decoding: result.error, as: UTF8.self))
    }

    nonisolated private static func remoteRepository(_ root: String) -> String? {
        guard let remotes = git(["remote", "-v"], root), remotes.status == 0 else { return nil }
        return PullRequests.repository(remotes: remotes.output)
    }

    /// ▶: the project's test command on the branch's commit, in a login shell, in the background. The result is kept for
    /// that commit; a failure keeps the end of its output.
    func runTests(root: String) {
        let compare = entry(root).compare
        guard let command = compare.testCommand, !compare.commit.isEmpty else { return }
        let commit = compare.commit
        entries[root]?.tests[commit] = .running
        DispatchQueue.global(qos: .utility).async {
            let result = GitHubCLI.execute("/bin/zsh", ["-lc", command], folder: root)
            let output = result.map { String(decoding: $0.output + $0.error, as: UTF8.self) } ?? "Couldn't run \(command)."
            let tail = output.split(whereSeparator: \.isNewline).suffix(40).joined(separator: "\n")
            let passed = result?.status == 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NewPullRequestStore.shared.entries[root]?.tests[commit] = passed ? .passed : .failed(tail)
                }
            }
        }
    }

    /// Create. It pushes the branch first unless GitHub has it as it is here, runs `gh pr create` ("Closes #N" added for
    /// a linked issue), and turns on auto-merge when asked and allowed. `done` gets the new pull request's number;
    /// a failure stays under the create bar.
    func create(root: String, form: Form, done: @escaping @MainActor (Int) -> Void) {
        guard entries[root]?.creating == false else { return }
        let compare = entry(root).compare
        entries[root]?.creating = true
        entries[root]?.createError = nil
        let gh = PullRequests.executable()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.publish(form, compare: compare, root: root, gh: gh)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = NewPullRequestStore.shared
                    store.entries[root]?.creating = false
                    switch result {
                    case .success(let number): done(number)
                    case .failure(let failure): store.entries[root]?.createError = failure.message
                    }
                }
            }
        }
    }

    nonisolated private static func publish(_ form: Form, compare: Compare, root: String, gh: String?)
        -> Result<Int, PullRequests.Failure> {
        if compare.pushed != .current {
            guard let push = git(BranchCompare.pushArguments(branch: form.branch), root,
                                 environment: ["GIT_TERMINAL_PROMPT": "0"]) else {
                return .failure(.failed("Couldn't run git."))
            }
            guard push.status == 0 else {
                return .failure(.failed("Couldn't push \(form.branch): \(BranchCompare.failure(push.error))"))
            }
        }
        let body = form.issue.map { PullRequestActions.body(form.body, closing: $0) } ?? form.body
        let arguments = BranchCompare.createArguments(repository: compare.repository, base: form.base, head: form.branch,
                                                      title: form.title, draft: form.draft, reviewers: form.reviewers,
                                                      labels: form.labels)
        let output: Data
        switch GitHubCLI.run(gh, arguments, input: Data(body.utf8), folder: root) {
        case .failure(let failure): return .failure(failure)
        case .success(let data): output = data
        }
        guard let number = BranchCompare.createdNumber(String(decoding: output, as: UTF8.self)) else {
            return .failure(.failed("GitHub didn't say which pull request it made."))
        }
        if form.autoMerge, let settings = compare.settings, settings.autoMergeAllowed {
            _ = GitHubCLI.run(gh, PullRequestActions.merge(number, repository: compare.repository,
                                                           method: settings.preferred, auto: true))
        }
        return .success(number)
    }
}
