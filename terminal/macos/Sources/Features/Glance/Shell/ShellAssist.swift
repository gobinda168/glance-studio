import AppKit
import GhosttyKit
import GlanceCore
import GlanceKit
import Observation

/// Glance's terminal suggestions on Studio's side (spec 2026-10-08-terminal-suggestions-design.md): the shell bridge,
/// which shell is which tab, the popups, and the history. Each zsh Studio starts gets `GLANCE_SHELL_SOCKET` and
/// `GLANCE_SHELL_TAB`; its plugin connects, and from then on the shell reports and applies while this decides.
@MainActor
@Observable
final class ShellAssist {
    static let shared = ShellAssist()

    /// What Settings says about keys another zsh plugin owns, one line each.
    private(set) var keysOwnedElsewhere: [String] = []
    /// Distinct commands in Glance's history, and how many came from zsh's file (for Settings).
    private(set) var historyCount = 0
    private(set) var importedCount = 0
    /// Why history is off, when it is (Settings shows it).
    private(set) var historyProblem: String?
    /// Where Claude Code is: nil while not looked up yet, "" when it isn't installed.
    private(set) var claudePath: String?

    @ObservationIgnored private let server = ShellBridgeServer()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var sessions: [ShellBridgeServer.ConnectionID: ShellSession] = [:]
    @ObservationIgnored private var surfaces: [UUID: Weak<Ghostty.SurfaceView>] = [:]
    @ObservationIgnored private var settings = Prefs.suggestions
    @ObservationIgnored private var history: CommandHistoryStore?
    @ObservationIgnored private let historyQueue = DispatchQueue(label: "dev.glance.shell-history", qos: .utility)
    @ObservationIgnored private var index = CommandIndex()
    @ObservationIgnored private var gitRoots: [String: String] = [:]
    /// Tab menu picks: place (`CompletionPicks.context`) → candidate → how often.
    @ObservationIgnored private var picks: [String: [String: Int]] = [:]
    /// The history file to import once the store is open (the first shell's `$HISTFILE`).
    @ObservationIgnored private var historyFile: String?
    @ObservationIgnored private var importChecked = false
    /// The popup open now: the Tab menu, the ↑ list or ⌃R.
    @ObservationIgnored private var active: (any ShellOverlay)?
    @ObservationIgnored private var pluginsSeen: Set<String> = []
    /// The `BROWSER` helper (DevServerLinks), written beside the socket: a path without spaces, which `BROWSER` needs.
    @ObservationIgnored private var browserHelper: String?
    /// The folder holding `glance-browser` (WebLogCommand), put on `PATH` for Studio's shells.
    @ObservationIgnored private var webLogsFolder: String?
    /// The Claude ask under way (one at a time).
    @ObservationIgnored private var claudeRun: ClaudeOneShot.Run?
    /// Claude's panel while its context is gathered: git's answer or the deadline, whichever comes first, starts it.
    @ObservationIgnored private weak var asking: ClaudePanel?
    /// The pill while its context is gathered (the same first-answer-wins as `asking`).
    @ObservationIgnored private weak var writing: SuggestionBadge?

    /// The key Studio writes after `run` so zsh accepts the line at once (the plugin binds ESC [ 9999 ~).
    static let wakeAction = "csi:9999~"

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let socket = (NSTemporaryDirectory() as NSString).appendingPathComponent("glance-shell/\(getpid()).sock")
        server.onOpen = { [weak self] id, pid in self?.sessions[id] = ShellSession(connection: id, peerPID: pid) }
        server.onEvent = { [weak self] id, event in self?.handle(event, from: id) }
        server.onClose = { [weak self] id in self?.closed(id) }
        do {
            try server.start(path: socket)
            writeBrowserHelper(beside: socket)
        } catch {
            NSLog("Glance: terminal suggestions are off: \(error)")
        }
        openHistory()
        lookForClaude()
        NotificationCenter.default.addObserver(forName: SettingsModel.suggestionsDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                               queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                // The search panel takes the key window from its terminal on purpose.
                guard let self, let window = note.object as? NSWindow, self.active?.window === window,
                      !(self.active is HistorySearch) else { return }
                self.closeOverlay()
            }
        }
    }

    /// What a new surface's shell gets so its plugin can find Studio: empty when the bridge isn't running.
    func environment(for id: UUID) -> [String: String] {
        // Restored windows can start their shells before the app has finished launching.
        start()
        guard let path = server.path else { return [:] }
        var environment = ["GLANCE_SHELL_SOCKET": path, "GLANCE_SHELL_TAB": id.uuidString,
                           "GLANCE_SHELL_CACHE": CompletionScripts.shared.cache.path,
                           "GLANCE_SHELL_COMPLETIONS": CompletionScripts.shared.folder.path]
        // Dev servers open their page through BROWSER (Vite, Create React App, Storybook…): Studio's helper shows it
        // in a Browser tab. A BROWSER the user set themselves wins (Studio's own environment, or their shell's rc).
        if let browserHelper, DevServerTabs.isOn, ProcessInfo.processInfo.environment["BROWSER"] == nil {
            environment["BROWSER"] = browserHelper
        }
        // Playwright tests run in the Glance browser, so the user watches them in its panel (spec 2026-10-14-agent-browser).
        if BrowserData.testsInAgentBrowser, StudioFeatures.shared.isOn(.browser),
           ProcessInfo.processInfo.environment["PW_TEST_CONNECT_WS_ENDPOINT"] == nil,
           let endpoint = AgentBrowserBroker.shared.testEndpoint {
            environment["PW_TEST_CONNECT_WS_ENDPOINT"] = endpoint
        }
        // `glance-browser`: the Browser tabs' console and network log, for the person and for Claude Code.
        if let webLogsFolder, BrowserData.capturesLogs {
            let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = webLogsFolder + ":" + inherited
            environment["GLANCE_BIN"] = WebLogCommand.glanceBinary
        }
        return environment
    }

    private func writeBrowserHelper(beside socket: String) {
        let folder = (socket as NSString).deletingLastPathComponent
        webLogsFolder = WebLogCommand.write(into: folder) ? folder : nil
        let path = ((socket as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(DevServerLinks.helperName)
        do {
            try DevServerLinks.helperScript.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            browserHelper = path
        } catch {
            NSLog("Glance: dev servers will open in the default browser: \(error)")
        }
    }

    func register(_ view: Ghostty.SurfaceView) {
        surfaces[view.id] = Weak(view)
        surfaces = surfaces.filter { $0.value.value != nil }
    }

    /// The surface lost focus: its popup closes (unless the search panel took the focus itself).
    func focusChanged(_ view: Ghostty.SurfaceView, focused: Bool) {
        guard !focused, active?.surface === view, !(active is HistorySearch) else { return }
        closeOverlay()
    }

    // MARK: - Events

    private func handle(_ event: ShellEvent, from id: ShellBridgeServer.ConnectionID) {
        guard let session = sessions[id] else { return }
        // The BROWSER helper, not a shell: one address, one answer, and the connection closes.
        if case .browse(let tab, let url) = event {
            let window = UUID(uuidString: tab).flatMap { surfaces[$0]?.value?.window }
            server.finish(.browsed(DevServerTabs.openFromShell(url, from: window)), to: id)
            return
        }
        if case .hello(let hello) = event {
            accept(hello, session)
            return
        }
        guard session.isAccepted else { return }
        switch event {
        case .hello: break
        case .prompt(let seq, let folder):
            session.prompt(seq: seq, folder: folder)
            if active?.session === session { closeOverlay() }
        case .line(let seq, let cursor, let text):
            session.line(seq: seq, cursor: cursor, text: text)
            lineChanged(session)
        case .exec(let folder, let start, let command):
            session.exec(folder: folder, start: start, command: command)
            if active?.session === session { closeOverlay() }
        case .done(let exit, let end):
            if let record = session.done(exit: exit, end: end, tab: session.hello?.tab) { remember(record) }
        case .candidates(let request, let seq, let total):
            session.beginCandidates(request: request, seq: seq, total: total)
        case .candidate(let request, let candidate):
            session.addCandidate(candidate, request: request)
        case .candidatesEnd(let request):
            if let list = session.endCandidates(request: request) { openMenu(list, session) }
        case .open(.history, let seq):
            openList(session, seq: seq)
        case .open(.search, let seq):
            openSearch(session, seq: seq, query: session.text)
        case .names(let kind, let names):
            session.setNames(kind, names)
        case .open(.ask, _):
            ask(session)
        case .open(.translate, _):
            translate(session)
        case .state, .bye, .browse:
            break
        }
    }

    /// A hello is taken when it names a surface of this app whose terminal is the caller's and whose foreground
    /// process is the caller; anything else is dropped.
    private func accept(_ hello: ShellHello, _ session: ShellSession) {
        guard let id = UUID(uuidString: hello.tab), let view = surfaces[id]?.value, let model = view.surfaceModel,
              ShellBridgePolicy.accepts(hello, peerPID: session.peerPID, foregroundPID: model.foregroundPID,
                                        tty: model.ttyName)
        else {
            NSLog("Glance: refused a shell bridge connection (tab \(hello.tab), pid \(hello.pid))")
            server.drop(session.connection)
            return
        }
        session.accept(hello, surface: view)
        server.send(.config(features: settings.wireFeatures), to: session.connection)
        pluginsSeen.formUnion(hello.plugins)
        updateKeysOwnedElsewhere()
        CompletionScripts.shared.refresh(path: hello.path)
        if historyFile == nil { historyFile = hello.historyFile ?? NSHomeDirectory() + "/.zsh_history" }
        importIfNeeded()
    }

    private func closed(_ id: ShellBridgeServer.ConnectionID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if active?.session === session { closeOverlay() }
    }

    /// The tab's current shell: the newest open session for that surface.
    private func current(for view: Ghostty.SurfaceView) -> ShellSession? {
        sessions.values.filter { $0.surface === view && $0.isAccepted }
            .max { ($0.acceptedAt ?? .distantPast) < ($1.acceptedAt ?? .distantPast) }
    }

    /// What a split's strip and tab chip show about its shell: where it is, the command running now, and the last one
    /// that ended with its exit code. Nil when the pane has no shell connected over the bridge.
    func paneSnapshot(for view: Ghostty.SurfaceView) -> PaneSnapshot? {
        guard let session = current(for: view) else { return nil }
        return PaneSnapshot(folder: session.running?.folder ?? session.folder, running: session.running?.command,
                            lastCommand: session.recent.last?.command, lastExit: session.recent.last?.exit)
    }

    private func settingsChanged() {
        settings = Prefs.suggestions
        for session in sessions.values where session.isAccepted {
            server.send(.config(features: settings.wireFeatures), to: session.connection)
        }
        if (active is CompletionMenu && !settings.isOn(.tab)) || (active is HistoryList && !settings.isOn(.up))
            || (active is HistorySearch && !settings.isOn(.search)) {
            closeOverlay()
        }
    }

    private func updateKeysOwnedElsewhere() {
        var lines: [String] = []
        if pluginsSeen.contains("fzf-tab") { lines.append("fzf-tab handles Tab in your shell, so the Tab menu stays off there.") }
        if pluginsSeen.contains("atuin") || pluginsSeen.contains("mcfly") || pluginsSeen.contains("fzf") {
            let owner = ["atuin", "mcfly", "fzf"].first(where: pluginsSeen.contains) ?? "Another plugin"
            lines.append("\(owner) handles ⌃R or ↑ in your shell; Glance leaves the keys it owns alone.")
        }
        keysOwnedElsewhere = lines
    }

    // MARK: - History

    private func openHistory() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("Glance/history.sqlite")
        historyQueue.async { [weak self] in
            do {
                let store = try CommandHistoryStore(url: url)
                let records = try store.all()
                let picks = (try? store.picks()) ?? [:]
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.history = store
                        self.picks = picks
                        self.setIndex(CommandIndex(records))
                        self.importIfNeeded()
                    }
                }
            } catch {
                NSLog("Glance: command history is off: \(error)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.historyProblem = "Glance's history couldn't be opened: \(error)" }
                }
            }
        }
    }

    private func setIndex(_ index: CommandIndex) {
        self.index = index
        historyCount = index.entries.count
        importedCount = index.entries.filter { $0.recordedCount == 0 }.count
    }

    private func remember(_ record: CommandRecord) {
        guard settings.recordHistory, HistoryPolicy.shouldRecord(record.command), let store = history else { return }
        var record = record
        if let folder = record.folder {
            let root = ProjectRoot.find(from: folder)
            if FileManager.default.fileExists(atPath: root + "/.git") {
                record.gitRoot = root
                record.branch = GitHead.branch(inFolder: folder)
            }
        }
        index.add(record)
        historyCount = index.entries.count
        historyQueue.async { [record] in
            do { try store.insert(record) } catch { NSLog("Glance: couldn't record a command: \(error)") }
        }
    }

    /// zsh's own history comes in once: the first time a shell connects with the store open.
    private func importIfNeeded() {
        guard !importChecked, let store = history, let file = historyFile else { return }
        importChecked = true
        let firstRecorded = index.entries.filter { $0.recordedCount > 0 }.map(\.lastStart).min() ?? Date()
        historyQueue.async { [weak self] in
            guard (try? store.meta("zshHistoryImported")) ?? nil == nil else { return }
            self?.runImport(file, store: store, before: firstRecorded, replacing: false)
        }
    }

    /// Settings → Import zsh history: the imported rows are made again from the file.
    func reimportHistory() {
        guard let store = history else { return }
        let file = historyFile ?? NSHomeDirectory() + "/.zsh_history"
        let firstRecorded = index.entries.filter { $0.recordedCount > 0 }.map(\.lastStart).min() ?? Date()
        historyQueue.async { [weak self] in
            self?.runImport(file, store: store, before: firstRecorded, replacing: true)
        }
    }

    /// Runs on `historyQueue`.
    nonisolated private func runImport(_ file: String, store: CommandHistoryStore, before: Date, replacing: Bool) {
        do {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
            let records = ZshHistory.records(ZshHistory.parse(data), before: before)
            if replacing { try store.deleteImported() }
            try store.insert(records)
            try store.setMeta("zshHistoryImported", file)
            let all = try store.all()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ShellAssist.shared.setIndex(CommandIndex(all)) }
            }
        } catch {
            NSLog("Glance: the zsh history import failed: \(error)")
        }
    }

    /// Settings → Clear history: every recorded and imported command goes (zsh's own file stays as it is).
    func clearHistory() {
        guard let store = history else { return }
        setIndex(CommandIndex())
        historyQueue.async {
            do { try store.deleteAll() } catch { NSLog("Glance: couldn't clear the history: \(error)") }
        }
    }

    private func forget(_ command: String) {
        index.remove(command: command)
        historyCount = index.entries.count
        guard let store = history else { return }
        historyQueue.async {
            do { try store.delete(command: command) } catch { NSLog("Glance: couldn't forget a command: \(error)") }
        }
    }

    // MARK: - Popups

    private func canOpen(_ session: ShellSession) -> Ghostty.SurfaceView? {
        guard let view = session.surface, current(for: view) === session, view.window?.isKeyWindow == true else {
            return nil
        }
        return view
    }

    private func openMenu(_ list: (request: Int, seq: Int, total: Int, candidates: [CompletionCandidate]),
                          _ session: ShellSession) {
        guard settings.isOn(.tab), let view = canOpen(session), !list.candidates.isEmpty else { return }
        closeOverlay()
        let place = CompletionPicks.context(line: session.text, start: list.candidates.first?.start ?? 0)
        let picked = picks[place] ?? [:]
        let menu = CompletionMenu(session: session, surface: view, request: list.request, total: list.total,
                                  candidates: list.candidates) { Double(picked[$0.word] ?? 0) }
        clearGhost(session)
        menu.onAccept = { [weak self, weak menu] match, open in
            guard let self, let menu else { return }
            self.accept(match, open: open, from: menu)
        }
        menu.onClose = { [weak self] in self?.closeOverlay() }
        guard menu.lineChanged(session.text, cursor: session.cursor) else { return }
        active = menu
        menu.show()
    }

    private func openList(_ session: ShellSession, seq: Int) {
        guard settings.isOn(.up), let view = canOpen(session), !index.isEmpty else {
            server.send(.fallback(seq: seq, key: "up"), to: session.connection)
            return
        }
        closeOverlay()
        let tab = session.hello?.tab, folder = session.folder
        let list = HistoryList(session: session, surface: view) { [weak self, weak session] typed in
            guard let self, let session else { return [] }
            return self.index.upList(typed: typed, tab: tab, folder: folder, gitRoot: self.gitRoot(of: folder)) {
                self.runs($0, in: session)
            }
        }
        list.onPick = { [weak self, weak session] command, run in
            guard let self, let session else { return }
            self.closeOverlay()
            self.put(command, on: session, run: run)
        }
        list.onSearch = { [weak self, weak session] text in
            guard let self, let session else { return }
            self.openSearch(session, seq: session.seq, query: text)
        }
        list.onClose = { [weak self] in self?.closeOverlay() }
        clearGhost(session)
        active = list
        list.show()
    }

    private func openSearch(_ session: ShellSession, seq: Int, query: String) {
        guard settings.isOn(.search), let view = canOpen(session) else {
            server.send(.fallback(seq: seq, key: "search"), to: session.connection)
            return
        }
        closeOverlay()
        let tab = session.hello?.tab, folder = session.folder
        let search = HistorySearch(session: session, surface: view, query: query) { [weak self, weak session] text, scope in
            guard let self, let session else { return [] }
            return self.index.search(text, scope: scope, tab: tab, folder: folder) { self.runs($0, in: session) }
        }
        search.onPick = { [weak self, weak session] command, run in
            guard let self, let session else { return }
            self.closeOverlay()
            self.put(command, on: session, run: run)
        }
        search.onDelete = { [weak self] command in self?.forget(command) }
        search.onClose = { [weak self] in self?.closeOverlay() }
        clearGhost(session)
        active = search
        search.show()
    }

    /// A pick from history: on the line to edit, or run (with the wake key, so zsh runs it at once).
    private func put(_ command: String, on session: ShellSession, run: Bool) {
        session.suggested = nil
        if run {
            server.send(.run(seq: session.seq, text: command), to: session.connection)
            guard let surface = session.surface?.surface else { return }
            let action = Self.wakeAction
            _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        } else {
            server.send(.replace(seq: session.seq, text: command, cursor: command.unicodeScalars.count),
                        to: session.connection)
        }
    }

    private func lineChanged(_ session: ShellSession) {
        if session.openAfterAccept {
            session.openAfterAccept = false
            server.send(.complete(seq: session.seq), to: session.connection)
        }
        mark(session)
        if let active, active.session === session {
            if !active.lineChanged(session.text, cursor: session.cursor) { closeOverlay() }
            return
        }
        suggest(session)
    }

    // MARK: - Error marks and fixes

    /// Marks unknown commands and an unclosed quote (spec "S4"), once the shell's names are in; not with
    /// zsh-syntax-highlighting, which marks the line itself.
    private func mark(_ session: ShellSession) {
        guard settings.isOn(.marks), session.hasNames,
              session.hello?.plugins.contains("zsh-syntax-highlighting") == false else { return }
        let marks = session.text.isEmpty ? [] : LineMarks.marks(line: session.text, cursor: session.cursor) { word in
            self.isKnown(word, in: session)
        }
        guard marks != session.marks else { return }
        session.marks = marks
        server.send(.marks(seq: session.seq, ranges: marks), to: session.connection)
    }

    private func isKnown(_ word: String, in session: ShellSession) -> Bool {
        if session.names.contains(word) { return true }
        let path = resolve(word, in: session.folder)
        var isFolder: ObjCBool = false
        if word.contains("/") || word.hasPrefix("~") {
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return false }
            return isFolder.boolValue || FileManager.default.isExecutableFile(atPath: path)
        }
        if let known = session.pathLookups[word] { return known }
        // Installed after the shell hashed its commands, or a folder name (AUTO_CD).
        let known = CompletionTools.locate(word, path: session.hello?.path ?? "",
                                           isExecutable: FileManager.default.isExecutableFile) != nil
            || (FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue)
        session.pathLookups[word] = known
        return known
    }

    /// Whether a past command would run: every command name in it known to the shell (a path counts, since it may
    /// be another folder's). A mistyped command stays in history but out of every suggestion; true until the shell's
    /// names are in.
    private func runs(_ command: String, in session: ShellSession) -> Bool {
        guard session.hasNames else { return true }
        return LineMarks.runs(command) { word in
            word.contains("/") || word.hasPrefix("~") || self.isKnown(word, in: session)
        }
    }

    private func resolve(_ path: String, in folder: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst(1) }
        if path.hasPrefix("/") { return path }
        return (folder as NSString).appendingPathComponent(path)
    }

    /// The last command's output, as the terminal shows it: its last 50 lines.
    private func lastOutput(_ session: ShellSession) -> String {
        guard let surface = session.surface?.surface else { return "" }
        var text = ghostty_text_s()
        guard ghostty_surface_read_last_output(surface, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        let output = String(cString: text.text)
        return output.split(separator: "\n", omittingEmptySubsequences: false).suffix(50).joined(separator: "\n")
    }

    /// After a failure, on the new prompt: the rules' fix as ghost text (it beats the next-command prediction). A
    /// moment's wait lets the terminal finish drawing the output before it's read.
    private func offerFix(_ session: ShellSession) -> Bool {
        guard settings.isOn(.fixes), let failed = session.failure, session.fix == nil else { return false }
        let seq = session.seq
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak session] in
            MainActor.assumeIsolated {
                guard let self, let session, session.seq == seq, session.text.isEmpty else { return }
                let failure = Failure(command: failed.command, exitCode: failed.exitCode, output: self.lastOutput(session),
                                      folder: failed.folder)
                session.failure = failure
                // A sentence that ran before the shell's ⏎ could catch it (an older plugin): "command not found" for a
                // line that reads as plain English is translated, not corrected by edit distance.
                if failure.exitCode == 127,
                   PlainEnglish.isRequest(failure.command, isKnown: { self.isKnown($0, in: session) }) {
                    self.claudeFix(session, sentence: failure.command)
                    return
                }
                guard let fix = Corrections.fix(failure, self.correctionContext(for: session)) else {
                    // No rule: Claude writes the fix onto the line, else offers the chip, else the next command.
                    self.claudeFix(session)
                    return
                }
                session.fix = fix
                self.send(GhostSuggestion(text: fix, cursor: nil), to: session, line: "")
            }
        }
        return true
    }

    private func correctionContext(for session: ShellSession) -> CorrectionContext {
        let folder = session.folder
        return CorrectionContext(
            names: session.names,
            exists: { [weak self] in FileManager.default.fileExists(atPath: self?.resolve($0, in: folder) ?? $0) },
            isDirectory: { [weak self] path in
                var isFolder: ObjCBool = false
                return FileManager.default.fileExists(atPath: self?.resolve(path, in: folder) ?? path,
                                                      isDirectory: &isFolder) && isFolder.boolValue
            },
            list: { [weak self] path in
                guard let self else { return nil }
                let url = URL(fileURLWithPath: self.resolve(path, in: folder), isDirectory: true)
                guard let items = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return nil }
                return items.prefix(2000).map { item in
                    let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    return item.lastPathComponent + (isFolder ? "/" : "")
                }
            },
            scripts: ProjectFacts.scripts(inFolder: folder),
            branches: ProjectFacts.branches(inFolder: folder),
            history: index.worked(folder: folder, gitRoot: gitRoot(of: folder)))
    }

    /// The git repository a folder is in, nil outside one. Looked up once per folder.
    private func gitRoot(of folder: String) -> String? {
        if let known = gitRoots[folder] { return known.isEmpty ? nil : known }
        let root = ProjectRoot.find(from: folder)
        let found = FileManager.default.fileExists(atPath: root + "/.git") ? root : nil
        gitRoots[folder] = found ?? ""
        return found
    }

    // MARK: - Ghost text

    /// Ghost text for the line as it is now (spec "S3"): kept while the user types along the last one; the next
    /// command on the first empty line after a command.
    private func suggest(_ session: ShellSession) {
        guard settings.isOn(.ghost), session.hello?.plugins.contains("zsh-autosuggestions") == false,
              session.cursorAtEnd else {
            session.suggested = nil
            return
        }
        let text = session.text
        if text.isEmpty {
            defer { session.justFinished = false }
            session.suggested = nil
            guard session.justFinished else { return }
            if offerFix(session) { return }
            offerNext(session)
            return
        }
        session.justFinished = false
        if let suggested = session.suggested, suggested.count > text.count, suggested.hasPrefix(text),
           text.hasPrefix(session.suggestedAfter) {
            session.suggestedAfter = text
            return
        }
        guard let suggestion = GhostSuggester.suggest(index, context(for: session)) else {
            session.suggested = nil
            return
        }
        send(suggestion, to: session, line: text)
    }

    private func offerNext(_ session: ShellSession) {
        guard settings.isOn(.next), let previous = session.previousCommand,
              let next = GhostSuggester.next(index, previous: previous, folder: session.folder),
              runs(next.text, in: session) else { return }
        send(next, to: session, line: "")
    }

    private func send(_ suggestion: GhostSuggestion, to session: ShellSession, line: String) {
        session.suggested = line + suggestion.text
        session.suggestedAfter = line
        server.send(.suggest(seq: session.seq, text: suggestion.text, cursor: suggestion.cursor), to: session.connection)
    }

    private func clearGhost(_ session: ShellSession) {
        guard session.suggested != nil else { return }
        session.suggested = nil
        server.send(.suggest(seq: session.seq, text: "", cursor: nil), to: session.connection)
    }

    private func context(for session: ShellSession) -> GhostContext {
        let folder = session.folder
        func resolve(_ path: String) -> String {
            if path == "~" { return NSHomeDirectory() }
            if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst(1) }
            if path.hasPrefix("/") { return path }
            return (folder as NSString).appendingPathComponent(path)
        }
        var ghost = GhostContext(
            line: session.text, folder: folder, tab: session.hello?.tab, previous: session.previousCommand, now: Date(),
            names: session.names,
            exists: { FileManager.default.fileExists(atPath: resolve($0)) },
            list: { path in
                let url = URL(fileURLWithPath: resolve(path), isDirectory: true)
                guard let items = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return nil }
                return items.prefix(2000).map { item in
                    let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    return item.lastPathComponent + (isFolder ? "/" : "")
                }
            })
        ghost.gitRoot = gitRoot(of: folder)
        ghost.runs = { [weak self, weak session] command in
            guard let self, let session else { return true }
            return self.runs(command, in: session)
        }
        return ghost
    }

    private func accept(_ match: CompletionMatch, open: Bool, from menu: CompletionMenu) {
        guard let session = menu.session else { return }
        closeOverlay()
        let place = CompletionPicks.context(line: session.text, start: match.candidate.start)
        picks[place, default: [:]][match.candidate.word, default: 0] += 1
        if let store = history {
            let word = match.candidate.word
            historyQueue.async { try? store.recordPick(context: place, candidate: word) }
        }
        session.openAfterAccept = open && match.candidate.isDirectory
        server.send(.accept(request: menu.request, index: match.candidate.index), to: session.connection)
    }

    private func closeOverlay() {
        let overlay = active
        active = nil
        if overlay is ClaudePanel || overlay is SuggestionBadge {
            claudeRun?.cancel()
            claudeRun = nil
        }
        overlay?.close()
    }

    // MARK: - Claude

    func lookForClaude() {
        ClaudeOneShot.locate { [weak self] path in self?.claudePath = path ?? "" }
    }

    private var claudeInstalled: Bool { claudePath.map { !$0.isEmpty } ?? false }

    /// The Ask pill at the prompt after a failure no rule fixed. False when it isn't shown.
    @discardableResult
    private func showChip(_ session: ShellSession) -> Bool {
        guard settings.isOn(.claude), claudeInstalled, active == nil, let view = canOpen(session) else { return false }
        let chip = AskChip(session: session, surface: view) { [weak self, weak session] in
            guard let self, let session else { return }
            self.ask(session)
        }
        active = chip
        chip.show()
        return true
    }

    /// After a failure no rule fixed: Claude writes the corrected command onto the empty prompt, marked as its
    /// suggestion and never run. If it can't, the Ask pill, else the next command.
    private func claudeFix(_ session: ShellSession, sentence: String? = nil) {
        guard settings.isOn(.claude), claudeInstalled, active == nil, let view = canOpen(session) else {
            if !showChip(session) { offerNext(session) }
            return
        }
        writeCommand(session, view: view, kind: sentence.map { .request($0) } ?? .failure, original: "") {
            [weak self, weak session] in
            guard let self, let session, session.text.isEmpty else { return }
            if !self.showChip(session) { self.offerNext(session) }
        }
    }

    /// ⏎ (or ⌘I) on a line that reads as plain English: Claude turns it into a command and puts it on the line to
    /// review, marked as its suggestion and never run. Anything that isn't a request, or without Claude, runs as typed.
    private func translate(_ session: ShellSession) {
        let line = session.text
        if let badge = active as? SuggestionBadge, badge.session === session, badge.state == .writing { return }
        guard settings.isOn(.claude), claudeInstalled, let view = canOpen(session),
              PlainEnglish.isRequest(line, isKnown: { self.isKnown($0, in: session) }) else {
            put(line, on: session, run: true)
            return
        }
        closeOverlay()
        clearGhost(session)
        writeCommand(session, view: view, kind: .request(line), original: line, fallback: nil)
    }

    /// Asks Claude for a command while the pill shows it writing, then puts the command on the line. `original` is
    /// what the line held (the sentence, or nothing after a failure): Esc brings it back. When Claude has no command,
    /// `fallback` runs, or the pill says so and the line stays as typed.
    private func writeCommand(_ session: ShellSession, view: Ghostty.SurfaceView, kind: TerminalAsk.Kind, original: String,
                              fallback: (() -> Void)?) {
        let badge = SuggestionBadge(session: session, surface: view, original: original)
        badge.onDismiss = { [weak self, weak session, weak badge] in
            guard let self, let session, let badge else { return }
            self.closeOverlay()
            if session.text != badge.original { self.put(badge.original, on: session, run: false) }
        }
        active = badge
        badge.show()
        writing = badge
        askContext(session) { [weak self, weak badge, weak session] context in
            guard let self, let badge, let session, self.writing === badge else { return }
            self.writing = nil
            guard self.active === badge else { return }
            let run = ClaudeOneShot.run(arguments: TerminalAsk.arguments(), prompt: TerminalAsk.prompt(kind, context),
                                        folder: nil) { [weak self, weak badge, weak session] result in
                guard let self, let badge, let session, self.active === badge else { return }
                switch result {
                case .success(let text):
                    guard let command = TerminalAsk.answer(text).commands.first?.command else {
                        return self.badgeGaveUp(badge, "Claude had no command for that", fallback)
                    }
                    badge.suggested(command, risky: TerminalAsk.isRisky(command))
                    self.server.send(.replace(seq: session.seq, text: command, cursor: command.unicodeScalars.count),
                                     to: session.connection)
                case .failure(let failure):
                    self.badgeGaveUp(badge, failure.kind == .notInstalled ? "Claude Code isn't installed" : failure.message,
                                     fallback)
                }
            }
            self.claudeRun = run
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak badge, weak run] in
                MainActor.assumeIsolated {
                    guard let self, let badge, let run, self.active === badge, badge.state == .writing else { return }
                    run.cancel()
                    self.badgeGaveUp(badge, "Claude didn't answer in 30 seconds", fallback)
                }
            }
        }
    }

    private func badgeGaveUp(_ badge: SuggestionBadge, _ message: String, _ fallback: (() -> Void)?) {
        guard active === badge else { return }
        if let fallback {
            closeOverlay()
            fallback()
        } else {
            badge.failed(String(message.prefix(60)))
        }
    }

    /// ⌘I, Tab or ⏎ on a `#` line, the chip (spec "S5"): ask Claude about the line, a failure, or start a request.
    private func ask(_ session: ShellSession) {
        guard settings.isOn(.claude), let view = canOpen(session) else { return }
        guard let kind = TerminalAsk.kind(line: session.text, lastFailed: session.failure != nil) else {
            // An empty line after a success: start a request.
            server.send(.replace(seq: session.seq, text: "# ", cursor: 2), to: session.connection)
            return
        }
        if case .explain(let line) = kind, PlainEnglish.isRequest(line, isKnown: { self.isKnown($0, in: session) }) {
            translate(session)
            return
        }
        closeOverlay()
        clearGhost(session)
        if case .failure = kind, let failed = session.failure, failed.output.isEmpty {
            session.failure = Failure(command: failed.command, exitCode: failed.exitCode, output: lastOutput(session),
                                      folder: failed.folder)
        }
        let question: String
        switch kind {
        case .request(let request): question = request
        case .failure: question = "Why did \u{201C}\(session.failure?.command ?? "")\u{201D} fail?"
        case .explain(let line): question = "What does \u{201C}\(line)\u{201D} do?"
        }
        let panel = ClaudePanel(session: session, surface: view, question: question)
        panel.onPick = { [weak self, weak session] command in
            guard let self, let session else { return }
            self.closeOverlay()
            self.put(command, on: session, run: false)
        }
        panel.onClose = { [weak self] in self?.closeOverlay() }
        active = panel
        panel.show()
        if claudePath == "" {
            panel.failed("Claude Code isn't installed, or isn't on your shell's PATH. Install it from claude.com/code, "
                         + "sign in once with `claude`, then ask again.")
            lookForClaude()
            return
        }
        asking = panel
        askContext(session) { [weak self, weak panel] context in
            guard let self, let panel, self.asking === panel else { return }
            self.asking = nil
            // Closed while git counted.
            guard self.active === panel else { return }
            self.startAsk(TerminalAsk.prompt(kind, context), panel: panel)
        }
    }

    private func startAsk(_ prompt: String, panel: ClaudePanel) {
        let run = ClaudeOneShot.run(arguments: TerminalAsk.arguments(), prompt: prompt, folder: nil) { [weak panel] result in
            guard let panel else { return }
            switch result {
            case .success(let text): panel.answered(TerminalAsk.answer(text))
            case .failure(let failure):
                panel.failed(failure.kind == .notInstalled
                    ? "Claude Code isn't installed, or isn't on your shell's PATH." : failure.message)
            }
        }
        claudeRun = run
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak panel, weak run] in
            MainActor.assumeIsolated {
                guard let panel, let run, panel.model.state == .thinking else { return }
                run.cancel()
                panel.failed("Claude didn't answer in 30 seconds. Check your connection, then ask again.")
            }
        }
    }

    /// What Claude is told. In a repository it also gets the uncommitted change counts, from a `git status` off the
    /// main thread that can be slow in a big one: the context comes back with them, or at 1.5 s without them (git is
    /// stopped then), and again a moment later (the caller takes the first).
    private func askContext(_ session: ShellSession, completion: @escaping @MainActor (TerminalAsk.Context) -> Void) {
        let folder = session.folder
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let makefile = (try? String(contentsOfFile: (folder as NSString).appendingPathComponent("Makefile"),
                                    encoding: .utf8)) ?? ""
        let branch = GitHead.branch(inFolder: folder)
        let context = TerminalAsk.Context(
            folder: ShellFormat.folder(folder),
            system: "macOS \(version.majorVersion).\(version.minorVersion), zsh \(session.hello?.zshVersion ?? "")",
            branch: branch, recent: session.recent,
            scripts: ProjectFacts.scripts(inFolder: folder), makeTargets: TerminalAsk.makeTargets(makefile),
            failure: session.failure)
        guard branch != nil else { return completion(context) }
        DispatchQueue.global(qos: .userInitiated).async {
            let changes = TerminalAsk.changeCounts(root: ProjectRoot.find(from: folder), timeout: 1.4)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var counted = context
                    counted.changes = changes
                    completion(counted)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { completion(context) }
        }
    }

    /// ⌘ keys in a surface: the open popup's (⌘C in Claude's panel), and ⌘I at a prompt.
    func performKeyEquivalent(_ event: NSEvent, in view: Ghostty.SurfaceView) -> Bool {
        if let active, active.surface === view, active.handleKeyEquivalent(event) { return true }
        guard event.keyCode == 34, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              settings.isOn(.claude), let session = current(for: view), session.atPrompt else { return false }
        ask(session)
        return true
    }

    /// A key in a surface: the open popup takes the ones it uses; everything else goes to the shell.
    func handleKey(_ event: NSEvent, in view: Ghostty.SurfaceView) -> Bool {
        guard let active else { return false }
        guard active.surface === view else {
            closeOverlay()
            return false
        }
        return active.handleKey(event)
    }
}
