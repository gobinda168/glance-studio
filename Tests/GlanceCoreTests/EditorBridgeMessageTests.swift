import Foundation
import Testing
@testable import GlanceCore

@Test func decodesWhatTheGlanceExtensionSends() {
  #expect(EditorBridgeMessage.decode(#"{"type":"hello","folder":"/Users/u/p"}"#) == .hello(folder: "/Users/u/p"))
  #expect(EditorBridgeMessage.decode(#"{"type":"openTerminal","cwd":"/Users/u/p/src"}"#) == .openTerminal(cwd: "/Users/u/p/src"))
  #expect(EditorBridgeMessage.decode(#"{"type":"closeTab"}"#) == .closeTab)
}

@Test func ignoresMalformedOrUnknownLines() {
  #expect(EditorBridgeMessage.decode("") == nil)
  #expect(EditorBridgeMessage.decode("not json") == nil)
  #expect(EditorBridgeMessage.decode(#"{"type":"hello"}"#) == nil)
  #expect(EditorBridgeMessage.decode(#"{"type":"format","path":"/x"}"#) == nil)
  #expect(EditorBridgeMessage.decode(#"["hello"]"#) == nil)
}

@Test func encodesToLinesThatDecodeBack() {
  for message: EditorBridgeMessage in [.hello(folder: "/a b/ü"), .openTerminal(cwd: "/x\"y"), .closeTab] {
    #expect(!message.line.contains("\n"))
    #expect(EditorBridgeMessage.decode(message.line) == message)
  }
}

@Test func splitsAStreamIntoLinesAcrossReads() {
  var lines = JSONLines()
  #expect(lines.append(Data("{\"type\":\"clo".utf8)) == [])
  #expect(lines.append(Data("seTab\"}\n{\"type\":\"hello\",\"folder\":\"/p\"}\n{\"ty".utf8)) ==
    [#"{"type":"closeTab"}"#, #"{"type":"hello","folder":"/p"}"#])
  #expect(lines.append(Data("pe\":\"closeTab\"}\r\n\n".utf8)) == [#"{"type":"closeTab"}"#])
}

@Test func dropsALineThatNeverEnds() {
  var lines = JSONLines()
  #expect(lines.append(Data(repeating: UInt8(ascii: "a"), count: 1_100_000)) == [])
  // The newline ends the dropped line; the next one is read normally.
  #expect(lines.append(Data("\n{\"type\":\"closeTab\"}\n".utf8)) == [#"{"type":"closeTab"}"#])
}

@Test func askClaudeCarriesTheSelectedTextAndFile() {
  #expect(EditorRequest(body: ["type": "askClaude", "text": "let x = 1", "path": "/p/a.swift"])
    == .askClaude(text: "let x = 1", path: "/p/a.swift"))
  #expect(EditorRequest(body: ["type": "askClaude", "text": "  \n"]) == nil)
}
