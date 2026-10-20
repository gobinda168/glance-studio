import AppKit
import GlanceCore
import GlanceKit

/// A terminal's desktop notification (OSC 9 / 777: Claude Code's "needs your permission" and "waiting for your input",
/// a long command finishing) also lands in the Notifications inbox, while that feature is on. Ghostty's App posts
/// `dev.glance.terminalNotification` with the surface as the object, before its own banner.
@MainActor
final class TerminalNoticeTap {
    static let shared = TerminalNoticeTap()
    static let name = Notification.Name("dev.glance.terminalNotification")

    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: Self.name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { TerminalNoticeTap.shared.received(note) }
        }
    }

    /// Runs inside Ghostty's action callback (posted synchronously, delivered on main): never read the split here.
    /// What's known now (the notice, whether its split is in front) is taken here; the inbox / nudge choice waits for
    /// the main-queue hop, where Claude needs you reads the splits.
    private func received(_ note: Notification) {
        guard let view = note.object as? Ghostty.SurfaceView else { return }
        let surface = view.id.uuidString
        let notice = notice(note, view)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // A prompt card already asks (spec 2026-10-11-needs-input-orb-design.md §6): inbox only, no nudge.
                let covered = NeedsYouStudio.shared.noticed(surface: surface)
                guard let notice, StudioFeatures.shared.isOn(.notifications) else { return }
                if covered, notice.kind == .claudeNeedsInput { NotificationHub.shared.add(notice) }
                else { NotificationHub.shared.post(notice) }
            }
        }
    }

    /// The inbox notice for this terminal notification, or nil (empty, or the split the user is looking at already
    /// shows it).
    private func notice(_ note: Notification, _ view: Ghostty.SurfaceView) -> Notice? {
        let title = note.userInfo?["title"] as? String ?? ""
        let body = note.userInfo?["body"] as? String ?? ""
        guard !(title.isEmpty && body.isEmpty) else { return nil }
        if NSApp.isActive, view.focused, view.window?.isKeyWindow == true { return nil }
        return TerminalNotices.notice(surface: view.id.uuidString, cwd: view.pwd, title: title, body: body, at: Date())
    }
}
