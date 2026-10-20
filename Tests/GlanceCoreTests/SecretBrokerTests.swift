import Foundation
import Testing
@testable import GlanceCore

@Suite struct SecretBrokerTests {
  struct Records: SecretRecordSource { let all: [SecretRecord]; func records() -> [SecretRecord] { all } }

  final class Transport: SecretTransport, @unchecked Sendable {
    var sent: [URLRequest] = []
    var limits: [Int] = []
    var respond: (URLRequest, (URL) -> Bool) throws -> (Int, [String: String], Data) = { _, _ in (200, [:], Data("{}".utf8)) }
    func send(_ request: URLRequest, maxBytes: Int, follow: @escaping @Sendable (URL) -> Bool) async throws
      -> (HTTPURLResponse, Data) {
      sent.append(request)
      limits.append(maxBytes)
      let (status, headers, body) = try respond(request, follow)
      return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, body)
    }
  }

  final class Approver: SecretApprover, @unchecked Sendable {
    var answer = true
    var asked: [SecretApprovalAsk] = []
    /// Runs while the request waits for approval: a hostile Claude's shell racing the file system.
    var meanwhile: () -> Void = {}
    func approve(_ ask: SecretApprovalAsk) async -> Bool { asked.append(ask); meanwhile(); return answer }
  }

  let token = "ghp_SECRETvalue0123456789"
  var record: SecretRecord { SecretRecordTests.record(value: token, hosts: ["api.github.com"]) }
  let caller = SecretCaller(session: 7, label: "acme", folder: "/tmp")

  func broker(_ records: [SecretRecord]? = nil, transport: Transport = Transport(), approver: Approver = Approver(),
              log: SecretActivityLog? = nil) -> SecretBroker {
    SecretBroker(records: Records(all: records ?? [record]), transport: transport, approver: approver, log: log)
  }

  func call(_ url: String = "https://api.github.com/user", method: String = "GET", headers: [String: String] = [:],
            body: String? = nil, bodyFile: String? = nil, saveTo: String? = nil) -> SecretHTTPCall {
    SecretHTTPCall(secret: "GITHUB_TOKEN", method: method, url: url, headers: headers, body: body, bodyFile: bodyFile,
                   saveTo: saveTo)
  }

  /// A fresh, realpath-resolved temp folder (and one beside it, standing in for ~/.ssh).
  func folders() throws -> (folder: URL, outside: URL, cleanup: () -> Void) {
    let temp = realpath(FileManager.default.temporaryDirectory.path, nil)!
    defer { free(temp) }
    let base = URL(fileURLWithPath: String(cString: temp))
      .appendingPathComponent("broker-\(UUID().uuidString)")
    let folder = base.appendingPathComponent("project")
    let outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    return (folder, outside, { try? FileManager.default.removeItem(at: base) })
  }

  @Test func theListHasNoValues() {
    let list = broker().list(caller: caller)
    #expect(list.text.contains("GITHUB_TOKEN"))
    #expect(list.text.contains("api.github.com"))
    #expect(!list.text.contains(token))
  }

  @Test func anAllowedCallCarriesTheHeaderInItsSlotAndComesBackScrubbed() async {
    let transport = Transport()
    transport.respond = { request, _ in
      (200, ["X-Echo": request.value(forHTTPHeaderField: "Authorization") ?? ""],
       Data(#"{"headers":{"Authorization":"Bearer \#(request.value(forHTTPHeaderField: "Authorization")!.dropFirst(7))"}}"#.utf8))
    }
    let result = await broker(transport: transport).request(call(), caller: caller)
    #expect(!result.isError)
    #expect(transport.sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    #expect(!result.value.text.contains(token))
    #expect(result.value.text.contains("[secret GITHUB_TOKEN]"))
    #expect(result.value["status"] == 200)
  }

  @Test func aRefusedOrDeniedCallNeverReachesTheNetwork() async {
    let transport = Transport()
    let approver = Approver()
    let b = broker(transport: transport, approver: approver)
    #expect(await b.request(call("https://evil.com/"), caller: caller).isError)
    #expect(await b.request(call(headers: ["Authorization": "x"]), caller: caller).isError)
    var unknown = call()
    unknown.secret = "NOPE"
    let missing = await b.request(unknown, caller: caller)
    #expect(missing.isError && missing.value.text.contains("GITHUB_TOKEN"))
    approver.answer = false
    let denied = await b.request(call(), caller: caller)
    #expect(denied.isError && denied.value.text.contains("denied"))
    #expect(transport.sent.isEmpty)
  }

  @Test func theFolderFenceIsChecked() async {
    let fenced = SecretRecordTests.record(value: token, hosts: ["api.github.com"], folders: ["/Users/me/acme"])
    let result = await broker([fenced]).request(call(), caller: SecretCaller(session: 7, label: "x", folder: "/tmp"))
    #expect(result.isError)
    #expect(broker([fenced]).list(caller: SecretCaller(session: 7, label: "x", folder: "/tmp")).text.contains("GITHUB_TOKEN") == false)
  }

  @Test func theApprovalShowsWhatWillBeSent() async {
    let approver = Approver()
    _ = await broker(approver: approver).request(call(method: "POST", body: "{\"title\":\"hi\"}"), caller: caller)
    #expect(approver.asked.first?.secret == "GITHUB_TOKEN")
    #expect(approver.asked.first?.method == "POST")
    #expect(approver.asked.first?.url == "https://api.github.com/user")
    #expect(approver.asked.first?.bodyPreview == "{\"title\":\"hi\"}")
    #expect(approver.asked.first?.bodyBytes == 14)
    #expect(approver.asked.first?.updated == record.updated)
  }

  @Test func aCrossHostRedirectIsReturnedNotFollowed() async {
    let transport = Transport()
    transport.respond = { _, follow in
      #expect(!follow(URL(string: "https://evil.com/")!))
      #expect(follow(URL(string: "https://api.github.com/next")!))
      return (302, ["Location": "https://evil.com/?t=\(self.token)"], Data())
    }
    let result = await broker(transport: transport).request(call(), caller: caller)
    #expect(result.value["status"] == 302)
    #expect(!result.value.text.contains(token))
  }

  @Test func bigOrBinaryBodiesNeedSaveTo() async throws {
    let transport = Transport()
    transport.respond = { _, _ in (200, [:], Data([0xff, 0xfe, 0x00]) + Data(self.token.utf8)) }
    let inline = await broker(transport: transport).request(call(), caller: caller)
    #expect(inline.isError && inline.value.text.contains("save_to"))

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("broker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let saved = await broker(transport: transport).request(call(saveTo: "out.bin"),
                                                           caller: SecretCaller(session: 7, label: "x", folder: folder.path))
    #expect(!saved.isError)
    let written = try Data(contentsOf: folder.appendingPathComponent("out.bin"))
    #expect(written.range(of: Data(token.utf8)) == nil)
    #expect(await broker(transport: transport).request(call(saveTo: "../out.bin"),
                                                       caller: SecretCaller(session: 7, label: "x", folder: folder.path)).isError)
  }

  /// Refused before any card: its own answer and log line, not a denial, and nothing is sent.
  @Test func tooManyWaitingIsNotADenial() async throws {
    final class Busy: SecretApprover {
      func approve(_ ask: SecretApprovalAsk) async -> Bool { false }
      func decide(_ ask: SecretApprovalAsk) async -> SecretApprovalDecision { .tooManyWaiting }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("broker-log-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let log = SecretActivityLog(url: url)
    let transport = Transport()
    let result = await SecretBroker(records: Records(all: [record]), transport: transport, approver: Busy(), log: log)
      .request(call(), caller: caller)
    #expect(result.isError)
    #expect(result.value.text.contains("Too many requests are waiting for you; try again in a moment."))
    #expect(!result.value.text.contains("denied"))
    #expect(transport.sent.isEmpty)
    #expect(log.recent(limit: 5).map(\.outcome) == ["refused: too many waiting"])
  }

  @Test func theLogNeverHoldsTheValue() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("broker-log-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let log = SecretActivityLog(url: url)
    _ = await broker(log: log).request(call("https://api.github.com/user?token=\(token)"), caller: caller)
    _ = await broker(log: log).request(call("https://evil.com/"), caller: caller)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains(token))
    #expect(log.recent(limit: 5).map(\.outcome) == ["refused: host", "200"])
  }

  // MARK: Beyond the brief: files at the moment of use, size caps, method, error text.

  @Test func aBodyFileIsReadFromInsideTheFolderAndPreviewed() async throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    try Data("{\"a\":1}".utf8).write(to: folder.appendingPathComponent("body.json"))
    let transport = Transport()
    let approver = Approver()
    let result = await broker(transport: transport, approver: approver)
      .request(call(method: "POST", bodyFile: "body.json"), caller: SecretCaller(session: 7, label: "x", folder: folder.path))
    #expect(!result.isError)
    #expect(transport.sent.first?.httpBody == Data("{\"a\":1}".utf8))
    #expect(approver.asked.first?.bodyPreview == "{\"a\":1}")
  }

  @Test func aHardLinkedBodyFileIsRefusedBeforeTheNetwork() async throws {
    let (folder, outside, cleanup) = try folders()
    defer { cleanup() }
    let credentials = outside.appendingPathComponent("credentials")
    try Data("aws_secret_access_key=xyz".utf8).write(to: credentials)
    try FileManager.default.linkItem(at: credentials, to: folder.appendingPathComponent("body.txt"))
    let transport = Transport()
    let result = await broker(transport: transport)
      .request(call(method: "POST", bodyFile: "body.txt"), caller: SecretCaller(session: 7, label: "x", folder: folder.path))
    #expect(result.isError)
    #expect(transport.sent.isEmpty)
  }

  @Test func aSymlinkSwappedInWhileWaitingForApprovalIsNotWrittenThrough() async throws {
    let (folder, outside, cleanup) = try folders()
    defer { cleanup() }
    let data = folder.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    let approver = Approver()
    approver.meanwhile = {
      try? FileManager.default.removeItem(at: data)
      try? FileManager.default.createSymbolicLink(at: data, withDestinationURL: outside)
    }
    let result = await broker(approver: approver)
      .request(call(saveTo: "data/authorized_keys"), caller: SecretCaller(session: 7, label: "x", folder: folder.path))
    #expect(result.isError)
    #expect(result.value.text.contains("inside this session's project folder"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test func aSymlinkAtTheTargetCreatedWhileWaitingIsNotWrittenThrough() async throws {
    let (folder, outside, cleanup) = try folders()
    defer { cleanup() }
    let victim = outside.appendingPathComponent("authorized_keys")
    try Data("mine".utf8).write(to: victim)
    let approver = Approver()
    approver.meanwhile = {
      try? FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("out.txt"), withDestinationURL: victim)
    }
    let result = await broker(approver: approver)
      .request(call(saveTo: "out.txt"), caller: SecretCaller(session: 7, label: "x", folder: folder.path))
    #expect(result.isError)
    #expect(try Data(contentsOf: victim) == Data("mine".utf8))
  }

  @Test func theFolderItselfSwappedForASymlinkWhileWaitingIsNotFollowed() async throws {
    let (folder, outside, cleanup) = try folders()
    defer { cleanup() }
    let moved = folder.deletingLastPathComponent().appendingPathComponent("moved")
    let approver = Approver()
    approver.meanwhile = {
      try? FileManager.default.moveItem(at: folder, to: moved)
      try? FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
    }
    _ = await broker(approver: approver)
      .request(call(saveTo: "out.txt"), caller: SecretCaller(session: 7, label: "x", folder: folder.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test func theTransportIsCappedAtTheInlineOrSaveLimit() async throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    let transport = Transport()
    _ = await broker(transport: transport).request(call(), caller: caller)
    _ = await broker(transport: transport).request(call(saveTo: "out.bin"),
                                                   caller: SecretCaller(session: 7, label: "x", folder: folder.path))
    #expect(transport.limits == [SecretBroker.inlineLimit, SecretBroker.saveLimit])
  }

  @Test func aResponseOverTheCapIsRefused() async throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    let streamed = Transport()
    streamed.respond = { _, _ in throw SecretTransportError.tooLarge }
    let saved = await broker(transport: streamed)
      .request(call(saveTo: "out.bin"), caller: SecretCaller(session: 7, label: "x", folder: folder.path))
    #expect(saved.isError && saved.value.text.contains("over 20 MB"))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("out.bin").path))
    let inline = await broker(transport: streamed).request(call(), caller: caller)
    #expect(inline.isError && inline.value.text.contains("save_to"))

    // A transport that ignores the cap is still held to it.
    let careless = Transport()
    careless.respond = { _, _ in (200, [:], Data(repeating: 0x61, count: SecretBroker.inlineLimit + 1)) }
    let big = await broker(transport: careless).request(call(), caller: caller)
    #expect(big.isError && big.value.text.contains("save_to"))
  }

  @Test func aBodyOverTenMegabytesIsRefused() async throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    try Data(repeating: 0x61, count: SecretBroker.bodyLimit + 1).write(to: folder.appendingPathComponent("big.txt"))
    let transport = Transport()
    let result = await broker(transport: transport)
      .request(call(method: "POST", bodyFile: "big.txt"), caller: SecretCaller(session: 7, label: "x", folder: folder.path))
    #expect(result.isError && result.value.text.contains("10 MB"))
    #expect(transport.sent.isEmpty)
  }

  @Test func thePreviewSurvivesACharacterCutAtTwoKilobytes() async {
    let approver = Approver()
    let body = String(repeating: "a", count: 2_047) + "é and more"
    _ = await broker(approver: approver).request(call(method: "POST", body: body), caller: caller)
    #expect(approver.asked.first?.bodyPreview == String(repeating: "a", count: 2_047))
    #expect(SecretBroker.preview(Data([0x61, 0xff])) == nil)
  }

  @Test func encodingAndRangeHeadersAreRefusedBeforeTheNetwork() async {
    let transport = Transport()
    for name in ["Accept-Encoding", "Range", "If-Range", "TE", "Accept-Charset"] {
      let result = await broker(transport: transport).request(call(headers: [name: "zstd"]), caller: caller)
      #expect(result.isError && result.value.text.contains(name), "\(name)")
    }
    #expect(transport.sent.isEmpty)
  }

  @Test func aResponseInAnEncodingGlanceCantReadIsNeitherReturnedNorSaved() async throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    let transport = Transport()
    let token = self.token
    var encoding = "zstd"
    transport.respond = { _, _ in (200, ["Content-Encoding": encoding], Data("(\(token)) compressed".utf8)) }
    for value in ["zstd", "gzip, zstd", "x-custom", "gzip, br", "identity, gzip", ", gzip", "gzip, gzip"] {
      encoding = value
      let inline = await broker(transport: transport).request(call(), caller: caller)
      #expect(inline.isError && inline.value.text.contains("encoding Glance can't check"), "\(value)")
      #expect(!inline.value.text.contains("compressed"))
      let saved = await broker(transport: transport)
        .request(call(saveTo: "out.bin"), caller: SecretCaller(session: 7, label: "x", folder: folder.path))
      #expect(saved.isError, "\(value)")
      #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("out.bin").path))
    }
    for value in ["", "identity", "GZIP", "x-gzip", "deflate", " br "] {
      encoding = value
      #expect(!(await broker(transport: transport).request(call(), caller: caller).isError), "\(value)")
    }
  }

  @Test func aCharsetGlanceCantCheckIsNeitherReturnedNorSaved() async throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    let transport = Transport()
    var type = ""
    transport.respond = { _, _ in (200, ["Content-Type": type], Data("+AGc-hp+AF8-".utf8)) }
    for value in ["text/plain; charset=utf-7", "text/plain; charset=\"UTF-32\""] {
      type = value
      let inline = await broker(transport: transport).request(call(), caller: caller)
      #expect(inline.isError && inline.value.text.contains("character set Glance can't check"), "\(value)")
      #expect(!inline.value.text.contains("AGc"))
      let saved = await broker(transport: transport)
        .request(call(saveTo: "out.bin"), caller: SecretCaller(session: 7, label: "x", folder: folder.path))
      #expect(saved.isError, "\(value)")
      #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("out.bin").path))
    }
    for value in ["", "application/json", "text/plain; charset=utf-8", "text/plain; charset=windows-1252"] {
      type = value
      #expect(!(await broker(transport: transport).request(call(), caller: caller).isError), "\(value)")
    }
    let asked = await broker(transport: transport).request(call(headers: ["Accept": "text/plain; charset=utf-7"]), caller: caller)
    #expect(asked.isError && asked.value.text.contains("character set"))
    #expect(transport.sent.count == 4 + 4)
  }

  @Test func aUTF16EchoIsScrubbedInlineAndSaved() async throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    let transport = Transport()
    transport.respond = { request, _ in
      (200, [:], request.value(forHTTPHeaderField: "Authorization")!.data(using: .utf16LittleEndian)!)
    }
    let utf16 = token.data(using: .utf16LittleEndian)!
    let inline = await broker(transport: transport).request(call(), caller: caller)
    #expect(!inline.isError)
    #expect(inline.value["body"]?.string.map { Data($0.utf8).range(of: utf16) == nil } == true)
    #expect(inline.value.text.contains("[secret GITHUB_TOKEN]"))
    let saved = await broker(transport: transport)
      .request(call(saveTo: "out.bin"), caller: SecretCaller(session: 7, label: "x", folder: folder.path))
    #expect(!saved.isError)
    #expect(try Data(contentsOf: folder.appendingPathComponent("out.bin")).range(of: utf16) == nil)
  }

  @Test func aFencedRecordDoesNotShadowAUsableOneOfTheSameName() async {
    let fenced = SecretRecordTests.record(value: "fenced-value-123", hosts: ["api.github.com"], folders: ["/Users/me/acme"])
    let transport = Transport()
    let result = await broker([fenced, record], transport: transport).request(call(), caller: caller)
    #expect(!result.isError)
    #expect(transport.sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    // Only fenced: the folder refusal; an unknown name: the usable names.
    #expect(await broker([fenced]).request(call(), caller: caller).value.text.contains("folder"))
  }

  @Test func anOddMethodIsRefused() async {
    let transport = Transport()
    let result = await broker(transport: transport).request(call(method: "GET / HTTP/1.1\r\nX: y"), caller: caller)
    #expect(result.isError)
    #expect(transport.sent.isEmpty)
  }

  @Test func errorTextIsScrubbed() async {
    let transport = Transport()
    let token = self.token
    transport.respond = { _, _ in
      throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad \(token) here"])
    }
    let result = await broker(transport: transport).request(call(), caller: caller)
    #expect(result.isError)
    #expect(!result.value.text.contains(token))
    #expect(result.value.text.contains("[secret GITHUB_TOKEN]"))
  }
}
