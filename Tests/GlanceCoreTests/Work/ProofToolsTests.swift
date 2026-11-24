import Foundation
import Testing
@testable import GlanceCore

@Suite struct ProofToolsTests {
  func temp(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
  }
  func store() -> WorkStore { WorkStore(folder: temp("pt")) }

  /// A repository on branch feat/x, optionally with a proof setup, and a folder inside it.
  func repo(setup: String? = nil) throws -> URL {
    let root = temp("repo")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "ref: refs/heads/feat/x\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    if let setup {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(".glance"), withIntermediateDirectories: true)
      try setup.write(to: root.appendingPathComponent(".glance/proof.json"), atomically: true, encoding: .utf8)
    }
    return root
  }

  @Test func noteAndPendingAndVerdict() {
    let s = store()
    _ = ProofTools.run(name: "proof_note", arguments: ["kind": "problem", "text": "Token refresh raced", "section": "Migrations"],
                       session: "s1", cwd: "/tmp", store: s)
    _ = ProofTools.run(name: "proof_pending", arguments: ["text": "Ask design"], session: "s1", cwd: "/tmp", store: s)
    _ = ProofTools.run(name: "proof_pending", arguments: ["text": "Ask design", "done": true], session: "s1", cwd: "/tmp", store: s)
    let (_, err) = ProofTools.run(name: "proof_verdict", arguments: ["verdict": "not-ready", "reasons": ["E2E missing"]],
                                  session: "s1", cwd: "/tmp", store: s)
    #expect(!err)
    let r = s.record(session: "s1")
    #expect(r?.notes.first?.section == "Migrations" && r?.notes.first?.kind == .problem)
    #expect(r?.pending.count == 1 && r?.pending.first?.done == true)
    #expect(r?.verdict?.verdict == .notReady && r?.verdict?.reasons == ["E2E missing"])
  }

  @Test func badArgumentsNameTheField() {
    let (value, err) = ProofTools.run(name: "proof_note", arguments: ["kind": "guess", "text": "x"], session: "s1", cwd: "/tmp", store: store())
    #expect(err && value.string == "kind must be one of tried, found, problem, resolved.")
    let (v2, e2) = ProofTools.run(name: "proof_verdict", arguments: ["verdict": "merge"], session: "s1", cwd: "/tmp", store: store())
    #expect(e2 && v2.string == "reasons is required: say why.")
  }

  @Test func anUnknownVerdictIsAnError() {
    let s = store()
    let (value, err) = ProofTools.run(name: "proof_verdict", arguments: ["verdict": "ship-it", "reasons": ["fine"]],
                                      session: "s1", cwd: "/tmp", store: s)
    #expect(err && value.string == "verdict must be one of merge, hold, not-ready.")
    #expect(s.record(session: "s1") == nil)
  }

  @Test func anUnknownToolIsAnError() {
    let (value, err) = ProofTools.run(name: "proof_nope", arguments: [:], session: "s1", cwd: "/tmp", store: store())
    #expect(err && value.string == "Unknown tool proof_nope.")
  }

  @Test func anUnsafeSessionIdIsAnErrorNotACrash() {
    let (value, err) = ProofTools.run(name: "proof_note", arguments: ["kind": "found", "text": "x"],
                                      session: "../etc", cwd: "/tmp", store: store())
    #expect(err && value.string == "Glance couldn't save the proof record; try again.")
  }

  @Test func recordsMadeByTheToolsCarryWhereTheSessionRuns() throws {
    let repo = try repo()
    let inner = repo.appendingPathComponent("Sources/App")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    let s = store()
    _ = ProofTools.run(name: "proof_note", arguments: ["kind": "found", "text": "x"], session: "n", cwd: inner.path, store: s)
    _ = ProofTools.run(name: "proof_pending", arguments: ["text": "y"], session: "p", cwd: inner.path, store: s)
    _ = ProofTools.run(name: "proof_verdict", arguments: ["verdict": "hold", "reasons": ["z"]], session: "v", cwd: inner.path, store: s)
    for session in ["n", "p", "v"] {
      let record = try #require(s.record(session: session))
      #expect(record.cwd == inner.path)
      #expect(record.worktree == repo.path)
      #expect(record.branch == "feat/x")
    }
  }

  @Test func captureCopiesFile() throws {
    let s = store()
    let dir = temp("cap")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: dir.appendingPathComponent("done.png"))
    let (_, err) = ProofTools.run(name: "proof_capture", arguments: ["path": "done.png", "caption": "Settings saved", "purpose": "outcome"],
                                  session: "s1", cwd: dir.path, store: s)
    #expect(!err)
    let c = try #require(s.record(session: "s1")?.captures.first)
    #expect(c.purpose == .outcome && c.source == .claude && c.kind == .screenshot && c.caption == "Settings saved")
    #expect(FileManager.default.fileExists(atPath: s.mediaFolder(session: "s1").appendingPathComponent(c.file).path))
  }

  @Test func aCaptureKeepsTheRecordsRepository() throws {
    let repo = try repo(setup: #"{"version":1}"#)
    try Data([9]).write(to: repo.appendingPathComponent("rec.mov"))
    let s = store()
    let args: JSONValue = ["path": .string(repo.appendingPathComponent("rec.mov").path), "caption": "Flow"]
    _ = ProofTools.run(name: "proof_note", arguments: ["kind": "found", "text": "x"], session: "s1", cwd: repo.path, store: s)
    let expected = GitCommonDir.normalize(repo.appendingPathComponent(".git").path)
    #expect(s.record(session: "s1")?.commonDir == expected)
    _ = ProofTools.run(name: "proof_capture", arguments: args, session: "s1", cwd: repo.path, store: s)
    let record = try #require(s.record(session: "s1"))
    #expect(record.captures.count == 1)
    #expect(record.commonDir == expected)
  }

  @Test func capturePurposeDefaultsToTestAndTakesTheEnvironmentAndPlace() throws {
    let repo = try repo(setup: """
      {"version":1,"environments":[{"name":"Local","url":"http://localhost:3000","match":["localhost:*"]}]}
      """)
    try Data([9]).write(to: repo.appendingPathComponent("rec.mov"))
    let s = store()
    let path = repo.appendingPathComponent("rec.mov").path
    let arguments: JSONValue = ["path": .string(path), "caption": "Flow", "url": "http://localhost:3000/login"]
    let (value, err) = ProofTools.run(name: "proof_capture", arguments: arguments, session: "s1", cwd: repo.path, store: s)
    #expect(!err && value["kind"]?.string == "clip")
    let record = try #require(s.record(session: "s1"))
    let c = try #require(record.captures.first)
    #expect(c.purpose == .test && c.environment == "Local" && c.url == "http://localhost:3000/login")
    #expect(record.worktree == repo.path && record.branch == "feat/x")
  }

  @Test func captureErrorsAreSentencesAndWriteNothing() throws {
    let s = store()
    let dir = temp("cap")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder.png"), withIntermediateDirectories: true)
    try Data([1]).write(to: dir.appendingPathComponent("a.png"))
    let (missing, e1) = ProofTools.run(name: "proof_capture", arguments: ["path": "/nope.png", "caption": "x"],
                                       session: "s1", cwd: "/tmp", store: s)
    #expect(e1 && missing.string == "No file at /nope.png.")
    let (folder, e2) = ProofTools.run(name: "proof_capture", arguments: ["path": "folder.png", "caption": "x"],
                                      session: "s1", cwd: dir.path, store: s)
    #expect(e2 && folder.string?.hasSuffix("isn't a file.") == true)
    let (purpose, e3) = ProofTools.run(name: "proof_capture", arguments: ["path": "a.png", "caption": "x", "purpose": "final"],
                                       session: "s1", cwd: dir.path, store: s)
    #expect(e3 && purpose.string == "purpose must be test or outcome.")
    let (caption, e4) = ProofTools.run(name: "proof_capture", arguments: ["path": "a.png"], session: "s1", cwd: dir.path, store: s)
    #expect(e4 && caption.string == "caption is required.")
    #expect(s.record(session: "s1") == nil)
  }

  @Test func onlyMediaAndLogsCanBeCaptured() throws {
    let s = store()
    let dir = temp("cap")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in [".env", "id_rsa", "server.pem", "notes.md", "Secrets.JSON"] {
      try Data([1]).write(to: dir.appendingPathComponent(name))
      let (value, err) = ProofTools.run(name: "proof_capture", arguments: ["path": .string(name), "caption": "x"],
                                        session: "s1", cwd: dir.path, store: s)
      #expect(err, "\(name) should be refused")
      #expect(value.string?.hasPrefix("proof_capture takes a screenshot") == true)
    }
    #expect(s.record(session: "s1") == nil)
    for (name, kind) in [("run.log", ProofCapture.Kind.file), ("out.TXT", .file), ("shot.JPEG", .screenshot), ("c.webm", .clip)] {
      try Data([1]).write(to: dir.appendingPathComponent(name))
      let (_, err) = ProofTools.run(name: "proof_capture", arguments: ["path": .string(name), "caption": .string(name)],
                                    session: "s1", cwd: dir.path, store: s)
      #expect(!err)
      #expect(s.record(session: "s1")?.captures.last?.kind == kind)
    }
  }

  @Test func aTildePathIsExpanded() {
    let name = "glance-proof-missing-\(UUID().uuidString).png"
    let (value, err) = ProofTools.run(name: "proof_capture", arguments: ["path": .string("~/" + name), "caption": "x"],
                                      session: "s1", cwd: "/tmp", store: store())
    #expect(err && value.string == "No file at \(NSHomeDirectory())/\(name).")
  }

  @Test func longTextIsClipped() throws {
    let s = store()
    let long = String(repeating: "é", count: 5_000)
    let dir = temp("cap")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data([1]).write(to: dir.appendingPathComponent("a.png"))
    _ = ProofTools.run(name: "proof_note", arguments: ["kind": "found", "text": .string(long), "section": .string(long)],
                       session: "s1", cwd: "/tmp", store: s)
    _ = ProofTools.run(name: "proof_pending", arguments: ["text": .string(long)], session: "s1", cwd: "/tmp", store: s)
    _ = ProofTools.run(name: "proof_verdict", arguments: ["verdict": "hold", "reasons": [.string(long), "short"]],
                       session: "s1", cwd: "/tmp", store: s)
    _ = ProofTools.run(name: "proof_capture",
                       arguments: ["path": "a.png", "caption": .string(long), "url": .string("http://x/" + long)],
                       session: "s1", cwd: dir.path, store: s)
    let r = try #require(s.record(session: "s1"))
    #expect(r.notes[0].text.count == 4_000 && r.notes[0].section?.count == 4_000)
    #expect(r.pending[0].text.count == 4_000)
    #expect(r.verdict?.reasons.map(\.count) == [4_000, 5])
    #expect(r.captures[0].caption.count == 4_000 && r.captures[0].url?.count == 4_000)
  }

  @Test func setupReportsMissing() {
    let (value, err) = ProofTools.run(name: "proof_setup", arguments: [:], session: "s1", cwd: "/", store: store())
    #expect(!err && value["status"]?.string == "missing")
  }

  @Test func setupReportsValidAndInvalid() throws {
    let valid = try repo(setup: #"{"version":1,"environments":[{"name":"Local","url":"http://localhost:3000"}],"sections":["Auth"]}"#)
    let (ok, e1) = ProofTools.run(name: "proof_setup", arguments: [:], session: "s1", cwd: valid.path, store: store())
    #expect(!e1 && ok["status"]?.string == "valid" && ok["root"]?.string == valid.path)
    #expect(ok["setup"]?["sections"]?.array == ["Auth"])
    #expect(ok["setup"]?["environments"]?.array?.first?["name"]?.string == "Local")

    let invalid = try repo(setup: "{\n  \"version\": 2\n}")
    let (bad, e2) = ProofTools.run(name: "proof_setup", arguments: [:], session: "s1", cwd: invalid.path, store: store())
    #expect(!e2 && bad["status"]?.string == "invalid")
    #expect(bad["problems"]?.array?.first?.string == "line 2: version must be 1.")
  }

  // MARK: - Which session

  func ledger(sessions: [TrackedSession], repo: String = "/r/.git") -> Ledger {
    let ledger = Ledger(folder: temp("ledger"))
    var state = TrackState(repo: repo)
    for session in sessions { state.sessions[session.id] = session }
    ledger.save(state)
    return ledger
  }

  func tracked(_ id: String, pid: Int32?, ended: Bool = false) -> TrackedSession {
    TrackedSession(id: id, worktree: "/r", branch: nil, pid: pid, terminal: nil, task: nil,
                   started: Date(timeIntervalSince1970: 1), ended: ended ? Date() : nil)
  }

  let inRepo: (String) -> RepoLocation? = { _ in RepoLocation(worktree: "/r", commonDir: "/r/.git", branch: nil) }

  @Test func theLiveSessionOfTheClaudeProcessIsFound() {
    let ledger = ledger(sessions: [tracked("s-1", pid: 4242), tracked("s-2", pid: 99)])
    let result = ProofTools.resolveSession(claudePID: 4242, cwd: "/r", location: inRepo, ledger: ledger, alive: { _ in true })
    #expect(result == .success("s-1"))
  }

  @Test func unknownSessionIsAnError() {
    let lead = "Glance can't tell which session this is"
    let empty = Ledger(folder: temp("ledger"))
    // No claude process above the tool.
    #expect(ProofTools.resolveSession(claudePID: nil, cwd: "/r", location: inRepo, ledger: empty, alive: { _ in true })
      == .failure(.init("\(lead): no claude process found above this tool.")))
    // A live pid the ledger doesn't know (Command Center off, or the session started before it was on).
    #expect(ProofTools.resolveSession(claudePID: 4242, cwd: "/r", location: inRepo, ledger: empty, alive: { _ in true })
      == .failure(.init("\(lead): this claude process isn't tracked. Is Command Center on in Glance Studio?")))
    // A folder outside git.
    #expect(ProofTools.resolveSession(claudePID: 4242, cwd: "/tmp/x", location: { _ in nil }, ledger: empty, alive: { _ in true })
      == .failure(.init("\(lead): /tmp/x isn't in a git repository.")))
    // Known, but ended or its process is gone: never a guess.
    let ended = ledger(sessions: [tracked("s-1", pid: 4242, ended: true)])
    #expect(ProofTools.resolveSession(claudePID: 4242, cwd: "/r", location: inRepo, ledger: ended, alive: { _ in true })
      == .failure(.init("\(lead): this claude process isn't tracked. Is Command Center on in Glance Studio?")))
    let gone = ledger(sessions: [tracked("s-1", pid: 4242)])
    #expect(ProofTools.resolveSession(claudePID: 4242, cwd: "/r", location: inRepo, ledger: gone, alive: { _ in false })
      == .failure(.init("\(lead): this claude process isn't tracked. Is Command Center on in Glance Studio?")))
  }

  // MARK: - Through the MCP framing

  /// The `tools/call` result a client reads from a reply line.
  func decode(_ line: String) throws -> (id: JSONValue, text: String, isError: Bool) {
    let message = try #require(JSONValue.parse(line))
    #expect(message["jsonrpc"]?.string == "2.0")
    let result = try #require(message["result"])
    return (try #require(message["id"]), result["content"]?.array?.first?["text"]?.string ?? "", result["isError"]?.bool ?? false)
  }

  @Test func repliesAreMCPToolResults() throws {
    let s = store()
    let ledger = ledger(sessions: [tracked("s-1", pid: 4242)])
    let ok = try decode(ProofTools.reply(id: 7, name: "proof_note", arguments: ["kind": "found", "text": "Found it"],
                                         claudePID: 4242, cwd: "/r", location: inRepo, ledger: ledger,
                                         alive: { _ in true }, store: s))
    #expect(ok.id == 7 && !ok.isError)
    #expect(JSONValue.parse(ok.text)?["recorded"]?.bool == true)
    #expect(s.record(session: "s-1")?.notes.first?.text == "Found it")

    let badArgument = try decode(ProofTools.reply(id: "a", name: "proof_note", arguments: ["kind": "guess", "text": "x"],
                                                  claudePID: 4242, cwd: "/r", location: inRepo, ledger: ledger,
                                                  alive: { _ in true }, store: s))
    #expect(badArgument.id == "a" && badArgument.isError && badArgument.text == "kind must be one of tried, found, problem, resolved.")

    let noSession = try decode(ProofTools.reply(id: 8, name: "proof_note", arguments: ["kind": "found", "text": "x"],
                                                claudePID: nil, cwd: "/r", location: inRepo, ledger: ledger,
                                                alive: { _ in true }, store: s))
    #expect(noSession.id == 8 && noSession.isError && noSession.text.hasPrefix("Glance can't tell which session this is"))
  }

  @Test func repliesToProofSetupWithAJSONText() throws {
    let ledger = ledger(sessions: [tracked("s-1", pid: 4242)])
    let reply = try decode(ProofTools.reply(id: 1, name: "proof_setup", arguments: [:], claudePID: 4242, cwd: "/",
                                            location: inRepo, ledger: ledger, alive: { _ in true }, store: store()))
    #expect(!reply.isError && JSONValue.parse(reply.text)?["status"]?.string == "missing")
  }

  // MARK: - Definitions

  @Test func definitionsNameFiveTools() {
    #expect(Set(ProofTools.definitions.compactMap { $0["name"]?.string }) == ProofTools.names)
    #expect(ProofTools.names == ["proof_note", "proof_pending", "proof_verdict", "proof_capture", "proof_setup"])
  }

  @Test func theToolListHasTheProofToolsOnlyForSessionsWithProofOn() {
    func names(_ assistant: Bool, _ proof: Bool) -> Set<String> {
      Set(ChannelTools.definitions(assistant: assistant, proof: proof).compactMap { $0["name"]?.string })
    }
    #expect(names(false, true).isSuperset(of: ProofTools.names))
    #expect(names(false, false).isDisjoint(with: ProofTools.names))
    #expect(names(true, true).isDisjoint(with: ProofTools.names))
    #expect(ChannelTools.definitions(assistant: false) == ChannelTools.definitions(assistant: false, proof: false))
    // The closed choices are enums, as in the other tools.
    func enumValues(_ tool: String, _ field: String) -> [String]? {
      ProofTools.definitions.first { $0["name"]?.string == tool }?["inputSchema"]?["properties"]?[field]?["enum"]?.array?.compactMap(\.string)
    }
    #expect(enumValues("proof_note", "kind") == ["tried", "found", "problem", "resolved"])
    #expect(enumValues("proof_verdict", "verdict") == ["merge", "hold", "not-ready"])
    #expect(enumValues("proof_capture", "purpose") == ["test", "outcome"])
    // Every proof tool schema says what it needs, so Claude can call it right the first time.
    for tool in ProofTools.definitions { #expect(tool["inputSchema"]?["required"]?.array != nil) }
  }
}
