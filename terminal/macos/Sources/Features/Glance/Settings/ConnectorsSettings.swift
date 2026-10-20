import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Settings → Connectors (spec 2026-10-12-connectors-design.md): Atlassian through Claude (its MCP connector) and
/// through Glance (the site sign-in), and every other connector Claude Code reported.
struct ConnectorsSettings: View {
    static let claudeConnectors = URL(string: "https://claude.ai/customize/connectors")!
    static let atlassianMCP = "https://mcp.atlassian.com/v2/mcp"
    static let atlassianWords = ["atlassian", "jira", "confluence"]
    static let named: [(title: String, words: [String])] = [("Linear", ["linear"]), ("GitHub", ["github"]),
                                                            ("Slack", ["slack"])]

    @ObservedObject private var probe = ConnectorProbe.shared
    @State private var window: NSWindow?
    @State private var adding = false
    @State private var note: String?

    /// Shows this page (Tickets' Open Connectors).
    static func open() {
        _ = SettingsTabController.open(section: .connectors, from: SettingsTabController.frontWindow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Atlassian through Claude") {
                SettingsRow(id: "connectors.claude", name: "Jira and Confluence in Claude",
                            detail: claudeDetail, light: light(Self.atlassianWords)) {
                    HStack(spacing: 8) {
                        StudioButton(title: "Open claude.ai Connectors") {
                            BrowserTabController.open(url: Self.claudeConnectors, from: window)
                        }
                        if server(Self.atlassianWords)?.status != .connected {
                            StudioButton(title: "Add to Claude Code", busy: adding) { addAtlassian() }
                        }
                        StudioButton(title: "Check again", icon: .refresh, style: .secondary, busy: probe.checking) {
                            probe.check(force: true)
                        }
                    }
                }
                if let note {
                    Text(note)
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                }
            }
            AtlassianSettings()
            SettingsGroup(title: "Other connectors") {
                ForEach(Self.named, id: \.title) { item in
                    SettingsRow(id: "connectors.\(item.title.lowercased())", name: item.title,
                                detail: words(server(item.words)), light: light(item.words)) {
                        StudioButton(title: "Open claude.ai Connectors") {
                            BrowserTabController.open(url: Self.claudeConnectors, from: window)
                        }
                    }
                }
                ForEach(others) { server in
                    SettingsRow(id: "connectors.others.\(server.name)", name: server.title, detail: words(server),
                                light: server.status == .connected) { EmptyView() }
                }
            }
            .id("connectors.others")
        }
        .background(WindowAccessor { window = $0 })
        .onAppear { probe.check() }
    }

    private var claudeDetail: String {
        if !probe.checked { return "Asking Claude Code which connectors it has…" }
        if let error = probe.error { return error }
        return words(server(Self.atlassianWords))
            + " Claude sessions use it for Jira and Confluence, and Tickets reads through it."
    }

    private func server(_ words: [String]) -> ConnectorServer? {
        probe.servers.first { $0.mentions(words) } ?? probe.servers.first { server in
            probe.trackers.contains { $0.server == server.name && words.contains(where: $0.name.lowercased().contains) }
        }
    }

    /// Servers that aren't Atlassian, Linear, GitHub or Slack, and aren't Glance's own.
    private var others: [ConnectorServer] {
        let known = Self.atlassianWords + Self.named.flatMap(\.words) + ["glance"]
        return probe.servers.filter { !$0.mentions(known) }
    }

    private func light(_ words: [String]) -> Bool? {
        guard probe.checked else { return nil }
        return server(words)?.status == .connected
    }

    private func words(_ server: ConnectorServer?) -> String {
        switch server?.status {
        case .connected: "Connected."
        case .needsAuth: server?.isClaudeAI == true
            ? "Added on claude.ai, waiting for you to sign in: reconnect it in claude.ai Connectors (or run /mcp in "
                + "Claude Code and pick \(server?.name ?? "it")), then Check again."
            : "Added, waiting for you to sign in (run /mcp in Claude Code)."
        case .failed: "Added, but it couldn't connect."
        case .pending: "Connecting…"
        case .other: "Added."
        case nil: probe.checked ? "Not connected." : "Checking…"
        }
    }

    private func addAtlassian() {
        adding = true
        note = nil
        probe.addServer(name: "atlassian", url: Self.atlassianMCP) { error in
            adding = false
            if let error { note = error; return }
            EditorBridgeActions.openTerminalTab(cwd: NSHomeDirectory(), near: window, input: "claude \"/mcp\"\n")
            note = "In the new terminal tab, trust the folder if Claude Code asks, then choose atlassian and "
                + "Authenticate (type /mcp if the list isn't open). Then come back and Check again."
        }
    }
}
