import Testing
@testable import GlanceCore

private let initLine = #"""
{"type":"system","subtype":"init","tools":["Bash","mcp__claude_ai_Atlassian__getAccessibleAtlassianResources","mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql","mcp__claude_ai_Atlassian__getJiraIssue","mcp__claude_ai_Atlassian__getTransitionsForJiraIssue","mcp__claude_ai_Atlassian__transitionJiraIssue","mcp__claude_ai_Atlassian__editJiraIssue","mcp__claude_ai_Atlassian__addCommentToJiraIssue","mcp__claude_ai_Atlassian__createJiraIssue","mcp__claude_ai_Atlassian__atlassianUserInfo","mcp__claude_ai_Atlassian__lookupJiraAccountId","mcp__linear__list_issues","mcp__linear__get_issue","mcp__linear__update_issue","mcp__linear__create_comment","mcp__linear__list_issue_statuses","mcp__claude_ai_Slack__slack_send_message","mcp__claude_ai_Slack__slack_read_thread","mcp__github__get_issue","mcp__github__update_issue"],"mcp_servers":[{"name":"claude.ai Atlassian","status":"connected"},{"name":"linear","status":"connected"},{"name":"claude.ai Slack","status":"connected"},{"name":"github","status":"needs-auth"}]}
"""#

@Test func connectedTrackersAreFoundWithTheirTools() throws {
  let trackers = try #require(TrackerProbe.trackers(initLine: initLine))
  #expect(trackers.map(\.server) == ["claude.ai Atlassian", "linear"])
  let jira = trackers[0]
  #expect(jira.readTools == ["mcp__claude_ai_Atlassian__getAccessibleAtlassianResources",
                             "mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql",
                             "mcp__claude_ai_Atlassian__getJiraIssue",
                             "mcp__claude_ai_Atlassian__getTransitionsForJiraIssue",
                             "mcp__claude_ai_Atlassian__atlassianUserInfo",
                             "mcp__claude_ai_Atlassian__lookupJiraAccountId"])
  #expect(jira.moveTools == ["mcp__claude_ai_Atlassian__transitionJiraIssue", "mcp__claude_ai_Atlassian__editJiraIssue"])
  #expect(jira.commentTools == ["mcp__claude_ai_Atlassian__addCommentToJiraIssue"])
  let linear = trackers[1]
  #expect(linear.readTools == ["mcp__linear__list_issues", "mcp__linear__get_issue", "mcp__linear__list_issue_statuses"])
  #expect(linear.moveTools == ["mcp__linear__update_issue"])
  #expect(linear.commentTools == ["mcp__linear__create_comment"])
}

@Test func otherEventsAreNotTheInitEvent() {
  #expect(TrackerProbe.trackers(initLine: #"{"type":"assistant"}"#) == nil)
  #expect(TrackerProbe.trackers(initLine: "garbage") == nil)
  #expect(TrackerProbe.trackers(initLine: #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[]}"#) == [])
}

@Test func toolNamesSplitIntoWords() {
  #expect(TrackerProbe.words("getJiraIssue") == ["get", "jira", "issue"])
  #expect(TrackerProbe.words("list_issue_statuses") == ["list", "issue", "statuses"])
  #expect(TrackerProbe.words("getURLFor") == ["get", "urlfor"])
  #expect(TrackerProbe.toolSegment("claude.ai Atlassian") == "claude_ai_Atlassian")
}

@Test func serversListsEveryServerWithItsStatus() {
  let line = #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[{"name":"claude.ai Atlassian","status":"needs-auth"},{"name":"glance","status":"connected"},{"name":"x","status":"failed"},{"name":"y","status":"weird"}]}"#
  let servers = TrackerProbe.servers(initLine: line)
  #expect(servers?.map(\.name) == ["claude.ai Atlassian", "glance", "x", "y"])
  #expect(servers?.map(\.status) == [.needsAuth, .connected, .failed, .other])
  #expect(servers?.first?.title == "Atlassian")
  #expect(servers?.first?.mentions(["jira", "atlassian"]) == true)
  #expect(TrackerProbe.servers(initLine: #"{"type":"assistant"}"#) == nil)
}

@Test func mcpListGivesEachServersSettledStatus() throws {
  let output = """
  Checking MCP server health…

  claude.ai Slack: https://mcp.slack.com/mcp - ✔ Connected
  claude.ai GitHub Integration: https://api.githubcopilot.com/mcp - ! Connected · tools fetch failed
  claude.ai Gmail: https://gmail.mcp.claude.com/mcp - ! Needs authentication
  plugin:context7:context7: npx -y @upstash/context7-mcp - ✔ Connected
  claude_design: https://api.anthropic.com/v1/design/mcp (HTTP) - ✘ Failed to connect — rejected (HTTP 403)
  sentry: https://mcp.sentry.dev/mcp - ✘ Connection error
  old: https://example.com - - Not configured
  """
  let servers = try #require(TrackerProbe.servers(mcpList: output))
  #expect(servers == [
    ConnectorServer(name: "claude.ai Slack", status: .connected),
    ConnectorServer(name: "claude.ai GitHub Integration", status: .connected),
    ConnectorServer(name: "claude.ai Gmail", status: .needsAuth),
    ConnectorServer(name: "plugin:context7:context7", status: .connected),
    ConnectorServer(name: "claude_design", status: .failed),
    ConnectorServer(name: "sentry", status: .failed),
    ConnectorServer(name: "old", status: .other),
  ])
  #expect(TrackerProbe.servers(mcpList: "No MCP servers configured. Use `claude mcp add` to add a server.") == nil)
}

@Test func aConnectorStillConnectingIsATrackerUnlessClaudeCodesListSaysOtherwise() throws {
  let pending = #"{"type":"system","subtype":"init","tools":["mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql","mcp__claude_ai_Atlassian__getJiraIssue"],"mcp_servers":[{"name":"claude.ai Atlassian","status":"pending"},{"name":"claude.ai Linear","status":"pending"}]}"#
  #expect(try #require(TrackerProbe.trackers(initLine: pending)).map(\.server) == ["claude.ai Atlassian"])
  #expect(TrackerProbe.trackers(initLine: pending, listed: [.init(name: "claude.ai Atlassian", status: .needsAuth)])
    == [])
  #expect(TrackerProbe.trackers(initLine: pending, listed: [.init(name: "claude.ai Atlassian", status: .connected)])?
    .map(\.server) == ["claude.ai Atlassian"])
  #expect(TrackerProbe.trackers(initLine: initLine, listed: [.init(name: "linear", status: .failed)])?.map(\.server)
    == ["claude.ai Atlassian"])
  #expect(TrackerProbe.waitForConnectors == ["MCP_CONNECTION_NONBLOCKING": "false", "MCP_CONNECT_TIMEOUT_MS": "20000"])
}

@Test func trackersAddedButNotSignedInSaySoAndWhere() throws {
  let servers = [ConnectorServer(name: "claude.ai Atlassian", status: .needsAuth),
                 ConnectorServer(name: "atlassian", status: .needsAuth),
                 ConnectorServer(name: "claude.ai Linear", status: .needsAuth),
                 ConnectorServer(name: "claude.ai Gusto", status: .needsAuth),
                 ConnectorServer(name: "claude.ai Slack", status: .connected),
                 ConnectorServer(name: "github", status: .failed)]
  #expect(TrackerProbe.signInNeeded(servers).map { $0.name } == ["Jira", "Linear"])
  let both = try #require(TrackerProbe.signInWords(servers))
  #expect(both.title == "Jira and Linear aren't signed in")
  #expect(both.line == "Claude Code has the connectors but can't read them until you sign in: reconnect them in "
    + "claude.ai's Connectors, or run /mcp in Claude Code and pick each. Then Refresh.")
  let local = try #require(TrackerProbe.signInWords([.init(name: "atlassian", status: .needsAuth)],
                                                    then: "Check again"))
  #expect(local.title == "Jira isn't signed in")
  #expect(local.line == "Claude Code has the connector but can't read it until you sign in: run /mcp in Claude Code, "
    + "pick it and Authenticate. Then Check again.")
  #expect(TrackerProbe.signInWords([.init(name: "claude.ai Slack", status: .needsAuth)]) == nil)
  #expect(ConnectorServer(name: "claude.ai Atlassian", status: .connected).isClaudeAI)
  #expect(!ConnectorServer(name: "atlassian", status: .connected).isClaudeAI)
}

@Test func aConnectorWithOneIssueToolIsNotATracker() throws {
  let line = #"{"type":"system","subtype":"init","tools":["mcp__elevenlabs__search_voices","mcp__elevenlabs__get_issue_report","mcp__acme__get_ticket","mcp__acme__update_ticket"],"mcp_servers":[{"name":"elevenlabs","status":"connected"},{"name":"acme","status":"connected"}]}"#
  let trackers = try #require(TrackerProbe.trackers(initLine: line))
  #expect(trackers.map(\.server) == ["acme"])
}

@Test func aTrackerRunDeniesEveryOtherServer() {
  let arguments = TicketPrompts.arguments(tools: ["mcp__a__get"], model: "haiku",
                                          otherServers: ["claude.ai Slack", "elevenlabs"])
  #expect(arguments[arguments.firstIndex(of: "--disallowedTools")! + 1] == "mcp__claude_ai_Slack,mcp__elevenlabs")
}
