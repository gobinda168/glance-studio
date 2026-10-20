import AppKit
import GhosttyKit
import GlanceCore
import GlanceKit

/// Studio's side of the orb channel: starts the hub (feature on, switch on), tells it about splits, and does what
/// only Studio can — focus a session's split, type into it, open a new tab running `claude`.
@MainActor
enum OrbChannelStudio {
    static func start() {
        guard StudioFeatures.shared.isOn(.orbChannel), Prefs.orbChannelEnabled else { return }
        let hub = OrbChannelHub.shared
        hub.resolve = { ChannelSessions.resolve(claudePID: $0) }
        hub.onOpenSession = { focus($0) }
        hub.typeIntoSession = { session, text in session.surface.map { type(text, intoSurface: $0) } ?? false }
        hub.secretsEnabled = { StudioFeatures.shared.isOn(.secrets) }
        hub.onTell = { session, markdown, size, speak, asked in
            GlanceTerminalHost.shared.tell(markdown, size: size, speak: speak, from: session, asked: asked)
        }
        OrbAssistant.shared.glancePath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/glance").path
        OrbAssistantTools.startSession = { folder, prompt in newClaudeTab(folder: folder, prompt: prompt) }
        OrbAssistantTools.openTarget = { openAssistantTarget($0) }
        OrbChannelHub.setOtherSpeech { GlanceTerminalHost.shared.isNarrating }
        let notifications = NotificationHub.shared
        if notifications.onOpen == nil { notifications.onOpen = { NoticeRouter.open($0) } }
        hub.start()
    }

    static func stop() { OrbChannelHub.shared.stop() }

    /// The orb assistant's `open`: a notification's thread, a session's split, or a pull request / issue page.
    private static func openAssistantTarget(_ target: AssistantTarget.Target) -> Bool {
        switch target {
        case .notification(let id):
            guard let row = NotificationHub.shared.book.rows(filter: nil, showDone: true)
                .first(where: { $0.newest.threadKey == id }) else { return false }
            NotificationHub.shared.open(row.newest)
            return true
        case .session(let handle):
            guard let session = OrbChannelHub.shared.book.session(handle: handle) else { return false }
            focus(session)
            return true
        case .pullRequest(let repository, let number):
            NSApp.activate(ignoringOtherApps: true)
            return PullRequestWindowController.open(repository: repository, number: number, root: nil,
                                                    from: SettingsTabController.frontWindow) != nil
        }
    }

    /// Whether Studio starts `claude` with its channel: the feature, the channel and the launch-flag switch all on, and
    /// Glance's MCP server set up in Claude Code (the flag names a server Claude must have). Read at each launch.
    static var launchesWithChannel: Bool {
        guard StudioFeatures.shared.isOn(.orbChannel), Prefs.orbChannelEnabled, Prefs.orbChannelLaunchFlag else {
            return false
        }
        if case .registered = mcpRegistration() { return true }
        return false
    }

    /// Whether Claude Code has Glance's MCP server, from `~/.claude.json`.
    static func mcpRegistration() -> MCPSetup.Status {
        MCPSetup.registered(claudeJSON: FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude.json"))
    }

    static func focus(_ session: ChannelBook.Session) {
        NoticeRouter.open(ChannelNotices.message(id: "focus", label: session.label, surface: session.surface,
                                                 cwd: session.projectDir, title: "", body: nil, date: Date()))
    }

    /// Types `text` and Return into a split (a session without a channel). False when the split is gone.
    static func type(_ text: String, intoSurface surface: String) -> Bool {
        guard let uuid = UUID(uuidString: surface),
              let view = (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: uuid),
              let model = view.surfaceModel else { return false }
        // A paste, then Return a moment later so Claude Code sees a keypress (as sendToProjectClaude does).
        model.sendText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press))
        }
        return true
    }

    /// A new tab in `folder` running `claude` (with the channel flag when that switch is on, and `prompt` as its
    /// first message).
    static func newClaudeTab(folder: String, prompt: String?) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
              let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return false }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder
        let command = launchesWithChannel
            ? ChannelLaunch.command(prompt: prompt)
            : "claude" + (prompt.map { " " + AutomationTemplate.shellQuoted($0) } ?? "")
        config.initialInput = command + "\n"
        _ = TerminalController.newTab(ghostty, from: TerminalController.preferredParent?.window, withBaseConfig: config)
        return true
    }
}
