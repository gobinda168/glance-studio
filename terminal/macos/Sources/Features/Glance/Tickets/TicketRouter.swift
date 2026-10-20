import AppKit
import GlanceCore
import GlanceKit

/// Where a ticket goes: its page (in Studio's Browser when it's on a Jira site Studio knows), or a terminal tab with
/// Claude on it.
@MainActor
enum TicketRouter {
    static func open(_ ticket: Ticket) {
        guard let url = ticket.url else { return NSSound.beep() }
        let host = url.host?.lowercased()
        if let site = AtlassianSessions.shared.store.sites.first(where: { $0.jiraURL?.host?.lowercased() == host }),
           BrowserTabController.openAtlassian(site: site, product: .jira, url: url, from: NSApp.keyWindow) != nil {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Work on this (spec "Tickets page and side bar"): a terminal tab in the ticket's project — its GitHub repository's
    /// folder, else where it was last worked on, else one the user picks — with Claude started on the ticket.
    static func workOn(_ ticket: Ticket, near window: NSWindow?) {
        guard let folder = folder(for: ticket) else { return }
        TicketService.shared.noteWorkOn(ticket.id, folder: folder)
        EditorBridgeActions.openTerminalTab(cwd: folder, near: window, input: "claude \(quoted(prompt(ticket)))\n")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// What Claude is told.
    static func prompt(_ ticket: Ticket) -> String {
        var text = "Work on \(ticket.key): \(ticket.title)."
        if let url = ticket.url { text += " \(url.absoluteString)" }
        return text + " Read the ticket with the tracker tools if you need its details."
    }

    /// Single-quoted for the shell: a ' inside becomes '\''.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func folder(for ticket: Ticket) -> String? {
        if let repository = ticket.repository, let folder = Prefs.repositoryFolders[repository],
           FileManager.default.fileExists(atPath: folder) {
            return folder
        }
        if let folder = TicketService.shared.lastFolder[ticket.id], FileManager.default.fileExists(atPath: folder) {
            return folder
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the project for \(ticket.key)"
        panel.prompt = "Work on It"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
