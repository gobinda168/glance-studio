import AppKit
import Combine
import GlanceCore
import GlanceKit
import SwiftUI

/// The window controller of the Home tab: Glance Studio's start screen (GlanceKit's `HomeView`) with the tab sidebar
/// and the Glance pane. One per tab group. It follows the group's terminal, so the pane, its sidebar row and the page
/// show that terminal's folder. Nothing to save, so closing it never asks.
@MainActor
final class HomeWindowController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner, ObservableObject {
    let model = HomeModel()
    var tabKind: String { HomeTabs.kind }
    var tabKey: String { HomeTabs.kind }
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    var glanceDirectory: String? { HomeTabs.terminal(near: window)?.glanceDirectory }

    private var cancellables: Set<AnyCancellable> = []
    private var pendingUpdate: DispatchWorkItem?
    /// An update is reading the disk: one at a time, and whatever changes meanwhile gets one more after it.
    private var updating = false
    private var updateAgain = false
    private var closed = false

    init() {
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.title = "Home"
        window.contentView = HomeHostingView(rootView: HomeTabView(controller: self))
        model.onAction = { [weak self] action in self?.perform(action) }
        // Plan usage, Claude's status, the tabs and their folders, and the pane: the page shows them all.
        PlanUsageModel.shared.$reading
            .sink { [weak self] _ in self?.setNeedsUpdate() }
            .store(in: &cancellables)
        TabSidebarModel.shared.rowsChange.$revision
            .sink { [weak self] _ in self?.setNeedsUpdate() }
            .store(in: &cancellables)
        GlanceLayoutModel.shared.$paneRevision
            .sink { [weak self] _ in self?.setNeedsUpdate() }
            .store(in: &cancellables)
        setNeedsUpdate(evenHidden: true) // the first state, so the page is ready before it's shown
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: The page

    /// This tab is selected in the key window, and the window is on screen: the page runs its animations only then.
    private var isActive: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.occlusionState.contains(.visible)
    }

    private func activityChanged() {
        model.isActive = isActive
        setNeedsUpdate()
    }

    /// Something the page shows may have changed: it gets a new state shortly while it's in front, else when it's
    /// back. `evenHidden` is for the page's first state and its own switch.
    private func setNeedsUpdate(evenHidden: Bool = false) {
        guard !closed, evenHidden || isActive else { return }
        if updating {
            updateAgain = true
        } else if pendingUpdate == nil {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.update() } }
            pendingUpdate = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
    }

    private func update() {
        pendingUpdate = nil
        updating = true
        let now = Date()
        let state = HomeState(
            version: AppVersion.current.version ?? "dev",
            greetingName: HomeState.greetingName(fullName: NSFullUserName()),
            showAtLaunch: Prefs.showHomeAtLaunch,
            editorName: EditorTabs.preferredKind.name,
            paneOpen: glancePaneOpen,
            folder: nil,
            claude: HomeTabs.claudeStatus(near: window),
            usage: PlanUsageModel.shared.reading.map { HomeState.Usage($0.usage, now: now) },
            recent: [])
        let recounted: @MainActor () -> Void = { [weak self] in self?.setNeedsUpdate() }
        HomeTabs.readDisk(directory: glanceDirectory, now: now, recounted: recounted) { [weak self] folder, recent in
            guard let self else { return }
            self.updating = false
            var full = state
            full.folder = folder
            full.recent = recent
            self.model.push(full)
            if self.updateAgain {
                self.updateAgain = false
                self.setNeedsUpdate(evenHidden: true)
            }
        }
    }

    /// Return and Esc reach the page without a click first.
    private func focusPage() {
        guard let window, window.isKeyWindow, let content = window.contentView else { return }
        window.makeFirstResponder(content)
        model.requestFocus()
    }

    private func perform(_ action: HomeAction) {
        switch action {
        case .newTerminal:
            HomeTabs.newTerminal(near: window)
        case .focusTerminal:
            HomeTabs.focusTerminal(near: window)
        case .newEditor:
            GlanceTerminalHost.shared.newEditorTab()
        case .openProject(let path, let target):
            if !HomeTabs.open(project: path, in: target, near: window) { setNeedsUpdate() } // gone: the list drops it
        case .toggleGlance:
            GlanceTerminalHost.shared.toggleGlance(in: window)
        case .settings:
            SettingsTabController.open(from: window)
        case .setShowAtLaunch(let on):
            Prefs.showHomeAtLaunch = on
            setNeedsUpdate(evenHidden: true)
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
        if window?.firstResponder === window { focusPage() }
        activityChanged()
    }

    func windowDidResignKey(_ notification: Notification) { activityChanged() }

    func windowDidChangeOcclusionState(_ notification: Notification) { activityChanged() }

    func windowWillClose(_ notification: Notification) {
        closed = true
        cancellables.removeAll()
        pendingUpdate?.cancel()
        pendingUpdate = nil
        model.onAction = nil
        model.isActive = false
        GlanceTabHost.closed(self)
        // The view holds this controller, which holds the window: once it has closed, let go of the view.
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}

/// Home's content: a click works even while its window is in back, as it did on the old web page.
private final class HomeHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
