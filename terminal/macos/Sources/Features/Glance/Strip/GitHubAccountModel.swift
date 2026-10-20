import AppKit
import GlanceCore
import GlanceKit

/// The GitHub account behind the Pull requests side bar (spec 2026-10-08-pr-repositories-design.md, "Signing in" and
/// "The repository list"): signed in or out (gh's login); gh's browser sign-in, run here, with its one-time code;
/// gh's sign-out; and every repository the account reaches, saved in
/// `~/Library/Application Support/Glance/github-repositories.json`.
@MainActor
final class GitHubAccountModel: ObservableObject {
    static let shared = GitHubAccountModel()

    enum State: Equatable {
        /// Not looked up yet.
        case unknown
        /// No gh on this Mac.
        case noGh
        case signedOut
        case signedIn(String)
    }

    /// The sign-in card while gh's browser sign-in runs.
    enum SignIn: Equatable {
        /// gh is starting: no code yet.
        case starting
        case waiting(GitHubAccount.SignInPrompt)
        case failed(String)
    }

    enum ListState: Equatable {
        case idle, loading
        case failed(String)
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var signIn: SignIn?
    @Published private(set) var repositories: [GitHubAccount.Repository] = []
    @Published private(set) var listState: ListState = .idle
    @Published private(set) var signOutError: String?
    private var readAt: Date?
    private var looking = false
    private var lookedOnce = false
    private var signInProcess: Process?
    private var signInTimedOut = false

    private init() {
        if let saved = Self.loadSaved() {
            state = .signedIn(saved.login)
            repositories = saved.repositories
            readAt = saved.readAt
        }
    }

    var login: String? {
        if case .signedIn(let login) = state { return login }
        return nil
    }

    /// The repository list has been read for this account.
    var hasList: Bool { readAt != nil }

    // MARK: The account

    /// Looks the account up (gh's login): once per launch, or again with `force`. Signed in, the list then reads when
    /// it's stale.
    func refresh(force: Bool = false) {
        guard !looking, force || !lookedOnce else { return }
        looking = true
        lookedOnce = true
        DispatchQueue.global(qos: .utility).async {
            let result = GitHubCLI.run(PullRequests.executable(), GitHubAccount.loginArguments)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GitHubAccountModel.shared.looked(result) }
            }
        }
    }

    private func looked(_ result: Result<Data, PullRequests.Failure>) {
        looking = false
        switch result {
        case .success(let data):
            let found = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !found.isEmpty else { return }
            if login?.lowercased() != found.lowercased() {
                // Another account: its list isn't this one's.
                repositories = []
                readAt = nil
            }
            state = .signedIn(found)
            signOutError = nil
            loadRepositories()
        case .failure(.notInstalled):
            state = .noGh
        case .failure(.signedOut):
            signedOutSeen()
        case .failure:
            break // offline: keep what's known
        }
    }

    /// A read found gh signed out (exit 4): the side bar shows the sign-in card, and nothing of the account stays.
    func signedOutSeen() {
        guard state != .signedOut else { return }
        state = .signedOut
        repositories = []
        readAt = nil
        listState = .idle
        Self.save(nil)
        PullRequestsModel.shared.clear()
    }

    // MARK: The repository list

    /// Reads the account's repositories, unless the list is under ten minutes old (and `force` is off).
    func loadRepositories(force: Bool = false) {
        guard let login, listState != .loading else { return }
        if !force, let readAt, Date().timeIntervalSince(readAt) < GitHubAccount.Saved.freshFor { return }
        listState = .loading
        DispatchQueue.global(qos: .utility).async {
            let result = GitHubCLI.run(PullRequests.executable(), GitHubAccount.repositoriesArguments)
                .map { GitHubAccount.repositories(String(decoding: $0, as: UTF8.self)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GitHubAccountModel.shared.loaded(result, for: login) }
            }
        }
    }

    private func loaded(_ result: Result<[GitHubAccount.Repository], PullRequests.Failure>, for login: String) {
        listState = .idle
        guard self.login == login else { return } // signed out or switched meanwhile
        switch result {
        case .success(let list):
            let now = Date()
            repositories = list
            readAt = now
            Self.save(GitHubAccount.Saved(login: login, readAt: now, repositories: list))
        case .failure(.signedOut):
            signedOutSeen()
        case .failure(let failure):
            listState = .failed(failure.message)
        }
    }

    // MARK: Signing in

    /// Sign in with GitHub: gh's browser sign-in. The card shows its code and waits until GitHub approves; no code in
    /// 20 s ends it with gh's last line.
    func startSignIn() {
        guard signInProcess == nil else { return }
        guard let gh = PullRequests.executable() else {
            state = .noGh
            return
        }
        signIn = .starting
        signInTimedOut = false
        let output = Output()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = GitHubAccount.signInArguments
        process.environment = GitHubCLI.environment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let prompt = GitHubAccount.signInPrompt(output.append(data)) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GitHubAccountModel.shared.prompted(prompt, by: process) }
            }
        }
        process.terminationHandler = { process in
            pipe.fileHandleForReading.readabilityHandler = nil
            let text = output.append(pipe.fileHandleForReading.readDataToEndOfFile())
            let status = process.terminationStatus
            let signalled = process.terminationReason == .uncaughtSignal
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    GitHubAccountModel.shared.signInEnded(process, status: status, signalled: signalled, output: text)
                }
            }
        }
        do {
            try process.run()
        } catch {
            signIn = .failed("Couldn't start gh: \(error.localizedDescription)")
            return
        }
        signInProcess = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak process] in
            MainActor.assumeIsolated {
                let model = GitHubAccountModel.shared
                guard let process, model.signInProcess === process, model.signIn == .starting else { return }
                model.signInTimedOut = true
                process.terminate()
            }
        }
    }

    private func prompted(_ prompt: GitHubAccount.SignInPrompt, by process: Process) {
        guard signInProcess === process, signIn != .waiting(prompt) else { return }
        signIn = .waiting(prompt)
    }

    private func signInEnded(_ process: Process, status: Int32, signalled: Bool, output: String) {
        guard signInProcess === process else { return }
        signInProcess = nil
        if status == 0 && !signalled {
            signIn = nil
            state = .unknown
            refresh(force: true) // the login, then the list
        } else if signalled && !signInTimedOut {
            signIn = nil // Cancel
        } else {
            signIn = .failed(GitHubAccount.lastLine(output) ?? "gh couldn't sign in.")
        }
        signInTimedOut = false
    }

    func cancelSignIn() {
        if let signInProcess, signInProcess.isRunning {
            signInProcess.terminate()
        } else {
            signIn = nil
        }
    }

    /// Copy Code and Open GitHub: the code on the clipboard again, and GitHub's device page in the browser.
    func copyCodeAndOpen() {
        guard case .waiting(let prompt) = signIn else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt.code, forType: .string)
        NSWorkspace.shared.open(prompt.url)
    }

    // MARK: Signing out

    /// Sign out, after a confirmation: gh's own sign-out (the terminals' too); then the side bar shows the sign-in card.
    func signOut(from window: NSWindow?) {
        guard let login else { return }
        let alert = NSAlert()
        alert.messageText = "Sign out of GitHub?"
        alert.informativeText = "The GitHub CLI signs out too, in your terminals."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        let answered: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = GitHubCLI.run(PullRequests.executable(), GitHubAccount.signOutArguments(login: login))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { GitHubAccountModel.shared.signedOut(result) }
                }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: answered) } else { answered(alert.runModal()) }
    }

    private func signedOut(_ result: Result<Data, PullRequests.Failure>) {
        switch result {
        case .success, .failure(.signedOut):
            signOutError = nil
            signedOutSeen()
        case .failure(let failure):
            signOutError = failure.message
        }
    }

    // MARK: The saved list

    private static var savedFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glance", isDirectory: true)
            .appendingPathComponent("github-repositories.json")
    }

    private static func loadSaved() -> GitHubAccount.Saved? {
        (try? Data(contentsOf: savedFile)).flatMap(GitHubAccount.Saved.decode)
    }

    /// Saves the list, or removes it (nil).
    private static func save(_ saved: GitHubAccount.Saved?) {
        let file = savedFile
        guard let data = saved?.encoded() else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// gh's sign-in output so far, from the pipe's queue.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        /// Adds `data` and returns everything so far as text.
        func append(_ data: Data) -> String {
            lock.lock()
            defer { lock.unlock() }
            bytes.append(data)
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
