import Foundation
import Testing
@testable import GlanceCore

@Suite struct MCPSetupTests {
  @Test func addsAUserScopeStdioServerThroughClaude() {
    let args = MCPSetup.addArguments(glancePath: "/Applications/Glance Studio.app/Contents/MacOS/glance")
    #expect(args.prefix(5) == ["mcp", "add-json", "--scope", "user", "glance"])
    #expect(JSONValue.parse(args[5])
      == ["type": "stdio", "command": "/Applications/Glance Studio.app/Contents/MacOS/glance", "args": ["mcp"]])
    #expect(MCPSetup.removeArguments == ["mcp", "remove", "--scope", "user", "glance"])
  }

  @Test func readsWhetherItIsRegistered() {
    #expect(MCPSetup.registered(claudeJSON: nil) == .missing)
    #expect(MCPSetup.registered(claudeJSON: Data(#"{"mcpServers":{}}"#.utf8)) == .missing)
    #expect(MCPSetup.registered(claudeJSON: Data(#"{"mcpServers":{"glance":{"command":"/x/glance","args":["mcp"]}}}"#.utf8))
      == .registered(command: "/x/glance"))
    #expect(MCPSetup.registered(claudeJSON: Data(#"{"mcpServers":{"glance":{"command":"node","args":["other.js"]}}}"#.utf8))
      == .other("node other.js"))
    #expect(MCPSetup.registered(claudeJSON: Data("garbage".utf8)) == .missing)
  }
}
