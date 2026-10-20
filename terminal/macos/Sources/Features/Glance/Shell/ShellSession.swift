import AppKit
import Foundation
import GlanceCore

/// One shell connected over the bridge: whose tab it is, its input line as last reported, the command running, and a
/// Tab list being received.
@MainActor
final class ShellSession {
    let connection: ShellBridgeServer.ConnectionID
    let peerPID: pid_t
    private(set) var hello: ShellHello?
    weak var surface: Ghostty.SurfaceView?
    /// When its hello was accepted: the newest open session of a tab is the current one.
    private(set) var acceptedAt: Date?

    /// The input line: its seq, text and cursor (zsh's character positions).
    private(set) var seq = 0
    private(set) var text = ""
    private(set) var cursor = 0
    private(set) var folder = ""
    /// The line is being edited (between a prompt and the command it becomes).
    private(set) var atPrompt = false

    /// The command that started and hasn't ended.
    private(set) var running: (folder: String, start: Double, command: String)?

    /// A Tab list coming in: its request, the line's seq, how many there are in all, the rows so far.
    private(set) var incoming: (request: Int, seq: Int, total: Int, candidates: [CompletionCandidate])?
    /// Tab on a folder: list it once the line shows it inserted.
    var openAfterAccept = false

    /// The shell's command names by kind (`commands`, `aliases`, `functions`, `builtins`), and all of them.
    private var namesByKind: [String: Set<String>] = [:]
    private(set) var names: Set<String> = []
    /// The last command that ran in this shell, and whether the prompt now is the one right after it.
    private(set) var previousCommand: String?
    var justFinished = false
    /// The whole line the ghost text on screen makes (line + suggestion), and the line it was last shown after. Like
    /// the plugin, it stays only while the line grows along it (a backspace makes the plugin drop it).
    var suggested: String?
    var suggestedAfter = ""

    /// The error marks on screen now, so the same ones aren't sent again.
    var marks: [ShellMark] = []
    /// Names looked up on `$PATH` because the shell hadn't hashed them (a tool installed since it started).
    var pathLookups: [String: Bool] = [:]
    /// The command that just failed, with its exit code and output once read: the fixes' input, and Claude's (S5).
    var failure: Failure?
    /// The fix offered for it as ghost text, if any.
    var fix: String?
    /// This shell's last commands with their exit codes (what Claude is told), oldest first.
    private(set) var recent: [(command: String, exit: Int?)] = []

    func setNames(_ kind: String, _ list: [String]) {
        namesByKind[kind] = Set(list)
        names = namesByKind.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        pathLookups = [:]
    }

    /// The shell has sent its command names (marks wait for them, or everything would look unknown).
    var hasNames: Bool { namesByKind["commands"] != nil }

    init(connection: ShellBridgeServer.ConnectionID, peerPID: pid_t) {
        self.connection = connection
        self.peerPID = peerPID
    }

    var isAccepted: Bool { acceptedAt != nil }

    func accept(_ hello: ShellHello, surface: Ghostty.SurfaceView) {
        self.hello = hello
        self.surface = surface
        acceptedAt = Date()
    }

    func prompt(seq: Int, folder: String) {
        self.seq = seq
        self.folder = folder
        text = ""
        cursor = 0
        atPrompt = true
        incoming = nil
    }

    func line(seq: Int, cursor: Int, text: String) {
        self.seq = seq
        self.cursor = cursor
        self.text = text
    }

    /// The cursor is at the end of the line (where ghost text shows).
    var cursorAtEnd: Bool { cursor == text.unicodeScalars.count }

    func exec(folder: String, start: Double, command: String) {
        running = (folder, start, command)
        atPrompt = false
        incoming = nil
        failure = nil
        fix = nil
    }

    /// The command that just ended, with how it went.
    func done(exit: Int, end: Double, tab: String?) -> CommandRecord? {
        defer { running = nil }
        guard let running else { return nil }
        previousCommand = running.command
        justFinished = true
        recent = Array((recent + [(running.command, exit)]).suffix(8))
        if !Corrections.notFailures.contains(exit) {
            failure = Failure(command: running.command, exitCode: exit, output: "", folder: running.folder)
        }
        return CommandRecord(command: running.command, folder: running.folder,
                             start: Date(timeIntervalSince1970: running.start),
                             duration: max(0, end - running.start), exitCode: exit, tab: tab,
                             gitRoot: nil, branch: nil, imported: false)
    }

    func beginCandidates(request: Int, seq: Int, total: Int) {
        incoming = (request, seq, total, [])
    }

    func addCandidate(_ candidate: CompletionCandidate, request: Int) {
        guard incoming?.request == request else { return }
        incoming?.candidates.append(candidate)
    }

    /// The finished Tab list, when `request` is the one being received.
    func endCandidates(request: Int) -> (request: Int, seq: Int, total: Int, candidates: [CompletionCandidate])? {
        defer { incoming = nil }
        guard let incoming, incoming.request == request else { return nil }
        return incoming
    }
}
