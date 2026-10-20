import AppKit
import GlanceCore
import WebKit

/// The ⌘ keys the page owns. WKWebView would otherwise let the menu's Undo, Find and so on take them, and Monaco would
/// never see them.
private let pageKeys: Set<String> = ["z", "f", "g", "d", "l", "i", "k", "/", "[", "]"]

final class EditorWebView: WKWebView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command), !flags.contains(.control),
       let key = event.charactersIgnoringModifiers?.lowercased(), pageKeys.contains(key) {
      keyDown(with: event)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// The editor page: Monaco in a web view. The page asks for files, listings and saves over a message bridge; this class
/// does the disk work with `FileService` off the main thread and answers. It also notices when an open file changes on
/// disk, and keeps the page's session (open files, layout) per project for the next launch.
@MainActor
public final class EditorWeb: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  public let view: WKWebView
  public let root: String
  /// The active file (nil: none open).
  public private(set) var openPath: String?
  /// The selected lines of the active file (1-based), or nil.
  public private(set) var selectedLines: ClosedRange<Int>?
  /// Every open file with unsaved edits.
  public private(set) var dirtyPaths: [String] = []
  public var isDirty: Bool { !dirtyPaths.isEmpty }
  /// The active file, the open files or their unsaved state changed (for the tab title).
  public var onChange: (() -> Void)?

  private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard
  private var sessionKey: String { "editorSession:" + root }

  private let files: FileService
  private let queue = DispatchQueue(label: "dev.glance.editor.files", qos: .userInitiated)
  private var ready = false
  private var queued: [String] = []
  /// The modification time the page last saw, for each open file.
  private var known: [String: Double] = [:]
  private var notified: [String: String] = [:]
  private var cachedList: [String]?
  private var pendingSave: ((Bool) -> Void)?
  private var searchToken: CancellationToken?
  private var poll: Timer?
  /// The Changes panel's commit message draft, while Claude writes it.
  private var commitDraft: ClaudeOneShot.Run?
  /// The page's inline Claude box (⌘I).
  private lazy var asks = InlineAskSessions(folder: root) { [weak self] event, request in
    self?.call(EditorReply.askEvent(event, request: request))
  }

  public init(root: String, webDirectory: URL) {
    self.root = root
    let files = FileService(root: root)
    self.files = files
    let configuration = WKWebViewConfiguration()
    let controller = WKUserContentController()
    configuration.userContentController = controller
    // The Markdown and HTML preview's images, stylesheets and scripts.
    configuration.setURLSchemeHandler(PreviewSchemeHandler(files: files), forURLScheme: PreviewFiles.scheme)
    // Monaco's workers are loaded from file: URLs.
    configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
    view = EditorWebView(frame: .zero, configuration: configuration)
    super.init()
    controller.add(WeakMessageHandler(self), name: "glanceEditor")
    view.navigationDelegate = self
    view.setValue(false, forKey: "drawsBackground")
    view.underPageBackgroundColor = .clear
    #if DEBUG
    view.isInspectable = true
    #endif
    // The page reads fonts from ../vendor, so the whole Web folder is readable.
    view.loadFileURL(webDirectory.appendingPathComponent("editor/index.html"), allowingReadAccessTo: webDirectory)
    // Only while the tab is in view: a background tab catches up when its window becomes key.
    poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.view.window?.occlusionState.contains(.visible) == true else { return }
        self.checkExternalChange()
      }
    }
    poll?.tolerance = 0.25
  }

  public func close() {
    poll?.invalidate()
    poll = nil
    asks.stopAll()
  }

  // MARK: Calls into the page

  private func call(_ script: String) {
    guard ready else { queued.append(script); return }
    view.evaluateJavaScript("void (\(script))") { _, error in
      if let error { NSLog("Glance editor: \(script.prefix(40))… failed: \(error)") }
    }
  }

  /// Saves the active file (the page's ⌘S), or with `all` every file with unsaved edits. `completion(true)` once
  /// everything asked for is saved; false when a save failed (the page shows why).
  public func save(all: Bool = false, completion: ((Bool) -> Void)? = nil) {
    guard ready else { completion?(!isDirty); return }
    pendingSave = completion
    call(all ? "editorHost.saveAll()" : "editorHost.save()")
  }

  public func quickOpen() { call("editorHost.quickOpen()") }

  /// Asks the page to show its Search panel (⌘⇧F).
  public func findInProject() { call("editorHost.search()") }

  /// Shows the lines Claude changed in its latest turn (paths relative to the root), replacing earlier marks.
  public func showClaudeChanges(_ marks: [String: [LineMark]]) { call(EditorReply.claudeChanges(marks)) }
  public func showClaudeFiles(_ paths: [String]) { call(EditorReply.claudeFiles(paths)) }
  public func nextClaudeChange() { call("editorHost.nextChange()") }
  public func previousClaudeChange() { call("editorHost.prevChange()") }
  public func clearClaudeChanges() { call("editorHost.clearChanges()") }

  /// Opens a file (a path relative to the root) in a tab, or activates its tab, optionally at a line and column.
  public func open(path: String, line: Int? = nil, column: Int? = nil) {
    call(EditorReply.open(path: path, line: line, column: column))
  }

  /// Asks the page to deal with every open file that changed on disk since the page last saw it.
  public func checkExternalChange() {
    let snapshot = known
    guard !snapshot.isEmpty else { return }
    queue.async { [files] in
      var changes: [(path: String, modified: Double?)] = []
      for (path, expected) in snapshot {
        let modified = files.modified(path)
        if modified != expected { changes.append((path, modified)) }
      }
      guard !changes.isEmpty else { return }
      DispatchQueue.main.async { [weak self, changes] in
        guard let self else { return }
        for change in changes {
          guard self.known[change.path] == snapshot[change.path] else { continue }
          let state = change.modified.map { String($0) } ?? "gone"
          guard self.notified[change.path] != state else { continue }
          self.notified[change.path] = state
          self.call(EditorReply.externalChange(path: change.path, modified: change.modified))
        }
      }
    }
  }

  // MARK: Messages from the page

  nonisolated public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    MainActor.assumeIsolated {
      // The preview's frames get the message handler too: only the editor page itself may use the bridge.
      guard message.frameInfo.isMainFrame, let request = EditorRequest(body: message.body) else { return }
      switch request {
      case .ready:
        ready = true
        call(EditorReply.project(root: root))
        queued.forEach { call($0) }
        queued.removeAll()
        if let stored = Self.defaults.string(forKey: sessionKey), let script = EditorReply.restore(sessionJSON: stored) {
          call(script)
        }
      case .state(let active, let dirty, let open):
        openPath = active
        dirtyPaths = dirty
        known = known.filter { open.contains($0.key) }
        notified = notified.filter { open.contains($0.key) }
        onChange?()
      case .selection(let lines):
        selectedLines = lines
        onChange?()
      case .session(let json):
        if EditorReply.restore(sessionJSON: json) != nil { Self.defaults.set(json, forKey: sessionKey) }
      case .saveDone(let ok):
        pendingSave?(ok)
        pendingSave = nil
      case .log(let text):
        NSLog("Glance editor page: %@", text)
      case .read(let id, let path):
        queue.async { [files] in
          let result = Result { try files.read(path) }
          DispatchQueue.main.async { [weak self] in self?.finishRead(id: id, result: result) }
        }
      case .list(let id, let path):
        queue.async { [files] in
          let result = Result { try files.listDirectory(path) }
          DispatchQueue.main.async { [weak self] in
            switch result {
            case .success(let entries): self?.call(EditorReply.entries(id: id, entries))
            case .failure(let error):
              NSLog("Glance editor: listing \"%@\" failed: %@", path, String(describing: error))
              self?.call(EditorReply.failed(id: id, Self.failure(error)))
            }
          }
        }
      case .save(let id, let path, let text, let modified, let bom):
        queue.async { [files] in
          let result = Result { try files.save(path, text: text, expectedModified: modified, bom: bom) }
          DispatchQueue.main.async { [weak self] in self?.finishSave(id: id, path: path, result: result) }
        }
      case .create(let id, let path, let directory):
        queue.async { [files] in
          let result = Result { try files.create(path, directory: directory) }
          DispatchQueue.main.async { [weak self] in
            switch result {
            case .success: self?.call(EditorReply.created(id: id))
            case .failure(let error): self?.call(EditorReply.failed(id: id, Self.failure(error)))
            }
          }
        }
      case .search(let id, let query, let options):
        searchToken?.cancel()
        let token = CancellationToken()
        searchToken = token
        DispatchQueue.global(qos: .userInitiated).async { [files] in
          let result = Result { try files.search(query: query, options: options, isCancelled: { token.isCancelled }) }
          DispatchQueue.main.async { [weak self] in
            switch result {
            case .success(let found): self?.call(EditorReply.searchResults(id: id, found))
            case .failure(let error): self?.call(Self.searchFailure(id: id, error))
            }
          }
        }
      case .replace(let id, let query, let options, let replacement, let paths, let skip):
        DispatchQueue.global(qos: .userInitiated).async { [files] in
          let result = Result { try files.replace(query: query, options: options, replacement: replacement, paths: paths, skipping: Set(skip)) }
          DispatchQueue.main.async { [weak self] in
            switch result {
            case .success(let done): self?.call(EditorReply.replaced(id: id, done))
            case .failure(let error): self?.call(Self.searchFailure(id: id, error))
            }
          }
        }
      case .changes(let id):
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
          let changes = GitChanges.lists(root: root)
          DispatchQueue.main.async { [weak self] in self?.call(EditorReply.changes(id: id, changes)) }
        }
      case .headText(let id, let path):
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
          let text = GitChanges.headText(root: root, path: path)
          DispatchQueue.main.async { [weak self] in self?.call(EditorReply.headText(id: id, text)) }
        }
      case .indexText(let id, let path):
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
          let text = GitChanges.indexText(root: root, path: path)
          DispatchQueue.main.async { [weak self] in self?.call(EditorReply.headText(id: id, text)) }
        }
      case .stage(let id, let paths):
        gitAction(id: id) { GitChanges.stage(root: $0, paths: paths) }
      case .unstage(let id, let paths):
        gitAction(id: id) { GitChanges.unstage(root: $0, paths: paths) }
      case .discard(let id, let tracked, let untracked):
        gitAction(id: id) { GitChanges.discard(root: $0, tracked: tracked, untracked: untracked) }
      case .commit(let id, let message):
        gitAction(id: id) { GitChanges.commit(root: $0, message: message) }
      case .draftCommit:
        startCommitDraft()
      case .draftCommitStop:
        commitDraft?.cancel()
        commitDraft = nil
      case .branch(let id):
        call(EditorReply.branch(id: id, GitHead.branch(inFolder: root)))
      case .branches(let id):
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
          let list = GitBranches.list(root: root)
          DispatchQueue.main.async { [weak self] in self?.call(EditorReply.branches(id: id, list)) }
        }
      case .switchBranch(let id, let name, let create, let remote):
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
          let error = GitBranches.switchBranch(root: root, to: name, create: create, remote: remote)
          DispatchQueue.main.async { [weak self] in self?.call(EditorReply.switchedBranch(id: id, error: error)) }
        }
      case .format(let id, let path, let text, let onSave, let range):
        if onSave && !Prefs.formatOnSave { call(EditorReply.formatSkipped(id: id)); return }
        let root = files.root
        DispatchQueue.global(qos: .userInitiated).async {
          let result = FormatRunner.format(root: root, relative: path, text: text, range: range)
          DispatchQueue.main.async { [weak self] in
            switch result {
            case .success(.prettier(let parser, let options)): self?.call(EditorReply.formatWithPrettier(id: id, parser: parser, options: options))
            case .success(.formatted(let text)): self?.call(EditorReply.formatted(id: id, text: text))
            case .failure(let failure): self?.call(EditorReply.formatFailed(id: id, failure))
            }
          }
        }
      case .askStart(let request):
        asks.start(request)
      case .askFollowUp(let id, let question):
        asks.followUp(id: id, question: question)
      case .askStop(let id):
        asks.stop(id: id)
      case .askClaude(let text, let path):
        AskClaudePanel.shared.ask(selection: text, source: path.map { ($0 as NSString).lastPathComponent })
      case .quickOpen(let id, let query):
        let cached = query.isEmpty ? nil : cachedList
        queue.async { [files] in
          let list = cached ?? files.listFiles()
          let ranked = QuickOpen.rank(query, in: list)
          DispatchQueue.main.async { [weak self] in
            self?.cachedList = list
            self?.call(EditorReply.paths(id: id, ranked))
          }
        }
      }
    }
  }

  // MARK: The Changes panel's git actions

  /// Runs a git action off the main thread and answers the page: done, or git's message.
  private func gitAction(id: Int, _ work: @escaping @Sendable (String) -> String?) {
    let root = self.root
    DispatchQueue.global(qos: .userInitiated).async {
      let error = work(root)
      DispatchQueue.main.async { [weak self] in self?.call(EditorReply.gitDone(id: id, error: error)) }
    }
  }

  /// ✦: Claude (Haiku, no tools) drafts a commit message from the staged diff; it streams into the message box.
  private func startCommitDraft() {
    commitDraft?.cancel()
    let root = self.root
    DispatchQueue.global(qos: .userInitiated).async {
      let context = GitChanges.draftContext(root: root)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard let context, !context.diff.isEmpty else {
          call(EditorReply.commitDraft(.failed(context == nil ? "Not a git repository" : "There are no changes to describe")))
          return
        }
        let prompt = CommitMessage.prompt(diff: context.diff, recent: context.recent, staged: context.staged)
        // A cancelled run sends nothing more, so every event here belongs to the latest draft.
        commitDraft = ClaudeRunner.run(prompt: prompt, tools: [], model: "haiku") { [weak self] event in
          guard let self else { return }
          switch event {
          case .text(let text): call(EditorReply.commitDraft(.text(text)))
          case .tool: break
          case .done(let text): commitDraft = nil; call(EditorReply.commitDraft(.done(text)))
          case .failed(let message): commitDraft = nil; call(EditorReply.commitDraft(.failed(message)))
          }
        }
      }
    }
  }

  // MARK: The page's process

  /// WebKit ended the page's process (memory pressure on a big project, a crash): the page would stay blank, tree and
  /// all. Load it again; it restores the saved session (open files, expanded folders) once it's ready.
  nonisolated public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    MainActor.assumeIsolated {
      NSLog("Glance editor: the page's process ended for %@; reloading", root)
      ready = false
      queued.removeAll()
      known.removeAll()
      notified.removeAll()
      pendingSave?(false)
      pendingSave = nil
      webView.reload()
    }
  }

  // MARK: Links clicked in the preview

  /// A link clicked in the Markdown or HTML preview: a project file opens in a tab, a web or mail link in the default
  /// app, and an anchor on the same page just scrolls. Nothing else navigates.
  nonisolated public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                                  decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    MainActor.assumeIsolated {
      // A link in the page itself targets the main frame; one in a preview targets its frame (or a new window).
      guard action.navigationType == .linkActivated, action.targetFrame?.isMainFrame != true,
            let url = action.request.url else {
        decisionHandler(.allow)
        return
      }
      switch url.scheme?.lowercased() {
      case "about":
        decisionHandler(.allow)
      case PreviewFiles.scheme:
        decisionHandler(.cancel)
        if let path = PreviewFiles.path(from: url) { open(path: path) }
      case "http", "https", "mailto":
        decisionHandler(.cancel)
        NSWorkspace.shared.open(url)
      default:
        decisionHandler(.cancel)
      }
    }
  }

  private func finishRead(id: Int, result: Result<FileService.Document, Error>) {
    switch result {
    case .success(let document):
      known[document.path] = document.modified
      notified[document.path] = nil
      call(EditorReply.opened(id: id, document))
    case .failure(let error):
      call(EditorReply.failed(id: id, Self.failure(error)))
    }
  }

  private func finishSave(id: Int, path: String, result: Result<Double, Error>) {
    switch result {
    case .success(let modified):
      known[path] = modified
      notified[path] = nil
      call(EditorReply.saved(id: id, modified: modified))
    case .failure(let error):
      call(EditorReply.failed(id: id, Self.failure(error)))
    }
  }

  private static func searchFailure(id: Int, _ error: Error) -> String {
    if let search = error as? SearchError { return EditorReply.failed(id: id, code: search.code, message: search.message) }
    return EditorReply.failed(id: id, failure(error))
  }

  private static func failure(_ error: Error) -> FileService.Failure {
    (error as? FileService.Failure) ?? .io(error.localizedDescription)
  }
}
