import Foundation
import Testing
@testable import GlanceCore

@Suite struct MCPTests {
  @Test func jsonValuesRoundTripThroughText() {
    let value: JSONValue = ["a": 1, "b": [true, "x", .null], "c": ["d": 2.5]]
    #expect(JSONValue.parse(value.text) == value)
    #expect(value.text == #"{"a":1,"b":[true,"x",null],"c":{"d":2.5}}"#)
    #expect(value["a"]?.int == 1)
    #expect(value["b"]?.array?.first?.bool == true)
    #expect(JSONValue.parse("not json") == nil)
  }

  @Test func booleansStayBooleans() {
    #expect(JSONValue.parse(#"{"x":true,"y":1}"#) == ["x": true, "y": 1])
  }

  @Test func parsesRequestsNotificationsAndResponses() {
    #expect(MCP.parse(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
      == .request(id: 3, method: "tools/list", params: [:]))
    #expect(MCP.parse(#"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"x"}}"#)
      == .request(id: "a", method: "tools/call", params: ["name": "x"]))
    #expect(MCP.parse(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
      == .notification(method: "notifications/initialized", params: [:]))
    #expect(MCP.parse(#"{"jsonrpc":"2.0","id":7,"result":{}}"#) == .response(id: 7))
    #expect(MCP.parse(#"{"id":1,"method":"x"}"#) == .invalid)
    #expect(MCP.parse("") == .invalid)
  }

  @Test func writesOneLineResultsErrorsAndNotifications() {
    #expect(MCP.result(id: 1, ["ok": true]) == #"{"id":1,"jsonrpc":"2.0","result":{"ok":true}}"#)
    #expect(MCP.error(id: "q", code: -32601, message: "Unknown method")
      == #"{"error":{"code":-32601,"message":"Unknown method"},"id":"q","jsonrpc":"2.0"}"#)
    #expect(MCP.notification(method: MCP.channelMethod, params: ["content": "hi", "meta": ["from": "glance"]])
      == #"{"jsonrpc":"2.0","method":"notifications/claude/channel","params":{"content":"hi","meta":{"from":"glance"}}}"#)
  }

  @Test func initializeDeclaresToolsAndBothChannelCapabilities() {
    let result = MCP.initializeResult(clientVersion: "2025-03-26", serverVersion: "1.2")
    #expect(result["protocolVersion"] == "2025-03-26")
    #expect(result["capabilities"]?["tools"] == [:])
    #expect(result["capabilities"]?["experimental"]?["claude/channel"] == [:])
    #expect(result["capabilities"]?["experimental"]?["claude/channel/permission"] == [:])
    #expect(result["serverInfo"]?["name"] == "glance")
    #expect(result["instructions"]?.string?.contains("ask") == true)
    // A version Glance doesn't know gets Glance's own.
    #expect(MCP.initializeResult(clientVersion: "1999-01-01", serverVersion: "1")["protocolVersion"]
      == .string(MCP.protocolVersion))
  }

  @Test func toolResultsAreOneTextBlock() {
    #expect(MCP.toolResult(["answer": "Revert"]) == ["content": [["type": "text", "text": #"{"answer":"Revert"}"#]],
                                                       "isError": false])
    #expect(MCP.toolResult("Glance Studio isn't running.", isError: true)
      == ["content": [["type": "text", "text": "Glance Studio isn't running."]], "isError": true])
  }
}
