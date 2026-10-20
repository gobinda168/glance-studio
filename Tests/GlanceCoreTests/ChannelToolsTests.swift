import Testing
@testable import GlanceCore

@Suite struct ChannelToolsTests {
  private func parse(_ name: String, _ args: JSONValue, assistant: Bool = false) -> Result<ChannelCall, ChannelTools.Failure> {
    ChannelTools.parse(name: name, arguments: args, assistant: assistant)
  }

  @Test func sessionsSeeNineTools() {
    #expect(ChannelTools.definitions(assistant: false).compactMap { $0["name"]?.string }
      == ["nudge", "ask", "check_answer", "speak", "tell", "status", "dismiss", "secrets_list",
          "http_request"])
    for tool in ChannelTools.definitions(assistant: false) {
      #expect(tool["inputSchema"]?["type"] == "object")
      #expect(tool["description"]?.string?.isEmpty == false)
    }
  }

  @Test func nudgeDefaultsAndLimits() {
    #expect(parse("nudge", ["title": "Tests pass"])
      == .success(.nudge(title: "Tests pass", body: nil, actions: [], waitSeconds: 300)))
    #expect(parse("nudge", ["title": "Deploy?", "body": "main is green", "actions": ["Ship", "Later"], "wait_seconds": 60])
      == .success(.nudge(title: "Deploy?", body: "main is green", actions: ["Ship", "Later"], waitSeconds: 60)))
    #expect(parse("nudge", ["title": "x", "actions": ["a", "b", "c", "d"]])
      == .failure(.init("nudge takes at most 3 actions.")))
    #expect(parse("nudge", [:]) == .failure(.init("title is required.")))
    #expect(parse("nudge", ["title": "  "]) == .failure(.init("title is required.")))
    #expect(parse("nudge", ["title": 5]) == .failure(.init("title must be a string.")))
    #expect(parse("nudge", ["title": "x", "wait_seconds": 900])
      == .failure(.init("wait_seconds must be between 1 and 540.")))
  }

  @Test func askNeedsChoicesOrText() {
    #expect(parse("ask", ["question": "Revert or fix forward?", "choices": ["Revert", "Fix forward"]])
      == .success(.ask(question: "Revert or fix forward?", choices: ["Revert", "Fix forward"], allowText: true,
                       speak: true, waitSeconds: 300)))
    #expect(parse("ask", ["question": "Name?", "speak": false, "wait_seconds": 30])
      == .success(.ask(question: "Name?", choices: [], allowText: true, speak: false, waitSeconds: 30)))
    #expect(parse("ask", ["question": "x", "allow_text": false])
      == .failure(.init("ask needs choices or allow_text.")))
    #expect(parse("ask", ["question": "x", "choices": ["1", "2", "3", "4", "5"]])
      == .failure(.init("ask takes at most 4 choices.")))
    #expect(parse("ask", ["question": "x", "choices": ["a", 2]]) == .failure(.init("choices must be strings.")))
  }

  @Test func tellTakesMarkdownSizeAndSpeak() {
    #expect(parse("tell", ["markdown": "CI passed."])
      == .success(.tell(markdown: "CI passed.", size: .auto, speak: true)))
    #expect(parse("tell", ["markdown": "| a | b |", "size": "full", "speak": false])
      == .success(.tell(markdown: "| a | b |", size: .full, speak: false)))
    #expect(parse("tell", ["markdown": "x", "size": "huge"])
      == .failure(.init("size must be one of auto, short, full.")))
    #expect(parse("tell", [:]) == .failure(.init("markdown is required.")))
    #expect(parse("tell", ["markdown": .string(String(repeating: "a", count: 20_001))])
      == .failure(.init("tell takes at most 20000 characters.")))
  }

  @Test func checkAnswerSpeakStatusDismiss() {
    #expect(parse("check_answer", ["id": "g3"]) == .success(.checkAnswer(id: "g3", waitSeconds: 0)))
    #expect(parse("check_answer", ["id": "g3", "wait_seconds": 120]) == .success(.checkAnswer(id: "g3", waitSeconds: 120)))
    #expect(parse("speak", ["text": "Build is green."]) == .success(.speak(text: "Build is green.", interrupt: false)))
    #expect(parse("speak", ["text": .string(String(repeating: "a", count: 401))])
      == .failure(.init("speak takes at most 400 characters; put the rest in a nudge.")))
    #expect(parse("status", ["state": "working", "text": "Running tests"])
      == .success(.status(text: "Running tests", state: .working)))
    #expect(parse("status", ["state": "sleeping"])
      == .failure(.init("state must be one of working, waiting, done, error, idle.")))
    #expect(parse("status", [:]) == .failure(.init("status needs text or state.")))
    #expect(parse("dismiss", ["id": "g1"]) == .success(.dismiss(id: "g1")))
    #expect(parse("frobnicate", [:]) == .failure(.init("Unknown tool frobnicate.")))
  }

  @Test func assistantToolsOnlyInAssistantMode() {
    let names = ChannelTools.definitions(assistant: true).compactMap { $0["name"]?.string }
    #expect(names == ["nudge", "ask", "check_answer", "speak", "tell", "status", "dismiss", "approve", "notifications",
                      "calendar", "sessions", "meeting_notes", "tickets", "open", "message_session", "start_session"])
    // The secrets tools are for sessions only in S1: neither listed nor callable by the assistant.
    #expect(!names.contains("secrets_list") && !names.contains("http_request"))
    #expect(parse("secrets_list", [:], assistant: true) == .failure(.init("Unknown tool secrets_list.")))
    #expect(parse("http_request", ["secret": "A", "url": "https://x"], assistant: true)
      == .failure(.init("Unknown tool http_request.")))
    #expect(parse("calendar", ["days": 2]) == .failure(.init("Unknown tool calendar.")))
    #expect(parse("calendar", ["days": 2], assistant: true) == .success(.calendar(days: 2)))
    #expect(parse("calendar", [:], assistant: true) == .success(.calendar(days: 1)))
    #expect(parse("approve", ["tool_name": "Bash", "input": ["command": "ls"]], assistant: true)
      == .success(.approve(tool: "Bash", input: ["command": "ls"])))
    #expect(parse("approve", ["tool_name": "Bash"], assistant: true) == .failure(.init("input is required.")))
    #expect(parse("notifications", [:], assistant: true) == .success(.notifications(filter: "unread")))
    #expect(parse("message_session", ["session": "glance", "text": "run lint"], assistant: true)
      == .success(.messageSession(session: "glance", text: "run lint")))
    #expect(parse("start_session", ["folder": "~/Code/glance", "prompt": "fix the test"], assistant: true)
      == .success(.startSession(folder: "~/Code/glance", prompt: "fix the test")))
  }

  @Test func secretsListTakesNothing() {
    #expect(parse("secrets_list", [:]) == .success(.secretsList))
  }

  @Test func httpRequestChecksItsArguments() {
    #expect(parse("http_request", ["secret": "GITHUB_TOKEN", "url": "https://api.github.com/user"])
      == .success(.httpRequest(SecretHTTPCall(secret: "GITHUB_TOKEN", method: "GET", url: "https://api.github.com/user",
                                              headers: [:], body: nil, bodyFile: nil, saveTo: nil))))
    #expect(parse("http_request", ["secret": "GITHUB_TOKEN", "method": "post", "url": "https://api.github.com/x",
                                   "headers": ["Accept": "application/json"], "body": "  {\"a\":1}\n",
                                   "save_to": "out.json"])
      == .success(.httpRequest(SecretHTTPCall(secret: "GITHUB_TOKEN", method: "POST", url: "https://api.github.com/x",
                                              headers: ["Accept": "application/json"], body: "  {\"a\":1}\n",
                                              bodyFile: nil, saveTo: "out.json"))))
    #expect(parse("http_request", ["url": "https://x"]) == .failure(.init("secret is required.")))
    #expect(parse("http_request", ["secret": "A", "url": "https://x", "method": "TRACE"])
      == .failure(.init("method must be one of DELETE, GET, HEAD, PATCH, POST, PUT.")))
    #expect(parse("http_request", ["secret": "A", "url": "https://x", "headers": ["A": 1]])
      == .failure(.init("headers must be an object of strings.")))
    #expect(parse("http_request", ["secret": "A", "url": "https://x", "body": "x", "body_file": "f"])
      == .failure(.init("Give body or body_file, not both.")))
  }

  /// A hostile Claude sends any JSON at all: wrong types, nulls, nesting, huge text. Each is a sentence, never a crash.
  @Test func httpRequestRejectsHostileShapes() {
    let ok: [String: JSONValue] = ["secret": "A", "url": "https://x"]
    func with(_ key: String, _ value: JSONValue) -> JSONValue {
      var args = ok
      args[key] = value
      return .object(args)
    }
    #expect(parse("http_request", with("headers", ["A": .null])) == .failure(.init("headers must be an object of strings.")))
    #expect(parse("http_request", with("headers", ["A": ["B": "c"]]))
      == .failure(.init("headers must be an object of strings.")))
    #expect(parse("http_request", with("headers", ["a", "b"])) == .failure(.init("headers must be an object of strings.")))
    #expect(parse("http_request", with("headers", "Accept: x")) == .failure(.init("headers must be an object of strings.")))
    #expect(parse("http_request", with("headers", .null))
      == .success(.httpRequest(SecretHTTPCall(secret: "A", method: "GET", url: "https://x", headers: [:], body: nil,
                                              bodyFile: nil, saveTo: nil))))
    #expect(parse("http_request", with("method", 5)) == .failure(.init("method must be a string.")))
    #expect(parse("http_request", with("method", ["GET"])) == .failure(.init("method must be a string.")))
    #expect(parse("http_request", with("body", 5)) == .failure(.init("body must be a string.")))
    #expect(parse("http_request", with("body", ["a": 1])) == .failure(.init("body must be a string.")))
    #expect(parse("http_request", with("body_file", true)) == .failure(.init("body_file must be a string.")))
    #expect(parse("http_request", with("save_to", [1])) == .failure(.init("save_to must be a string.")))
    #expect(parse("http_request", with("url", 5)) == .failure(.init("url must be a string.")))
    #expect(parse("http_request", with("secret", ["A"])) == .failure(.init("secret must be a string.")))
    #expect(parse("http_request", .string("not an object")) == .failure(.init("secret is required.")))
    #expect(parse("http_request", .array([])) == .failure(.init("secret is required.")))
    #expect(parse("http_request", .null) == .failure(.init("secret is required.")))
  }

  /// Empty and null bodies are bodies/no body; a body_file beside an empty body is still "both".
  @Test func httpRequestBodyEdgeCases() {
    let ok: [String: JSONValue] = ["secret": "A", "url": "https://x"]
    var empty = ok
    empty["body"] = ""
    #expect(parse("http_request", .object(empty))
      == .success(.httpRequest(SecretHTTPCall(secret: "A", method: "GET", url: "https://x", headers: [:], body: "",
                                              bodyFile: nil, saveTo: nil))))
    empty["body_file"] = "f"
    #expect(parse("http_request", .object(empty)) == .failure(.init("Give body or body_file, not both.")))
    var nulls = ok
    nulls["body"] = .null
    nulls["body_file"] = "f"
    #expect(parse("http_request", .object(nulls))
      == .success(.httpRequest(SecretHTTPCall(secret: "A", method: "GET", url: "https://x", headers: [:], body: nil,
                                              bodyFile: "f", saveTo: nil))))
  }

  @Test func httpRequestCapsBodyAndHeaders() {
    let limit = ChannelTools.requestBodyLimit
    var big: [String: JSONValue] = ["secret": "A", "url": "https://x"]
    big["body"] = .string(String(repeating: "a", count: limit + 1))
    #expect(parse("http_request", .object(big))
      == .failure(.init("body is over 10 MB; put it in a file and give body_file.")))
    big["body"] = .string(String(repeating: "a", count: limit))
    if case .failure = parse("http_request", .object(big)) { Issue.record("a body of exactly the limit is fine") }
    var many: [String: JSONValue] = [:]
    for i in 0...ChannelTools.headerLimit { many["X-\(i)"] = "v" }
    #expect(parse("http_request", ["secret": "A", "url": "https://x", "headers": .object(many)])
      == .failure(.init("headers takes at most \(ChannelTools.headerLimit) entries.")))
  }
}
