import AppKit
import GlanceCore

/// Typing into the terminal a Glance view shows: the same paste-then-Return the orb channel uses, and Esc to stop.
@MainActor
enum SessionInput {
    static func send(_ text: String, to surface: UUID) -> Bool {
        OrbChannelStudio.type(text, intoSurface: surface.uuidString)
    }

    /// The board's reply: as `send`, but `beforeReturn` is asked just before Return and can hold it back or wait for the
    /// text to be drawn. False when nothing was pasted. Once pasted, `done` says whether Return went; if not the text stays
    /// on the line, which is harmless.
    static func send(_ text: String, to surface: UUID, beforeReturn: @escaping () -> BoardReply.ReturnGate, done: @escaping (Bool) -> Void) -> Bool {
        OrbChannelStudio.type(text, intoSurface: surface.uuidString, beforeReturn: beforeReturn, finished: done)
    }

    static func interrupt(_ surface: UUID) -> Bool {
        guard let view = (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: surface) else { return false }
        SurfaceScreen.send([.escape], to: view)
        return true
    }

    /// Types `claude` into the split's shell, with `prompt` as its first message when there is one, and the worktree
    /// `recap` ahead of it when `asContext`. False when the terminal couldn't take it, or the message was refused (with the
    /// command center on, `RecapText.firstMessage` has already said why to a caller that asked it).
    static func startClaude(in surface: UUID, prompt: String? = nil, recap: WorktreeRecap? = nil, asContext: Bool = false) -> Bool {
        guard case .success(let line) = claudeCommand(prompt: prompt, recap: recap, asContext: asContext) else { return false }
        return send(line, to: surface)
    }

    /// Why text meant for a shell mustn't be typed into this split now (a Claude or an editor is in front, or it can't be
    /// told); nil when it is at a shell. `action` is a gerund for the reason ("resuming").
    static func typingRefusal(in surface: UUID, action: String) -> String? {
        guard let view = (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: surface),
              let pid = view.surfaceModel?.foregroundPID, let process = ProcessArguments.read(pid: pid) else {
            return TerminalProgram.refusal(.unknown, action: action)
        }
        return TerminalProgram.refusal(TerminalProgram.state(executable: process.executable, arguments: process.arguments), action: action)
    }

    /// A new tab in `folder` with the Glance view over a plain shell (no `claude`), for a view that shows something before a
    /// session starts. Nil when the folder isn't there or the tab couldn't open.
    static func blankTab(folder: String?, beside window: NSWindow?) -> TerminalController? {
        var isDirectory: ObjCBool = false
        guard let folder, FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
              let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder
        return TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
    }

    /// A new tab beside `window` in `folder`, running `claude` and showing its Glance view. False when it couldn't open.
    static func newSessionTab(folder: String, beside window: NSWindow?) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
              let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return false }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder
        config.initialInput = bareCommand + "\n"
        guard let controller = TerminalController.newTab(ghostty, from: window, withBaseConfig: config) else { return false }
        controller.glanceSessionModel().claudeLaunched()
        GlanceMode.set(true, in: controller)
        return true
    }

    /// A new tab in `folder` resuming `session`, showing its Glance view. False when it couldn't open.
    static func resumeTab(session: String, folder: String, beside window: NSWindow?) -> Bool {
        // Only a real session id is typed into the shell.
        guard UUID(uuidString: session) != nil,
              let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return false }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder
        config.initialInput = "claude --resume \(session)\n"
        guard let controller = TerminalController.newTab(ghostty, from: window, withBaseConfig: config) else { return false }
        controller.glanceSessionModel().claudeLaunched()
        GlanceMode.set(true, in: controller)
        return true
    }

    /// `claude`, with the channel flag when that switch is on.
    private static var bareCommand: String {
        OrbChannelStudio.launchesWithChannel ? ChannelLaunch.command(prompt: nil) : "claude"
    }

    /// `claude` (with the channel flag when that switch is on), and `prompt` quoted as its first message. With the
    /// command center on that is `RecapText.startCommand`, the tested builder: the text is made safe, the recap goes
    /// ahead of it when asked, and a message too long for a command line is refused. With it off the line is as it was.
    private static func claudeCommand(prompt: String?, recap: WorktreeRecap? = nil, asContext: Bool = false) -> Result<String, RecapText.Refusal> {
        let channel = OrbChannelStudio.launchesWithChannel
        guard let prompt else { return .success(bareCommand) }
        guard StudioFeatures.shared.isOn(.commandCenter) else {
            return .success(channel ? ChannelLaunch.command(prompt: prompt) : "claude " + AutomationTemplate.shellQuoted(prompt))
        }
        return RecapText.startCommand(recap: recap, asContext: asContext, text: prompt, channel: channel)
    }
}

extension Notification.Name {
    static let glanceSessionLinksChanged = Notification.Name("dev.glance.sessionLinksChanged")
    static let glancePromptsChanged = Notification.Name("dev.glance.promptsChanged")
}
