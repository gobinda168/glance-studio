import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Where the tab is for one window's top bar: its worktree or checkout and branch, with Create PR. Polls like
/// `WorkingChangesModel` (every 3 s while the window is key) and only for terminals and editors; the location is nil, so
/// the bar hides, outside a repo, and `summary` is nil, so Create PR hides, on the base branch, a detached HEAD, and a
/// branch with nothing against the base.
@MainActor
final class BranchBarModel: ObservableObject {
    @Published private(set) var location: TabLocation.Location?
    @Published private(set) var base: String?
    @Published private(set) var summary: BranchSummary.Summary?

    private weak var window: NSWindow?
    private var timer: Timer?
    private var reading = false
    private var tokens: [NSObjectProtocol] = []

    init(window: NSWindow) {
        self.window = window
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePolling() }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePolling() }
            })
        }
        Task { @MainActor [weak self] in self?.updatePolling() }
    }

    deinit {
        timer?.invalidate()
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    private func updatePolling() {
        timer?.invalidate()
        timer = nil
        guard let window, window.isKeyWindow, NSApp.isActive else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        self.timer = timer
        refresh()
    }

    private func refresh() {
        guard !reading, let window else { return }
        let kind = TabSidebarModel.kind(for: window)
        guard kind == .terminal || kind == .editor,
              let path = (window.windowController as? GlancePaneOwner)?.glanceDirectory, !path.isEmpty else {
            apply(location: nil, base: nil, summary: nil)
            return
        }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let location = TabLocation.read(folder: path)
            let found = location == nil ? nil : BranchSummary.read(folder: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.reading = false
                    self.apply(location: location, base: found?.base, summary: found?.summary)
                }
            }
        }
    }

    private func apply(location: TabLocation.Location?, base: String?, summary: BranchSummary.Summary?) {
        if self.location != location { self.location = location }
        if self.base != base { self.base = base }
        if self.summary != summary { self.summary = summary }
    }

    /// Create PR: the project's New pull request tab, which reads the project's own branch.
    func createPullRequest() {
        guard let window, let folder = (window.windowController as? GlancePaneOwner)?.glanceDirectory,
              !folder.isEmpty else { return }
        NewPullRequestWindowController.open(root: ProjectRoot.find(from: folder), from: window)
    }
}

/// "▤ rotate-refresh · ⎇ priya/rotate-refresh  [Create PR]" in a glass capsule: a stack for a linked worktree, a folder for
/// the main checkout. Always shown in a repo, so the Changes item beside it never counts lines in an unnamed place. No
/// line counts here: the branch's whole diff against the base read like unsaved work.
struct BranchBarItem: View {
    @ObservedObject var model: BranchBarModel

    var body: some View {
        if let location = model.location {
            let sentence = location.sentence(base: model.base)
            HStack(spacing: 6) {
                Image(systemName: location.isLinkedWorktree ? "square.stack.3d.up" : "folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GlassChrome.ink2)
                Text(location.folder)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(GlassChrome.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 130)
                Circle()
                    .fill(GlassChrome.ink2)
                    .frame(width: 2.5, height: 2.5)
                    .opacity(0.8)
                BranchChip(location.head.label, size: 11, truncation: .middle, tooltip: sentence)
                    .frame(maxWidth: 180)
                if let summary = model.summary {
                    Button { model.createPullRequest() } label: {
                        Text("Create PR")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 20)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(ChromeButtonStyle(resting: true))
                    .help("Raise a pull request for \(summary.branch)")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, model.summary == nil ? 6 : 2)
            .frame(height: 24)
            .glassSurface(Capsule(style: .continuous), solid: Color(nsColor: .controlBackgroundColor))
            .padding(.horizontal, 2)
            .help(sentence)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(sentence)
        } else {
            // The toolbar drops zero-sized items, so keep a sliver.
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
