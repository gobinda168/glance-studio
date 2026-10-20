import AppKit
import Combine
import GlanceCore
import SwiftUI
import WebKit

/// The window controller of a GS Code tab: one project root, VS Code (the local VSCodium server's web workbench)
/// on the left, the Glance pane on the right. Unsaved files are VS Code's business: it backs them up as you type and
/// brings them back next time, so closing the tab never asks.
@MainActor
final class StudioWindowController: NSWindowController, NSWindowDelegate, EditorTab, GlancePaneOwner, ObservableObject {
    let root: String
    let webView: VSCodeWebView
    var tabKind: String { EditorKind.studio.rawValue }
    var editorKind: EditorKind { .studio }
    /// GS Code doesn't tell the app which file is open.
    var currentFile: String? { nil }
    var tabKey: String { root }
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    var glanceDirectory: String? { root }
    /// Claude's latest changed lines in this project, by path relative to the root, sent again on every hello.
    private(set) var claudeMarks: [String: [LineMark]] = [:]
    private var pendingOpen: (command: EditorBridgeCommand, until: Date)?
    /// The files Claude edited in the latest session, sent again on every hello.
    private(set) var claudeFiles: [String] = []

    private let navigation = VSCodeNavigation()
    private var cancellables: Set<AnyCancellable> = []
    private var titleToken: NSKeyValueObservation?
    private var loadedPort: Int?

    init(root: String) {
        self.root = root
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // VS Code keeps settings and unsaved-file backups in it
        configuration.preferences.isElementFullscreenEnabled = true
        webView = VSCodeWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = navigation
        webView.uiDelegate = navigation
        window.contentView = NSHostingView(rootView: StudioTabView(controller: self))
        titleToken = webView.observe(\.title) { [weak self] _, _ in
            Task { @MainActor in self?.updateTitle() }
        }
        updateTitle()
        let server = EditorServerManager.shared
        server.$state
            .sink { [weak self] state in self?.serverChanged(state) }
            .store(in: &cancellables)
        server.ensureRunning()
        GlanceTerminalHost.shared.deliverClaudeChanges(to: self) // a new editor tab starts with the latest marks
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `@Published` hands over the new state before the property changes, so everything comes from `state` itself.
    private func serverChanged(_ state: EditorServerManager.State) {
        guard case .running(let port) = state else {
            loadedPort = nil // after a restart the page loads again
            return
        }
        guard port != loadedPort else { return }
        loadedPort = port
        navigation.port = port
        let url = EditorServer.workbenchURL(port: port, token: EditorServerManager.shared.token, root: root)
        webView.load(URLRequest(url: url))
    }

    private func updateTitle() {
        var page = webView.title ?? ""
        if page.hasSuffix(" — GS Code") { page = String(page.dropLast(" — GS Code".count)) }
        window?.title = page.isEmpty ? "GS Code — " + URL(fileURLWithPath: root).lastPathComponent : page
    }

    /// A file of this project (relative to the root) to show at a line. Sent now if VS Code is connected, else when
    /// its extension host says hello, as long as that's within 20 s.
    func openFile(_ relative: String, line: Int?, column: Int?) {
        window?.tabGroup?.selectedWindow = window
        let command = EditorBridgeCommand.open(path: (root as NSString).appendingPathComponent(relative), line: line, column: column)
        if EditorBridgeServer.shared.send(command, toFolder: root) { return }
        pendingOpen = (command, Date().addingTimeInterval(20))
    }

    func showClaudeChanges(_ marks: [String: [LineMark]]) {
        claudeMarks = marks
        EditorBridgeServer.shared.send(.claudeChanges(marks), toFolder: root)
    }

    /// The tab's extension host connected (or reconnected): give it the marks and any file waiting to open.
    func showClaudeFiles(_ paths: [String]) {
        claudeFiles = paths
        EditorBridgeServer.shared.send(.claudeFiles(paths), toFolder: root)
    }

    func bridgeConnected() {
        EditorBridgeServer.shared.send(.claudeFiles(claudeFiles), toFolder: root)
        EditorBridgeServer.shared.send(.claudeChanges(claudeMarks), toFolder: root)
        if let pending = pendingOpen, pending.until > Date() {
            EditorBridgeServer.shared.send(pending.command, toFolder: root)
        }
        pendingOpen = nil
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
    }

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil) // ends the workbench's connection, so its extension host goes away
        cancellables.removeAll()
        GlanceTabHost.closed(self)
    }
}
