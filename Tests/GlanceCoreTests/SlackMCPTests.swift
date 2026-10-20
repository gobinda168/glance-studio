import Testing
@testable import GlanceCore

@Test func aConnectedSlackServerIsFound() {
  let line = #"{"type":"system","subtype":"init","tools":["mcp__claude_ai_Slack__slack_read_thread","mcp__claude_ai_Slack__slack_send_message","mcp__claude_ai_Slack__slack_search_messages","mcp__claude_ai_Claude_Docs__read"],"mcp_servers":[{"name":"claude.ai Slack","status":"connected"},{"name":"claude.ai Claude Docs","status":"connected"}]}"#
  let status = SlackMCP.status(initLine: line)
  #expect(status?.connected == true)
  #expect(status?.server == "claude.ai Slack")
  #expect(status?.sendTools == ["mcp__claude_ai_Slack__slack_send_message"])
  #expect(status?.readTools == ["mcp__claude_ai_Slack__slack_read_thread", "mcp__claude_ai_Slack__slack_search_messages"])
}

@Test func noSlackServerMeansNotConnected() {
  let line = #"{"type":"system","subtype":"init","tools":["mcp__claude_ai_Claude_Docs__read"],"mcp_servers":[{"name":"claude.ai Slack","status":"needs-auth"}]}"#
  #expect(SlackMCP.status(initLine: line) == .disconnected)
  #expect(SlackMCP.status(initLine: "{\"type\":\"assistant\"}") == nil)
}

@Test func slackToolsNotAllowedForAStepAreDisallowed() {
  let line = #"{"type":"system","subtype":"init","tools":["mcp__claude_ai_Slack__slack_read_thread","mcp__claude_ai_Slack__slack_send_message","mcp__claude_ai_Slack__slack_create_canvas","mcp__claude_ai_Claude_Docs__read"],"mcp_servers":[{"name":"claude.ai Slack","status":"connected"}]}"#
  let status = SlackMCP.status(initLine: line)!
  #expect(status.tools == ["mcp__claude_ai_Slack__slack_read_thread", "mcp__claude_ai_Slack__slack_send_message",
                           "mcp__claude_ai_Slack__slack_create_canvas"])
  #expect(status.disallowed(allowing: status.readTools) == ["mcp__claude_ai_Slack__slack_send_message",
                                                           "mcp__claude_ai_Slack__slack_create_canvas"])
  #expect(status.disallowed(allowing: status.sendTools) == ["mcp__claude_ai_Slack__slack_read_thread",
                                                           "mcp__claude_ai_Slack__slack_create_canvas"])
  #expect(SlackMCP.Status.disconnected.tools.isEmpty)
}

@Test func aSlackServerStillConnectingIsPendingNotDisconnected() {
  // claude.ai connectors are often still connecting when the init line is printed: no tools listed yet.
  let line = #"{"type":"system","subtype":"init","tools":["mcp__claude_ai_Claude_Docs__read"],"mcp_servers":[{"name":"claude.ai Slack","status":"pending"},{"name":"claude.ai Claude Docs","status":"connected"}]}"#
  let status = SlackMCP.status(initLine: line)
  #expect(status?.connected == false)
  #expect(status?.pending == true)
  #expect(status?.server == "claude.ai Slack")
  #expect(SlackMCP.Status.disconnected.pending == false)
}
