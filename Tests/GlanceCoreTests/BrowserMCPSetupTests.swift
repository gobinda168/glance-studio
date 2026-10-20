import Foundation
import Testing
@testable import GlanceCore

@Test func claudesBrowserIsAddedAsItsOwnMCPServer() {
  let arguments = BrowserMCPSetup.addArguments(glancePath: "/Applications/Glance Studio.app/Contents/MacOS/glance")
  #expect(Array(arguments.prefix(5)) == ["mcp", "add-json", "--scope", "user", "glance-browser"])
  let config = JSONValue.parse(arguments[5])
  #expect(config?["command"]?.string == "/Applications/Glance Studio.app/Contents/MacOS/glance")
  #expect(config?["args"]?.array?.compactMap(\.string) == ["agent-browser", "mcp"])
  #expect(BrowserMCPSetup.removeArguments == ["mcp", "remove", "--scope", "user", "glance-browser"])
}

@Test func claudesBrowserServerIsFoundInClaudeJSON() {
  func json(_ text: String) -> Data { Data(text.utf8) }
  #expect(BrowserMCPSetup.registered(claudeJSON: nil) == .missing)
  #expect(BrowserMCPSetup.registered(claudeJSON: json(#"{"mcpServers":{"glance":{"command":"/x/glance","args":["mcp"]}}}"#)) == .missing)
  #expect(BrowserMCPSetup.registered(claudeJSON: json(
    #"{"mcpServers":{"glance-browser":{"command":"/A/Contents/MacOS/glance","args":["agent-browser","mcp"]}}}"#))
    == .registered(command: "/A/Contents/MacOS/glance"))
  #expect(BrowserMCPSetup.registered(claudeJSON: json(
    #"{"mcpServers":{"glance-browser":{"command":"npx","args":["@playwright/mcp"]}}}"#)) == .other("npx @playwright/mcp"))
}
