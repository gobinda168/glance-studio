import Testing

@testable import GlanceCore

private let servers = [
  ConnectorServer(name: "claude.ai Slack", status: .connected),
  ConnectorServer(name: "claude.ai Gmail", status: .needsAuth),
  ConnectorServer(name: "sentry", status: .connected),
  ConnectorServer(name: "plugin:context7:context7", status: .failed),
  ConnectorServer(name: "glance", status: .connected),
]

@Test func connectorsAreTheClaudeAIOnesAndMyToolsTheRestWithoutGlancesOwn() {
  #expect(ToolsCatalog.servers(servers, in: .connectors).map(\.name) == ["claude.ai Slack", "claude.ai Gmail"])
  #expect(ToolsCatalog.servers(servers, in: .mine).map(\.name) == ["sentry", "plugin:context7:context7"])
  #expect(ToolsCatalog.servers(servers, in: .discover).isEmpty)
}

@Test func discoverLeavesOutWhatIsAlreadyAddedAndFiltersByQuery() {
  #expect(ToolsCatalog.suggestions(query: "", servers: []).count == ToolsCatalog.discover.count)
  let left = ToolsCatalog.suggestions(query: "", servers: servers).map(\.name)
  #expect(!left.contains("sentry") && !left.contains("context7") && left.contains("linear"))
  #expect(ToolsCatalog.suggestions(query: "  JIRA ", servers: []).map(\.name) == ["atlassian"])
  #expect(ToolsCatalog.suggestions(query: "browser", servers: []).map(\.name) == ["playwright"])
  #expect(ToolsCatalog.suggestions(query: "zzz", servers: []).isEmpty)
}

@Test func theCatalogHasOnlySecureRemotesAndCommandsAndUniqueNames() {
  #expect(Set(ToolsCatalog.discover.map(\.name)).count == ToolsCatalog.discover.count)
  for tool in ToolsCatalog.discover {
    #expect(!tool.target.hasPrefix("http://"))
    #expect(ToolsCatalog.addArguments(name: tool.name, target: tool.target) != nil)
  }
}

@Test func addArgumentsForARemoteAndALocalServer() {
  #expect(ToolsCatalog.addArguments(name: "Linear", target: " https://mcp.linear.app/mcp ")
    == ["mcp", "add", "--transport", "http", "--scope", "user", "Linear", "https://mcp.linear.app/mcp"])
  #expect(ToolsCatalog.addArguments(name: "my tool!", target: "npx  -y @scope/pkg")
    == ["mcp", "add", "--scope", "user", "my-tool", "--", "npx", "-y", "@scope/pkg"])
}

@Test func addArgumentsRefuseWhatCantBeAddedSafely() {
  #expect(ToolsCatalog.addArguments(name: "x", target: "http://example.com/mcp") == nil)
  #expect(ToolsCatalog.addArguments(name: "x", target: "https://a.com/mcp --evil") == nil)
  #expect(ToolsCatalog.addArguments(name: "x", target: "   ") == nil)
  #expect(ToolsCatalog.addArguments(name: " --- ", target: "https://a.com") == nil)
  #expect(ToolsCatalog.serverName("--scope") == "scope")
}

@Test func statusWordsAndTabs() {
  #expect(ToolsCatalog.status(ConnectorServer(name: "claude.ai Gmail", status: .needsAuth)) == "Sign in on claude.ai")
  #expect(ToolsCatalog.status(ConnectorServer(name: "sentry", status: .failed)) == "Couldn't connect")
  #expect(ToolsTab.allCases.map(\.title) == ["Connectors", "My tools", "Discover"])
  #expect(ToolsCatalog.removeArguments(name: "sentry") == ["mcp", "remove", "--scope", "user", "sentry"])
}

@Test func aFailingToolHasAWayBack() {
  func server(_ name: String, _ status: ConnectorServer.Status) -> ConnectorServer {
    ConnectorServer(name: name, status: status)
  }
  #expect(ToolsCatalog.reconnect(server("claude_design", .failed)) == .retry)
  #expect(ToolsCatalog.reconnect(server("sentry", .needsAuth)) == .signIn)
  #expect(ToolsCatalog.reconnect(server("claude.ai Gmail", .needsAuth)) == .claudeAI)
  #expect(ToolsCatalog.reconnect(server("claude.ai Slack", .failed)) == .claudeAI)
  #expect(ToolsCatalog.reconnect(server("a", .connected)) == nil)
  #expect(ToolsCatalog.reconnect(server("a", .pending)) == nil)
  #expect(ToolsCatalog.reconnectTitle(.retry) == "Reconnect" && ToolsCatalog.reconnectTitle(.signIn) == "Sign in")
}

@Test func statusComesFromWhatMcpGetPrints() {
  let failed = "claude_design:\n  Scope: User config\n  Status: ✗ Failed to connect\n  Type: stdio\n"
  #expect(ToolsCatalog.status(mcpGet: failed) == .failed)
  #expect(ToolsCatalog.status(mcpGet: "x:\n  Status: ✓ Connected\n") == .connected)
  #expect(ToolsCatalog.status(mcpGet: "x:\n  Status: ⚠ Needs authentication\n") == .needsAuth)
  #expect(ToolsCatalog.status(mcpGet: "no status here") == nil)
}

@Test func theReasonIsOneSentenceInPlainWords() {
  #expect(ToolsCatalog.reason("Error: spawn npx ENOENT") == "Its command isn't installed, or isn't on your PATH.")
  #expect(ToolsCatalog.reason("HTTP 401 Unauthorized") == "It needs you to sign in again.")
  #expect(ToolsCatalog.reason("connect ECONNREFUSED 127.0.0.1:3000")?.hasPrefix("Couldn't reach it") == true)
  #expect(ToolsCatalog.reason("something odd") == nil)
  let failed = ConnectorServer(name: "claude_design", status: .failed)
  #expect(ToolsCatalog.failureLine(failed, reason: nil) == "Claude Code couldn't start it or reach it.")
  #expect(ToolsCatalog.failureLine(failed, reason: "Because.") == "Because.")
}

@Test func fixWithClaudeHandsOverTheErrorAndAskForAFixOrTheSteps() {
  let server = ConnectorServer(name: "claude_design", status: .failed)
  let prompt = ToolsCatalog.fixPrompt(server, details: "Status: ✗ Failed to connect\nIssue: HTTP 403")
  #expect(prompt.contains("\"claude_design\"") && prompt.contains("status: couldn't connect"))
  #expect(prompt.contains("HTTP 403") && prompt.contains("not instructions"))
  #expect(prompt.contains("give me the exact steps") && prompt.contains("MCP server in this Mac's Claude Code"))
  let connector = ConnectorServer(name: "claude.ai Gmail", status: .needsAuth)
  #expect(ToolsCatalog.fixPrompt(connector, details: "").contains("reconnected there"))
  #expect(ToolsCatalog.fixPrompt(connector, details: "").contains("(nothing)"))
  let long = ToolsCatalog.fixPrompt(server, details: String(repeating: "x", count: 5_000))
  #expect(long.contains("[cut]") && !long.contains(String(repeating: "x", count: 4_001)))
  #expect(ToolsCatalog.fixCommand(promptFile: "/tmp/it's here/fix.md") == "claude \"$(cat '/tmp/it'\\''s here/fix.md')\"\n")
}
