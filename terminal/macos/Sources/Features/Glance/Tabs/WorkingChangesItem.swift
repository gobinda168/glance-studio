import AppKit
import Combine
import GlanceCore
import SwiftUI

/// What the tab's repo has changed since its last commit, for one window's top bar. It asks git every 3 s while the
/// window is the key window of the app in front, and at once when it becomes key; terminals and editors only (Home,
/// Settings and Chats borrow a nearby terminal's folder; PR pages draw their own diff).
@MainActor
final class WorkingChangesModel: ObservableObject {
    @Published private(set) var summary: WorkingChanges.Summary?
    @Published private(set) var folder = ""

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
        // The window gets its controller (and so its folder) after the toolbar is made.
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
              let path = (window.windowController as? GlancePaneOwner)?.glanceDirectory else {
            if summary != nil { summary = nil }
            return
        }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let found = WorkingChanges.read(folder: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.reading = false
                    let name = FolderLabel.name(forPath: path)
                    if self.folder != name { self.folder = name }
                    if self.summary != found { self.summary = found }
                }
            }
        }
    }
}

/// "▤ 25 · +282 −385" in a glass capsule beside the plan usage: files changed in the mono ink, the lines added green
/// and removed red with their + and − (MASTER §7.4: colour is never the only cue), rolling to new values. Hidden
/// outside a repo and when nothing has changed.
struct WorkingChangesItem: View {
    @ObservedObject var model: WorkingChangesModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let summary = model.summary, !summary.isClean {
            let sentence = summary.sentence(folder: model.folder)
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GlassChrome.ink2)
                number("\(summary.files)", summary.files, GlassChrome.ink)
                Circle()
                    .fill(GlassChrome.ink2)
                    .frame(width: 2.5, height: 2.5)
                    .opacity(0.8)
                number("+\(summary.additions)", summary.additions, GlassChrome.okInk)
                number("\u{2212}\(summary.deletions)", summary.deletions, GlassChrome.criticalInk)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .glassSurface(Capsule(style: .continuous), solid: Color(nsColor: .controlBackgroundColor))
            .padding(.horizontal, 2)
            .animation(reduceMotion ? GlassChrome.fade : .smooth(duration: 0.6), value: summary)
            .help(sentence)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sentence)
        } else {
            // The toolbar drops zero-sized items, so keep a sliver.
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func number(_ text: String, _ value: Int, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(value)))
    }
}
