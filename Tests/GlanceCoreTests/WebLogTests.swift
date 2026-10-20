import Foundation
import Testing
@testable import GlanceCore

// MARK: Masking

@Test func credentialHeadersAreMaskedAndOthersKept() {
  let masked = WebLogRedactor.headers([
    "Authorization": "Bearer abc123456789", "cookie": "sid=1", "Set-Cookie": "a=b", "x-api-key": "k",
    "content-type": "application/json", "accept": "*/*",
  ])
  #expect(masked["Authorization"] == "[masked]")
  #expect(masked["cookie"] == "[masked]")
  #expect(masked["Set-Cookie"] == "[masked]")
  #expect(masked["x-api-key"] == "[masked]")
  #expect(masked["content-type"] == "application/json")
  #expect(masked["accept"] == "*/*")
}

@Test func queryCredentialsAreMaskedInAddresses() {
  let url = WebLogRedactor.url("https://api.example.com/v1/users?page=2&access_token=secret123&q=cats")
  #expect(url == "https://api.example.com/v1/users?page=2&access_token=[masked]&q=cats")
  #expect(WebLogRedactor.url("http://localhost:3000/a?b=c") == "http://localhost:3000/a?b=c")
  #expect(WebLogRedactor.url("https://u:hunter2@example.com/").contains("hunter2") == false)
}

@Test func jsonAndFormBodiesMaskCredentialFieldsOnly() {
  let json = WebLogRedactor.body(#"{"email":"a@b.co","password":"hunter2","nested":{"apiKey":"k-1"},"count":3}"#)
  #expect(json.contains("hunter2") == false)
  #expect(json.contains("k-1") == false)
  #expect(json.contains("a@b.co"))
  #expect(json.contains("\"count\":3"))
  #expect(WebLogRedactor.body("user=amy&password=pw&remember=1") == "user=amy&password=[masked]&remember=1")
  #expect(WebLogRedactor.body("plain words") == "plain words")
}

@Test func printedTokensAreMasked() {
  let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghij"
  #expect(WebLogRedactor.text("token is \(jwt) ok") == "token is [masked] ok")
  #expect(WebLogRedactor.text("Authorization: Bearer abcdefgh12345") == "Authorization: [masked]")
  #expect(WebLogRedactor.text("fetch failed") == "fetch failed")
}

// MARK: Assembling

private func message(_ fields: [String: Any]) -> [String: Any] { fields }

@Test func aRequestIsWrittenWhenItStartsAndWhenItEnds() {
  var assembler = WebLogAssembler()
  let start = assembler.receive(message([
    "t": "net", "phase": "start", "fid": "f1", "rid": 1, "via": "fetch", "method": "POST",
    "url": "http://localhost:3000/api/login?token=abc", "at": 1_000_000.0,
    "requestHeaders": ["authorization": "Bearer abcdefgh123", "content-type": "application/json"],
    "requestBody": #"{"password":"x"}"#,
  ]))
  #expect(start.count == 1)
  #expect(start[0].isPending)
  #expect(start[0].url == "http://localhost:3000/api/login?token=[masked]")
  #expect(start[0].requestHeaders?["authorization"] == "[masked]")

  let end = assembler.receive(message([
    "t": "net", "phase": "end", "fid": "f1", "rid": 1, "status": 401, "statusText": "Unauthorized",
    "durationMs": 87, "responseType": "application/json", "responseBody": #"{"error":"bad login"}"#,
  ]))
  #expect(end.count == 1)
  #expect(end[0].id == start[0].id)
  #expect(end[0].status == 401)
  #expect(end[0].isFailedRequest)
  #expect(end[0].isPending == false)
  #expect(end[0].method == "POST")
}

@Test func aRequestWithNoAnswerFailsWithItsError() {
  var assembler = WebLogAssembler()
  _ = assembler.receive(message(["t": "net", "phase": "start", "fid": "f", "rid": 4, "method": "GET", "url": "http://x/"]))
  let end = assembler.receive(message(["t": "net", "phase": "end", "fid": "f", "rid": 4, "status": 0, "error": "Failed to fetch"]))
  #expect(end.first?.failed == true)
  #expect(end.first?.error == "Failed to fetch")
}

@Test func anEndWithoutAStartIsIgnored() {
  var assembler = WebLogAssembler()
  #expect(assembler.receive(message(["t": "net", "phase": "end", "fid": "f", "rid": 9, "status": 200])).isEmpty)
}

@Test func aNewDocumentCancelsRequestsTheOldOneWaitedFor() {
  var assembler = WebLogAssembler()
  _ = assembler.receive(message(["t": "net", "phase": "start", "fid": "old", "rid": 1, "method": "GET", "url": "http://x/slow"]))
  let written = assembler.receive(message(["t": "nav", "fid": "new", "top": true, "spa": false, "url": "http://x/next"]))
  #expect(written.count == 2)
  #expect(written[0].failed == true)
  #expect(written[0].error?.hasPrefix("cancelled") == true)
  #expect(written[1].kind == .navigation)
  // A same-page route change cancels nothing.
  _ = assembler.receive(message(["t": "net", "phase": "start", "fid": "new", "rid": 1, "method": "GET", "url": "http://x/a"]))
  #expect(assembler.receive(message(["t": "nav", "fid": "new", "top": true, "spa": true, "url": "http://x/b"])).count == 1)
}

@Test func consoleMessagesKeepTheirLevelAndGetOrderedIds() {
  var assembler = WebLogAssembler()
  let first = assembler.receive(message(["t": "console", "level": "warn", "text": "careful", "at": 2_000.0]))
  let second = assembler.receive(message(["t": "console", "text": "hello"]))
  #expect(first[0].level == "warn")
  #expect(first[0].time == 2.0)
  #expect(second[0].level == "log")
  #expect(second[0].id == first[0].id + 1)
}

@Test func maskingCanBeSwitchedOff() {
  var assembler = WebLogAssembler(masksSecrets: false)
  let written = assembler.receive(message(["t": "console", "text": "Bearer abcdefgh12345"]))
  #expect(written[0].text == "Bearer abcdefgh12345")
}

@Test func theDocumentRequestIsLogged() {
  var assembler = WebLogAssembler()
  let ok = assembler.document(url: "http://localhost:3000/", status: 200, headers: ["set-cookie": "s=1"], contentType: "text/html")
  #expect(ok[0].via == "document")
  #expect(ok[0].responseHeaders?["set-cookie"] == "[masked]")
  let refused = assembler.documentFailed(url: "http://localhost:3000/", message: "Could not connect to the server.")
  #expect(refused[0].isFailedRequest)
}

// MARK: Reading

private func request(_ id: Int, status: Int?, method: String = "GET", url: String = "http://x/a") -> WebLogEntry {
  var entry = WebLogEntry(id: id, kind: .network, time: 10)
  entry.method = method
  entry.url = url
  entry.status = status
  return entry
}

@Test func theLastLineForAnIdIsItsState() {
  let lines = [request(1, status: nil), request(2, status: 200), request(1, status: 500)]
  let reduced = WebLogReader.reduce(lines)
  #expect(reduced.map(\.id) == [1, 2])
  #expect(reduced[0].status == 500)
}

@Test func linesRoundTripThroughJSON() throws {
  var entry = request(3, status: 404)
  entry.responseHeaders = ["content-type": "text/plain"]
  let line = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
  #expect(WebLogReader.parse(line + "\nnot json\n") == [entry])
}

@Test func filtersNarrowTheLog() {
  var error = WebLogEntry(id: 1, kind: .console, time: 1)
  error.level = "error"
  error.text = "TypeError: x is undefined"
  var warn = WebLogEntry(id: 2, kind: .console, time: 1)
  warn.level = "warn"
  warn.text = "deprecated"
  let okay = request(3, status: 200)
  let missing = request(4, status: 404, method: "POST", url: "http://x/users")
  let nav = WebLogEntry(id: 5, kind: .navigation, time: 1)

  var errors = WebLogFilter()
  errors.errorsOnly = true
  #expect([error, warn, okay, missing, nav].filter(errors.matches).map(\.id) == [1, 4])

  var warnings = WebLogFilter()
  warnings.minLevel = "warn"
  #expect([error, warn, okay, missing, nav].filter(warnings.matches).map(\.id) == [1, 2, 4])

  var posts = WebLogFilter()
  posts.method = "post"
  #expect([error, okay, missing].filter(posts.matches).map(\.id) == [4])

  var search = WebLogFilter()
  search.text = "UNDEFINED"
  #expect([error, warn, okay].filter(search.matches).map(\.id) == [1])

  var network = WebLogFilter()
  network.console = false
  network.navigation = false
  #expect([error, okay, missing, nav].filter(network.matches).map(\.id) == [3, 4])
}

@Test func theFrontTabIsTheOneUsedLast() {
  let tabs = [
    WebLogTab(key: "tab:1", title: "Docs", url: "https://docs.example.com", file: "tab-1.jsonl", focused: 5),
    WebLogTab(key: "tab:2", title: "App", url: "http://localhost:3000/", file: "tab-2.jsonl", focused: 9),
  ]
  #expect(WebLogReader.tab(nil, in: tabs)?.key == "tab:2")
  #expect(WebLogReader.tab("1", in: tabs)?.key == "tab:1")
  #expect(WebLogReader.tab("tab:2", in: tabs)?.key == "tab:2")
  #expect(WebLogReader.tab("docs", in: tabs)?.key == "tab:1")
  #expect(WebLogReader.tab("nothing", in: tabs) == nil)
}

@Test func logFilesAreNamedForTheirTab() {
  #expect(WebLogFiles.fileName(forTab: "tab:3") == "tab-3.jsonl")
  #expect(WebLogFiles.fileName(forTab: "app:AB-12") == "app-AB-12.jsonl")
}

// MARK: Terminal text

@Test func rowsReadAsPlainTextWithoutColor() {
  let format = WebLogFormat(color: false)
  var log = WebLogEntry(id: 1, kind: .console, time: 0)
  log.level = "error"
  log.text = "boom\n  at app.js:1"
  let lines = format.line(log).split(separator: "\n")
  #expect(lines.count == 2)
  #expect(lines[0].hasSuffix("ERROR  boom"))
  #expect(lines[1].hasSuffix("  at app.js:1"))

  var row = request(7, status: 404, method: "POST", url: "http://localhost:3000/api/users")
  row.durationMs = 143
  let text = format.line(row)
  #expect(text.contains("#7"))
  #expect(text.contains("POST"))
  #expect(text.contains("404"))
  #expect(text.contains("143ms"))
  #expect(text.hasSuffix("http://localhost:3000/api/users"))
  #expect(text.contains("\u{1B}") == false)
  #expect(WebLogFormat(color: true).line(row).contains("\u{1B}[33m404"))
}

@Test func aRowLeavesRoomForItsAddress() {
  let row = request(1, status: 200, url: "http://localhost:3000/" + String(repeating: "a", count: 300))
  let line = WebLogFormat(color: false, width: 100).line(row)
  #expect(line.count <= 100)
  #expect(line.hasSuffix("…"))
}

@Test func theDetailShowsHeadersPayloadAndResponse() {
  var entry = request(2, status: 422, method: "POST", url: "http://x/users")
  entry.requestHeaders = ["content-type": "application/json", "authorization": "[masked]"]
  entry.requestBody = #"{"name":""}"#
  entry.responseBody = #"{"error":"name required"}"#
  entry.contentType = "application/json"
  let text = WebLogFormat(color: false).detail(entry)
  #expect(text.contains("Request headers"))
  #expect(text.contains("  authorization: [masked]"))
  #expect(text.contains("Request body"))
  #expect(text.contains("\"error\" : \"name required\""))
  #expect(text.contains("Response body (application/json)"))
}
