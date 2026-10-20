import Foundation
import Testing
@testable import GlanceCore

private func decoded(_ text: String) -> AutomationBridgeRequest? {
  if case .success(let request) = AutomationBridge.decode(text) { return request }
  return nil
}

private func refusal(_ text: String) -> String? {
  if case .failure(let error) = AutomationBridge.decode(text) { return error.message }
  return nil
}

@Test func callsDecode() {
  #expect(decoded(#"{"op":"run","inputs":{"repo":"acme/app","pr":412}}"#)
    == .run(inputs: ["repo": .string("acme/app"), "pr": .number(412)]))
  #expect(decoded(#"{"op":"run"}"#) == .run(inputs: [:]))
  #expect(decoded(#"{"op":"cancel","runID":"2026-10-09T09-00-00.120Z"}"#)
    == .cancel(run: "2026-10-09T09-00-00.120Z"))
  #expect(decoded(#"{"op":"runs"}"#) == .runs(limit: 20))
  #expect(decoded(#"{"op":"runs","limit":5}"#) == .runs(limit: 5))
  #expect(decoded(#"{"op":"runs","limit":5000}"#) == .runs(limit: 200))
  #expect(decoded(#"{"op":"state.get","key":"filters"}"#) == .stateGet(key: "filters"))
  #expect(decoded(#"{"op":"state.set","key":"filters","value":{"open":true}}"#)
    == .stateSet(key: "filters", value: .object(["open": .bool(true)])))
  #expect(decoded(#"{"op":"state.set","key":"filters"}"#) == .stateSet(key: "filters", value: .null))
  #expect(decoded(#"{"op":"openURL","url":"https://github.com/acme/app/pull/7"}"#)
    == .openURL("https://github.com/acme/app/pull/7"))
  #expect(decoded(#"{"op":"reveal","path":"~/Downloads"}"#) == .reveal("~/Downloads"))
}

// Review focus: a page's bad call is refused with a reason, never acted on.
@Test func badCallsAreRefusedWithAReason() {
  #expect(refusal("not json") == "glance.js sent something that isn't a JSON object.")
  #expect(refusal("[1]") == "glance.js sent something that isn't a JSON object.")
  #expect(refusal(#"{"inputs":{}}"#) == "A call needs an op.")
  #expect(refusal(#"{"op":"run","inputs":[1]}"#)
    == #"glance.run takes an object of inputs, like { repo: "acme/app" }."#)
  #expect(refusal(#"{"op":"cancel","runID":"../approvals"}"#) == "glance.cancel takes the id of a run.")
  #expect(refusal(#"{"op":"cancel"}"#) == "glance.cancel takes the id of a run.")
  #expect(refusal(#"{"op":"runs","limit":0}"#) == "glance.runs takes a whole number of runs, 1 or more.")
  #expect(refusal(#"{"op":"runs","limit":2.5}"#) == "glance.runs takes a whole number of runs, 1 or more.")
  let long = String(repeating: "k", count: 201)
  #expect(refusal(#"{"op":"state.get","key":"\#(long)"}"#) == "glance.state keys are text of 1 to 200 characters.")
  #expect(refusal(#"{"op":"state.set","key":""}"#) == "glance.state keys are text of 1 to 200 characters.")
  #expect(refusal(#"{"op":"openURL","url":"  "}"#) == "glance.openURL takes a link or a path.")
  #expect(refusal(#"{"op":"reveal"}"#) == "glance.reveal takes a path.")
  #expect(refusal(#"{"op":"exec"}"#) == "glance has no `exec`.")
}

@Test func runLinesBecomePageEvents() {
  #expect(AutomationBridge.event(run: "r1", .stepStart(step: "log")) == .object([
    "type": .string("step"), "runID": .string("r1"), "step": .string("log"), "status": .string("running"),
  ]))
  #expect(AutomationBridge.event(run: "r1", .runPark(step: "comment")) == .object([
    "type": .string("step"), "runID": .string("r1"), "step": .string("comment"), "status": .string("waiting"),
  ]))
  #expect(AutomationBridge.event(run: "r1", .stepOutput(step: "log", chunk: "a\n")) == .object([
    "type": .string("output"), "runID": .string("r1"), "step": .string("log"), "chunk": .string("a\n"),
  ]))
  #expect(AutomationBridge.event(run: "r1", .stepEnd(step: "log", status: .ok, text: "{}", json: .object([:]),
                                                     durationMs: 5, costUSD: nil)) == .object([
    "type": .string("step"), "runID": .string("r1"), "step": .string("log"), "status": .string("ok"),
    "text": .string("{}"), "json": .object([:]),
  ]))
  #expect(AutomationBridge.event(run: "r1", .stepTool(step: "fix", name: "Edit")) == nil)
  #expect(AutomationBridge.event(run: "r1", .runEnd(status: .ok)) == nil)
  #expect(AutomationBridge.theme(dark: true) == .object(["type": .string("theme"), "theme": .string("dark")]))
}

@Test func doneAndRunsCarryWhatThePageReads() {
  let start = Date(timeIntervalSince1970: 1_760_000_000)
  let record = RunRecord(
    id: "2025-10-09T08-53-20.000Z", status: .ok, trigger: "manual", inputs: [:], version: 3, startedAt: start,
    endedAt: start.addingTimeInterval(1.5),
    steps: [RunRecord.Step(id: "log", status: .ok, text: "hi", json: .number(1), output: "hi", tools: [],
                           durationMs: 10, costUSD: nil)],
    parkedAt: nil)
  #expect(AutomationBridge.done(record) == .object([
    "type": .string("done"), "runID": .string("2025-10-09T08-53-20.000Z"), "status": .string("ok"),
    "steps": .array([.object(["id": .string("log"), "status": .string("ok"), "text": .string("hi"),
                              "json": .number(1)])]),
  ]))
  var going = record
  going.endedAt = nil
  going.status = .running
  #expect(AutomationBridge.runs([record, going]) == .array([
    .object(["id": .string("2025-10-09T08-53-20.000Z"), "status": .string("ok"), "trigger": .string("manual"),
             "startedAt": .string("2025-10-09T08:53:20.000Z"), "durationMs": .number(1500)]),
    .object(["id": .string("2025-10-09T08-53-20.000Z"), "status": .string("running"), "trigger": .string("manual"),
             "startedAt": .string("2025-10-09T08:53:20.000Z"), "durationMs": .null]),
  ]))
}

@Test func bootIsGlanceAutomationAndTheTheme() {
  let boot = AutomationBridge.boot(AutomationSample.manifest(), dark: false)
  let automation = boot.object?["automation"]?.object
  #expect(automation?["id"] == .string("fix-red-ci"))
  #expect(automation?["name"] == .string("Fix red CI"))
  #expect(automation?["version"] == .number(3))
  #expect(automation?["inputs"]?.object?["repo"] == .object([
    "type": .string("string"), "required": .bool(true), "description": .string("owner/name"),
  ]))
  #expect(automation?["inputs"]?.object?["dry"] == .object([
    "type": .string("boolean"), "required": .bool(false), "default": .bool(false),
  ]))
  #expect(boot.object?["theme"] == .string("light"))
}

@Test func stateKeepsOneObjectPerAutomation() throws {
  #expect(AutomationUIState.get(nil, key: "a") == .null)
  let first = try AutomationUIState.set(nil, key: "filters", value: .object(["open": .bool(true)])).get()
  #expect(AutomationUIState.get(first, key: "filters") == .object(["open": .bool(true)]))
  let second = try AutomationUIState.set(first, key: "seen", value: .number(3)).get()
  #expect(AutomationUIState.get(second, key: "filters") == .object(["open": .bool(true)]))
  #expect(AutomationUIState.get(second, key: "seen") == .number(3))
  let cleared = try AutomationUIState.set(second, key: "filters", value: .null).get()
  #expect(AutomationUIState.get(cleared, key: "filters") == .null)
  #expect(String(decoding: cleared, as: UTF8.self) == "{\n  \"seen\" : 3\n}")
  // A corrupt file reads as empty rather than failing every call.
  #expect(AutomationUIState.get(Data("{oops".utf8), key: "seen") == .null)
}

// Review focus: glance.state can't grow past 1 MB.
@Test func stateHoldsAtMostOneMegabyte() {
  let big = AutomationValue.string(String(repeating: "x", count: 1_000_001))
  guard case .failure(let error) = AutomationUIState.set(nil, key: "big", value: big) else {
    Issue.record("wrote more than 1 MB")
    return
  }
  #expect(error.message.hasPrefix("glance.state holds at most 1 MB per automation"))
}

// Review focus: github.com never opens in a browser.
@Test func githubOpensOnlyPullRequestsAndIssuesInStudio() {
  #expect(AutomationLinks.route("https://github.com/acme/app/pull/412")
    == .pullRequest(repository: "acme/app", number: 412))
  #expect(AutomationLinks.route("https://github.com/acme/app/pull/412/files")
    == .pullRequest(repository: "acme/app", number: 412))
  #expect(AutomationLinks.route("https://www.github.com/acme/app/issues/9#issuecomment-1")
    == .pullRequest(repository: "acme/app", number: 9))
  #expect(AutomationLinks.route("https://github.com/acme/app")
    == .refused("Studio opens GitHub pull requests and issues; other GitHub pages aren't opened."))
  #expect(AutomationLinks.route("https://app.slack.com/client/T123/C456") == .slack(team: "T123"))
  #expect(AutomationLinks.route("https://example.com/report") == .browser(URL(string: "https://example.com/report")!))
  #expect(AutomationLinks.route("~/Downloads/report.pdf") == .file("~/Downloads/report.pdf"))
  #expect(AutomationLinks.route("/tmp/report.pdf") == .file("/tmp/report.pdf"))
  #expect(AutomationLinks.route("file:///tmp/a%20b.txt") == .file("/tmp/a b.txt"))
  #expect(AutomationLinks.route("javascript:alert(1)") == .refused("Only web links and files open from an automation."))
  #expect(AutomationLinks.route("  ") == .refused("There's no link."))
}

// Review focus: github.com never reaches a browser, however the address is spelled.
@Test func githubStaysOutOfTheBrowserWhateverTheSpelling() {
  let refused = AutomationLinks.Route.refused(
    "Studio opens GitHub pull requests and issues; other GitHub pages aren't opened.")
  #expect(AutomationLinks.route("https://github.com./acme/app") == refused)
  #expect(AutomationLinks.route("https://GitHub.com../acme/app") == refused)
  #expect(AutomationLinks.route("https://gist.github.com/acme/abc") == refused)
  #expect(AutomationLinks.route("https://raw.github.com/acme/app/main/a.txt") == refused)
  #expect(AutomationLinks.route("https://github.com./acme/app/pull/3")
    == .pullRequest(repository: "acme/app", number: 3))
  #expect(AutomationLinks.route("https://notgithub.com/x") == .browser(URL(string: "https://notgithub.com/x")!))
  for text in ["https:/github.com/acme/app", "https:github.com/acme/app", "https:///github.com/acme/app",
               "http:/github.com/acme/app"] {
    #expect(AutomationLinks.route(text) == .refused("That web link has no host."), "\(text)")
  }
}

@Test func pullRequestPartsAreChecked() {
  let refused = AutomationLinks.Route.refused(
    "Studio opens GitHub pull requests and issues; other GitHub pages aren't opened.")
  #expect(AutomationLinks.route("https://github.com/../app/pull/1") == refused)
  #expect(AutomationLinks.route("https://github.com/acme/../pull/1") == refused)
  #expect(AutomationLinks.route("https://github.com/ac%20me/app/pull/1") == refused)
  #expect(AutomationLinks.route("https://github.com/acme/app/pull/0") == refused)
  #expect(AutomationLinks.route("https://github.com/acme/app/pull/-4") == refused)
  #expect(AutomationLinks.route("https://github.com/acme/app/pull/x") == refused)
  #expect(AutomationLinks.route("https://github.com/Acme/my-app.js_2/pull/1")
    == .pullRequest(repository: "Acme/my-app.js_2", number: 1))
}

@Test func onlyTheOwnHomeIsATildePath() {
  #expect(AutomationLinks.route("~") == .file("~"))
  #expect(AutomationLinks.route("~/Downloads") == .file("~/Downloads"))
  #expect(AutomationLinks.route("~root/.ssh/id_rsa") != .file("~root/.ssh/id_rsa"))
  #expect(AutomationLinks.route("~root/.ssh/id_rsa") == .refused("`~root/.ssh/id_rsa` isn't a link or a path."))
}
