import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Tools side bar (spec 2026-10-12-agents-tools-design.md): what Claude Code, and so the agents, can reach, in three
/// tabs. Connectors are the apps added on claude.ai, My tools the MCP servers added to Claude Code on this Mac (add
/// one by address or command, remove it), and Discover a short list of popular ones to add in a click. The servers and
/// their status come from `ConnectorProbe`, as in Settings → Connectors.
struct ToolsSidebarView: View {
    @ObservedObject private var probe = ConnectorProbe.shared
    @State private var tab = ToolsTab.connectors
    @State private var query = ""
    @State private var window: NSWindow?
    /// Names being added or removed: their buttons wait.
    @State private var busy: Set<String> = []
    @State private var note: String?
    @State private var newName = ""
    @State private var newTarget = ""
    /// Servers being asked about again (Reconnect), what Claude Code printed about each failing one, and the rows
    /// whose details are open.
    @State private var reconnecting: Set<String> = []
    @State private var printed: [String: String] = [:]
    @State private var open: Set<String> = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(title: "Tools") {
                SidebarIconButton(icon: .refresh, label: "Check again") { probe.check(force: true) }
            }
            tabs
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tab.line)
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                    if let note { noteRow(note) }
                    if !probe.checked || probe.checking && probe.servers.isEmpty {
                        Text("Asking Claude Code which tools it has…")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .padding(.horizontal, 10)
                    } else if let error = probe.error {
                        Text(error)
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.danger)
                            .padding(.horizontal, 10)
                    }
                    switch tab {
                    case .connectors: connectors
                    case .mine: mine
                    case .discover: discover
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { window = $0 })
        .onAppear { probe.check() }
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(ToolsTab.allCases, id: \.self) { item in
                Button {
                    tab = item
                    note = nil
                } label: {
                    Text(item.title)
                        .font(.studio(11.5, .medium))
                        .foregroundStyle(tab == item ? StudioColors.ink : StudioColors.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tab == item ? StudioColors.selection : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
    }

    // MARK: Connectors

    @ViewBuilder private var connectors: some View {
        let servers = ToolsCatalog.servers(probe.servers, in: .connectors)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(servers) { server in
                ToolRow(title: server.title, detail: detail(server), tone: tone(server)) {
                    Button("Manage on claude.ai") { openClaudeAI() }
                } footer: {
                    fixRow(server)
                }
            }
            if servers.isEmpty && probe.checked {
                emptyNote("No connectors yet. Add apps like Slack, Gmail or Jira on claude.ai and they show up here.")
            }
        }
        HStack(spacing: 8) {
            StudioButton(title: "Open claude.ai Connectors") { openClaudeAI() }
        }
        .padding(.horizontal, 10)
        Button("Atlassian and other sign-ins in Settings") { ConnectorsSettings.open() }
            .buttonStyle(.plain)
            .font(.studio(12, .medium))
            .foregroundStyle(StudioColors.coralInk)
            .padding(.horizontal, 10)
    }

    // MARK: My tools

    @ViewBuilder private var mine: some View {
        let servers = ToolsCatalog.servers(probe.servers, in: .mine)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(servers) { server in
                ToolRow(title: server.name, detail: detail(server), tone: tone(server)) {
                    Button("Remove") { remove(server.name) }
                        .disabled(busy.contains(server.name))
                } footer: {
                    fixRow(server)
                }
            }
            if servers.isEmpty && probe.checked {
                emptyNote("None yet. Add an MCP server below, or pick one in Discover.")
            }
        }
        addForm
    }

    /// A name and an https address (a remote server) or a command (a local one).
    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption("Add a tool")
            field("Name", text: $newName)
            field("https://… or a command like npx -y pkg", text: $newTarget)
            StudioButton(title: "Add to Claude Code", busy: busy.contains("new"),
                         enabled: ToolsCatalog.addArguments(name: newName, target: newTarget) != nil) {
                add(name: newName, target: newTarget, key: "new") {
                    newName = ""
                    newTarget = ""
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: Discover

    @ViewBuilder private var discover: some View {
        let found = ToolsCatalog.suggestions(query: query, servers: probe.servers)
        field("Search tools", text: $query)
            .padding(.horizontal, 10)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(found) { tool in
                ToolRow(title: tool.title, detail: tool.summary, tone: nil) {
                    Button("Add to Claude Code") { add(name: tool.name, target: tool.target, key: tool.name) {} }
                        .disabled(busy.contains(tool.name))
                } footer: {
                    EmptyView()
                }
            }
            if found.isEmpty {
                emptyNote(query.trimmingCharacters(in: .whitespaces).isEmpty
                          ? "Everything here is already added."
                          : "Nothing matches “\(query.trimmingCharacters(in: .whitespaces))”.")
            }
        }
        Button("Browse more on claude.ai") { openClaudeAI() }
            .buttonStyle(.plain)
            .font(.studio(12, .medium))
            .foregroundStyle(StudioColors.coralInk)
            .padding(.horizontal, 10)
    }

    // MARK: Pieces

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.studio(12))
            .foregroundStyle(StudioColors.ink)
            .focused($fieldFocused)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
            .accessibilityLabel(placeholder)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.studio(12))
            .foregroundStyle(StudioColors.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(.studio(12))
            .foregroundStyle(StudioColors.body)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(StudioColors.chip))
            .padding(.horizontal, 4)
    }

    /// The row's second line: the status, and for a failing server why, in words.
    private func detail(_ server: ConnectorServer) -> String {
        guard ToolsCatalog.reconnect(server) != nil else { return ToolsCatalog.status(server) }
        if reconnecting.contains(server.name) { return "Reconnecting…" }
        return ToolsCatalog.failureLine(server, reason: printed[server.name].flatMap(ToolsCatalog.reason))
    }

    /// Under a failing server: Reconnect (or Sign in), Details, and what Claude Code printed.
    @ViewBuilder private func fixRow(_ server: ConnectorServer) -> some View {
        if let action = ToolsCatalog.reconnect(server) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StudioButton(title: ToolsCatalog.reconnectTitle(action), icon: .refresh, style: .secondary,
                                 busy: reconnecting.contains(server.name), height: 26) {
                        reconnect(server, action)
                    }
                    if action != .retry {
                        StudioButton(title: "Check again", style: .quiet, busy: reconnecting.contains(server.name),
                                     height: 26) { ensureCheck(server) }
                    }
                    StudioButton(title: open.contains(server.name) ? "Hide details" : "Details", style: .quiet, height: 26) {
                        toggleDetails(server)
                    }
                }
                if open.contains(server.name) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(printed[server.name] ?? "Asking Claude Code…")
                            .font(.studioMono(11))
                            .foregroundStyle(StudioColors.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
                        if let text = printed[server.name], !text.isEmpty {
                            HStack(spacing: 14) {
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                }
                                .buttonStyle(.plain)
                                .help("Copy what Claude Code printed")
                                Button("Fix with Claude") { fixWithClaude(server, text) }
                                    .buttonStyle(.plain)
                                    .help("Open Claude Code in a new terminal tab with this error, to fix it or give "
                                          + "you the steps")
                            }
                            .font(.studio(11.5, .medium))
                            .foregroundStyle(StudioColors.coralInk)
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func tone(_ server: ConnectorServer) -> AutomationTone {
        switch server.status {
        case .connected: .ok
        case .needsAuth, .pending: .waiting
        case .failed: .failed
        case .other: .neutral
        }
    }

    // MARK: Actions

    private func openClaudeAI() {
        BrowserTabController.open(url: ConnectorsSettings.claudeConnectors, from: window)
    }

    private func add(name: String, target: String, key: String, done: @escaping () -> Void) {
        guard busy.insert(key).inserted else { return }
        note = nil
        probe.addTool(name: name, target: target) { error in
            busy.remove(key)
            if let error { note = error; return }
            done()
            tab = .mine
            note = "Added \(ToolsCatalog.serverName(name) ?? name). If it needs a sign-in, run /mcp in Claude Code and "
                + "pick it, then check again."
        }
    }

    /// Retry asks Claude Code about the server again; Sign in opens Claude Code's /mcp menu in a terminal tab (the
    /// way Settings → Connectors adds Atlassian); claude.ai connectors are reconnected on claude.ai.
    private func reconnect(_ server: ConnectorServer, _ action: ToolsCatalog.Reconnect) {
        note = nil
        switch action {
        case .claudeAI:
            openClaudeAI()
            note = "Reconnect \(server.title) there, then press Check again."
        case .signIn:
            EditorBridgeActions.openTerminalTab(cwd: NSHomeDirectory(), near: window, input: "claude \"/mcp\"\n")
            note = "In the new terminal tab, choose \(server.name) and Authenticate. Then come back and press "
                + "Check again."
        case .retry:
            ensureCheck(server)
        }
    }

    /// Asks again; if it still isn't connected the details open with what Claude Code said.
    private func ensureCheck(_ server: ConnectorServer) {
        guard reconnecting.insert(server.name).inserted else { return }
        probe.recheck(name: server.name) { text in
            reconnecting.remove(server.name)
            if let text { printed[server.name] = text }
            let now = probe.servers.first { $0.name == server.name }
            if now?.status == .connected {
                open.remove(server.name)
                note = "\(server.title) is connected."
            } else if text != nil {
                open.insert(server.name)
            }
        }
    }

    /// Claude Code starts in a new terminal tab with the error and what to do (fix it, or the steps). The prompt goes
    /// through a file in the scratch folder so its lines and quotes reach `claude` as one argument.
    private func fixWithClaude(_ server: ConnectorServer, _ details: String) {
        let prompt = ToolsCatalog.fixPrompt(server, details: details)
        let name = ToolsCatalog.serverName(server.name) ?? "tool"
        let file = (ClaudeOneShot.scratchFolder as NSString).appendingPathComponent("fix-\(name).md")
        do {
            try prompt.write(toFile: file, atomically: true, encoding: .utf8)
        } catch {
            note = "Couldn't prepare the request: \(error.localizedDescription)"
            return
        }
        EditorBridgeActions.openTerminalTab(cwd: NSHomeDirectory(), near: window,
                                            input: ToolsCatalog.fixCommand(promptFile: file))
        note = "Claude Code is open in a new terminal tab with the error. Press Reconnect here once it's fixed."
    }

    private func toggleDetails(_ server: ConnectorServer) {
        if open.remove(server.name) != nil { return }
        open.insert(server.name)
        guard printed[server.name] == nil else { return }
        probe.recheck(name: server.name) { text in printed[server.name] = text ?? "Claude Code printed nothing." }
    }

    private func remove(_ name: String) {
        guard busy.insert(name).inserted else { return }
        note = nil
        probe.removeTool(name: name) { error in
            busy.remove(name)
            if let error { note = error }
        }
    }
}

/// A tool in a list: its status glyph (none in Discover), name and one line, a menu of what to do with it, and under
/// it whatever fixes it (Reconnect, details).
private struct ToolRow<Actions: View, Footer: View>: View {
    let title: String
    let detail: String
    let tone: AutomationTone?
    @ViewBuilder var actions: Actions
    @ViewBuilder var footer: Footer
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let tone {
                AutomationStatusGlyph(tone: tone, size: 11)
                    .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.studio(12.5, .medium))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.studio(11.5))
                    .foregroundStyle(tone == .failed ? StudioColors.danger : StudioColors.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                footer
            }
            Spacer(minLength: 0)
            Menu {
                actions
            } label: {
                StudioIcon(.more, size: 14).foregroundStyle(StudioColors.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(title)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}
