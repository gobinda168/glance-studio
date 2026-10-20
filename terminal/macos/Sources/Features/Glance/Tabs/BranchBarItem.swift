import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The tab's branch against its base for one window's top bar, with Create PR. Polls like `WorkingChangesModel` (every
/// 3 s while the window is key) and only for terminals and editors; nil, so the bar hides, on the base branch, a
/// detached HEAD, and a branch with nothing against the base.
@MainActor
final class BranchBarModel: ObservableObject {
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
            if summary != nil { summary = nil }
            return
        }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let found = BranchSummary.read(folder: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.reading = false
                    if self.summary != found { self.summary = found }
                }
            }
        }
    }

    /// Create PR: the project's New pull request tab, which reads the project's own branch.
    func createPullRequest() {
        guard let window, let folder = (window.windowController as? GlancePaneOwner)?.glanceDirectory,
              !folder.isEmpty else { return }
        NewPullRequestWindowController.open(root: ProjectRoot.find(from: folder), from: window)
    }
}

/// "⎇ claude/x  [Create PR]" in a glass capsule. No line counts: the Changes item beside it counts what isn't
/// committed yet, and the branch's whole diff against the base read like unsaved work. Hidden when there is nothing to raise.
struct BranchBarItem: View {
    @ObservedObject var model: BranchBarModel

    var body: some View {
        if let summary = model.summary {
            HStack(spacing: 8) {
                BranchChip(summary.branch, size: 11, truncation: .middle)
                    .frame(maxWidth: 220)
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
            .padding(.leading, 6)
            .padding(.trailing, 2)
            .frame(height: 24)
            .glassSurface(Capsule(style: .continuous), solid: Color(nsColor: .controlBackgroundColor))
            .padding(.horizontal, 2)
            .help(summary.sentence())
        } else {
            // The toolbar drops zero-sized items, so keep a sliver.
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
