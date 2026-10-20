import Foundation
import Testing
@testable import GlanceCore

private func json(_ line: String) -> AutomationValue? { AutomationValue.decode(Data(line.utf8)) }

private func sent(_ line: String) -> AutomationValue? {
  guard case .send(let text) = AutomationMCP.reply(to: AutomationMCP.parse(line), version: "1.2.3") else { return nil }
  return json(text)
}

private func called(_ name: String, _ arguments: String) -> Result<AutomationMCPCall, AutomationMCPArgumentError> {
  AutomationMCP.call(name: name, arguments: json(arguments)?.object ?? [:])
}

@Test func linesParse() {
  #expect(AutomationMCP.parse(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    == .request(id: .number(1), method: "tools/list", params: [:]))
  #expect(AutomationMCP.parse(#"{"jsonrpc":"2.0","id":"a","method":"ping","params":{"x":1}}"#)
    == .request(id: .string("a"), method: "ping", params: ["x": .number(1)]))
  #expect(AutomationMCP.parse(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    == .notification(method: "notifications/initialized"))
  #expect(AutomationMCP.parse("not json") == .invalid(id: .null, code: -32700, message: "Parse error: the line isn't JSON."))
  #expect(AutomationMCP.parse("[1]") == .invalid(id: .null, code: -32600, message: "Invalid request: expected a JSON object."))
  #expect(AutomationMCP.parse(#"{"jsonrpc":"2.0","id":3,"method":"ping","params":[1]}"#)
    == .invalid(id: .number(3), code: -32602, message: "Invalid params: expected an object."))
  // A response to a request this server never sent: nothing to answer.
  #expect(AutomationMCP.parse(#"{"jsonrpc":"2.0","id":9,"result":{}}"#) == .notification(method: ""))
}

@Test func initializeAgreesOnAVersion() {
  let asked = sent(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#)
  let result = asked?.object?["result"]?.object
  #expect(asked?.object?["id"] == .number(0))
  #expect(result?["protocolVersion"] == .string("2025-03-26"))
  #expect(result?["serverInfo"]?.object?["name"] == .string("glance"))
  #expect(result?["serverInfo"]?.object?["version"] == .string("1.2.3"))
  #expect(result?["capabilities"] == .object(["tools": .object(["listChanged": .bool(false)])]))
  #expect(result?["instructions"] == .string(AutomationMCP.instructions))
  let unknown = sent(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
  #expect(unknown?.object?["result"]?.object?["protocolVersion"] == .string("2025-06-18"))
}

@Test func theInstructionsRepeatRulesOneAndTwo() {
  #expect(AutomationMCP.instructions.contains("call automations_search"))
  #expect(AutomationMCP.instructions.contains("run it with automation_run instead"))
}

@Test func toolsListHasTheSixTools() {
  let tools = sent(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)?.object?["result"]?.object?["tools"]
  guard case .array(let list)? = tools else {
    Issue.record("no tools")
    return
  }
  #expect(list.compactMap { $0.object?["name"] } == AutomationMCP.toolNames.map(AutomationValue.string))
  for tool in list {
    let schema = tool.object?["inputSchema"]?.object
    #expect(schema?["type"] == .string("object"))
    #expect(tool.object?["description"].map { $0.text.count > 20 } == true)
  }
  #expect(AutomationMCP.serverRule == "mcp__plugin_glance_glance")
}

@Test func otherMessagesGetTheirAnswers() {
  #expect(sent(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#)?.object?["result"] == .object([:]))
  #expect(sent(#"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#)?.object?["error"]?.object?["code"]
    == .number(-32601))
  #expect(AutomationMCP.reply(to: AutomationMCP.parse(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#),
                              version: "1") == .none)
  #expect(sent(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}"#)?
    .object?["error"]?.object?["code"] == .number(-32602))
}

@Test func toolCallsBecomeCalls() throws {
  let line = #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"automation_run","arguments":{"id":"fix-red-ci","inputs":{"repo":"acme/app"}}}}"#
  #expect(AutomationMCP.reply(to: AutomationMCP.parse(line), version: "1")
    == .call(id: .number(8), .run(id: "fix-red-ci", inputs: ["repo": .string("acme/app")], wait: true)))
  #expect(try called("automations_search", #"{"query":"ci"}"#).get() == .search(query: "ci", limit: 10))
  #expect(try called("automations_search", #"{"query":"","limit":3}"#).get() == .search(query: "", limit: 3))
  #expect(try called("automation_get", #"{"id":"a","file":"steps/x.sh"}"#).get() == .get(id: "a", file: "steps/x.sh"))
  #expect(try called("automation_run", #"{"id":"a","wait":false}"#).get() == .run(id: "a", inputs: [:], wait: false))
  #expect(try called("automation_runs", #"{"id":"a","run":"2026-10-09T09-00-00.120Z"}"#).get()
    == .runs(id: "a", run: "2026-10-09T09-00-00.120Z", limit: 10))
  #expect(try called("automation_save", #"{"id":"a","from":".drafts/a"}"#).get()
    == .save(id: "a", files: [:], delete: [], from: ".drafts/a"))
  #expect(try called("automation_save", #"{"id":"a","files":{"README.md":"hi"},"delete":["old.sh"]}"#).get()
    == .save(id: "a", files: ["README.md": "hi"], delete: ["old.sh"], from: nil))
  #expect(try called("automation_events", "{}").get() == .events)
}

// Review focus: Claude's malformed arguments come back as a tool error with a reason, never a crash or a call.
@Test func badArgumentsAreRefusedWithAReason() {
  func refusal(_ name: String, _ arguments: String) -> String? {
    if case .failure(let error) = called(name, arguments) { return error.message }
    return nil
  }
  #expect(refusal("automation_get", #"{"id":"../x"}"#)
    == "id must be an automation's id: 1 to 48 lowercase letters, digits or dashes.")
  #expect(refusal("automation_get", #"{"id":"Fix"}"#) != nil)
  #expect(refusal("automation_run", #"{"id":"a","inputs":[1]}"#)
    == #"inputs must be an object of input values, like {"repo": "acme/app"}."#)
  #expect(refusal("automation_run", #"{"id":"a","wait":"yes"}"#) == "wait must be true or false.")
  #expect(refusal("automations_search", #"{"query":"x","limit":0}"#) == "limit must be a whole number from 1 to 50.")
  #expect(refusal("automations_search", #"{"query":"x","limit":2.5}"#) != nil)
  #expect(refusal("automation_runs", #"{"id":"a","run":"../../approvals"}"#) == "run must be a run id from automation_runs.")
  #expect(refusal("automation_save", #"{"id":"a"}"#) == "Give files, from (a folder) or delete: there's nothing to save.")
  #expect(refusal("automation_save", #"{"id":"a","files":{"x.sh":1}}"#) == #"files["x.sh"] must be the file's text."#)
  #expect(refusal("automation_save", #"{"id":"a","delete":"x"}"#) == "delete must list package paths.")
  #expect(refusal("automation_get", #"{"id":"a","file":""}"#) != nil)
  #expect(refusal("automation_events", #"{"x":1}"#) == "automation_events has no argument x.")
  let line = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"automation_get","arguments":{}}}"#
  guard case .send(let text) = AutomationMCP.reply(to: AutomationMCP.parse(line), version: "1") else {
    Issue.record("no reply")
    return
  }
  #expect(json(text)?.object?["result"]?.object?["isError"] == .bool(true))
}

@Test func resultsRead() {
  let result = json(AutomationMCP.toolResult(id: .string("q"), text: "done", isError: false))?.object
  #expect(result?["id"] == .string("q"))
  #expect(result?["result"] == .object(["content": .array([.object(["type": .string("text"), "text": .string("done")])]),
                                        "isError": .bool(false)]))
  #expect(AutomationMCPText.search([], query: "pdf").contains("No automation matches \"pdf\""))
  #expect(AutomationMCPText.saved(id: "a", name: "A", version: 2, commit: "0123456789", approval: .never)
    .hasPrefix("Saved a v2 (commit 0123456). It needs approval"))
  #expect(AutomationMCPText.saved(id: "a", name: "A", version: 3, commit: nil, approval: .approved)
    .contains("approval still holds"))
}

// Hardening beyond the brief: ids, paths and sizes Claude (or a prompt-injected page) might send.
@Test func reservedIDsAndEscapingPathsAreRefused() {
  func refusal(_ name: String, _ arguments: String) -> String? {
    if case .failure(let error) = called(name, arguments) { return error.message }
    return nil
  }
  #expect(refusal("automation_get", #"{"id":"state"}"#) == "`state` is reserved by the library and can't be an automation's id.")
  #expect(refusal("automation_run", #"{"id":"state"}"#) != nil)
  for bad in ["../x.sh", "/etc/passwd", "a/../../b", ".git/config", "steps/.hidden", "~/x", "a//b", "a\\u0000b"] {
    let expected = "must be a file inside the package (no `..`, no leading `/`, no hidden files)."
    #expect(refusal("automation_get", #"{"id":"a","file":"\#(bad)"}"#)?.hasSuffix(expected) == true, "get \(bad)")
    #expect(refusal("automation_save", #"{"id":"a","files":{"\#(bad)":"x"}}"#)?.hasSuffix(expected) == true, "files \(bad)")
    #expect(refusal("automation_save", #"{"id":"a","delete":["\#(bad)"]}"#)?.hasSuffix(expected) == true, "delete \(bad)")
  }
  #expect(called("automation_save", #"{"id":"a","files":{"steps/fetch.sh":"x","docs/a.md":"y"}}"#).isSuccess)
  #expect(refusal("automation_save", #"{"id":"a","from":"a\u0000b"}"#) == "from must be a folder path.")
}

@Test func oversizeInputsAreRefused() {
  let big = String(repeating: "x", count: 1_000_001)
  if case .failure(let error) = called("automation_save", #"{"id":"a","files":{"big.txt":"\#(big)"}}"#) {
    #expect(error.message.contains("too large"))
  } else {
    Issue.record("a 1 MB+ file was accepted")
  }
  let chunk = String(repeating: "y", count: 900_000)
  let three = (1...3).map { #""f\#($0).txt":"\#(chunk)""# }.joined(separator: ",")
  if case .failure(let error) = called("automation_save", #"{"id":"a","files":{\#(three)}}"#) {
    #expect(error.message.contains("together"))
  } else {
    Issue.record("a 2.7 MB payload was accepted")
  }
  let two = (1...2).map { #""f\#($0).txt":"\#(chunk)""# }.joined(separator: ",")
  #expect(called("automation_save", #"{"id":"a","files":{\#(two)}}"#).isSuccess)
  let inputs = String(repeating: "z", count: 300_000)
  #expect(!called("automation_run", #"{"id":"a","inputs":{"k":"\#(inputs)"}}"#).isSuccess)
  let many = (0..<501).map { #""d\#($0).txt""# }.joined(separator: ",")
  #expect(!called("automation_save", #"{"id":"a","delete":[\#(many)]}"#).isSuccess)
  #expect(AutomationMCP.parse(String(repeating: " ", count: AutomationMCP.maxLineBytes + 1))
    == .invalid(id: .null, code: -32600, message: "Invalid request: the line is too long."))
}

@Test func malformedMessagesNeverCrash() {
  #expect(AutomationMCP.parse("") == .invalid(id: .null, code: -32700, message: "Parse error: the line isn't JSON."))
  #expect(AutomationMCP.parse("null") == .invalid(id: .null, code: -32600, message: "Invalid request: expected a JSON object."))
  #expect(AutomationMCP.parse(#"{"jsonrpc":"2.0","id":1,"method":5}"#)
    == .invalid(id: .number(1), code: -32600, message: "Invalid request: no method."))
  #expect(AutomationMCP.parse(#"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#)
    == .invalid(id: .null, code: -32600, message: "Invalid request: the id must be a number or a string."))
  #expect(AutomationMCP.parse(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
    == .invalid(id: .null, code: -32600, message: "Invalid request: the id must be a number or a string."))
  #expect(AutomationMCP.parse(#"{"jsonrpc":"2.0","id":2,"error":{"code":1,"message":"x"}}"#) == .notification(method: ""))
  // Notifications never get an answer, even unknown ones; an unknown method with an id gets -32601.
  #expect(AutomationMCP.reply(to: AutomationMCP.parse(#"{"jsonrpc":"2.0","method":"nope"}"#), version: "1") == .none)
  #expect(sent(#"{"jsonrpc":"2.0","id":1,"method":"nope"}"#)?.object?["error"]?.object?["code"] == .number(-32601))
  // Bad params: a tool call with no name, a non-object arguments, a list of params.
  #expect(sent(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#)?.object?["error"]?.object?["code"] == .number(-32602))
  #expect(sent(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"automation_events","arguments":[1]}}"#)?
    .object?["error"]?.object?["code"] == .number(-32602))
  #expect(sent(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":7}}"#)?.object?["error"]?.object?["code"]
    == .number(-32602))
  #expect(sent(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":5}}"#)?
    .object?["result"]?.object?["protocolVersion"] == .string("2025-06-18"))
}

@Test func theToolsAgreeWithTheSkill() {
  let run = AutomationMCP.tools.text
  #expect(run.contains("parked"))
  #expect(run.contains("Saving never approves"))
  #expect(AutomationMCP.toolNames.allSatisfy { AutomationPluginDocs.skill(cli: "/x/glance").contains("`\($0)`") })
}

private extension Result {
  var isSuccess: Bool { if case .success = self { return true } else { return false } }
}

// Review focus: the stdio reader never holds more than the cap (plus one chunk) of a line, answers an over-long line
// once, skips to its end, and still serves the next line.
@Test func linesOverTheCapAreDroppedAsTheyArriveAndTheNextLineStillComes() {
  var lines = AutomationMCPLines(limit: 10)
  #expect(lines.feed(Data("abc\n".utf8)) == [.line("abc")])
  #expect(lines.feed(Data("12345".utf8)) == [])
  #expect(lines.feed(Data("67890".utf8)) == [])  // exactly the limit so far: still fine
  #expect(lines.feed(Data("1".utf8)) == [.tooLong])
  #expect(lines.feed(Data("xxxxxxxxxxxxxxxxxxxx".utf8)) == [])  // skipped, no second report
  #expect(lines.feed(Data("yy\nok\n".utf8)) == [.line("ok")])
  #expect(lines.feed(Data("12345678901\nnext\n".utf8)) == [.tooLong, .line("next")])
  #expect(lines.feed(Data("1234567890\n".utf8)) == [.line("1234567890")])
  #expect(lines.feed(Data("\n\n".utf8)) == [.line(""), .line("")])
  #expect(lines.feed(Data("tail".utf8)) == [])
  #expect(lines.finish() == [.line("tail")])
  #expect(lines.finish() == [])
}

@Test func aLineCutByTheEndOfInputWhileSkippingSaysNothingMore() {
  var lines = AutomationMCPLines(limit: 4)
  #expect(lines.feed(Data("123456".utf8)) == [.tooLong])
  #expect(lines.finish() == [])
  #expect(AutomationMCP.reply(to: AutomationMCP.lineTooLong, version: "1")
    == .send(AutomationMCP.error(id: .null, code: -32600, message: "Invalid request: the line is too long.")))
}

@Test func theSaveToolSaysWhereFromStartsAndThatFilesAloneEditTheCurrentPackage() {
  guard case .array(let tools) = AutomationMCP.tools,
        let save = tools.first(where: { $0.object?["name"] == .string("automation_save") }),
        case .string(let text)? = save.object?["description"] else {
    Issue.record("no description")
    return
  }
  #expect(text.contains("drafts live in <library>/.drafts/<id>"))
  #expect(text.contains("must hold that automation's automation.json"))
  #expect(text.contains("`files` alone"))
  #expect(text.contains("symlinks inside it are refused"))
}
