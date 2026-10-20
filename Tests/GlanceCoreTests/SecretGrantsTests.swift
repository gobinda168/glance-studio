import Foundation
import Testing
@testable import GlanceCore

@Suite struct SecretGrantsTests {
  let secret = UUID()

  @Test func everyTimeAlwaysAsksAlwaysNeverAsks() {
    var grants = SecretGrants()
    grants.grant(session: 7, secret: secret)
    #expect(grants.needsAsking(.everyTime, session: 7, secret: secret))
    #expect(!grants.needsAsking(.always, session: 9, secret: secret))
  }

  @Test func oncePerSessionAsksUntilGrantedForThatSessionOnly() {
    var grants = SecretGrants()
    #expect(grants.needsAsking(.oncePerSession, session: 7, secret: secret))
    grants.grant(session: 7, secret: secret)
    #expect(!grants.needsAsking(.oncePerSession, session: 7, secret: secret))
    #expect(grants.needsAsking(.oncePerSession, session: 8, secret: secret))
    #expect(grants.needsAsking(.oncePerSession, session: 7, secret: UUID()))
  }

  @Test func grantsEndWithTheSessionAndWhenTheSecretChanges() {
    var grants = SecretGrants()
    grants.grant(session: 7, secret: secret)
    grants.end(session: 7)
    #expect(grants.needsAsking(.oncePerSession, session: 7, secret: secret))
    grants.grant(session: 7, secret: secret)
    grants.forget(secret: secret)
    #expect(grants.needsAsking(.oncePerSession, session: 7, secret: secret))
  }

  @Test func endingOneSessionOrSecretLeavesTheOthersGranted() {
    var grants = SecretGrants()
    let other = UUID()
    grants.grant(session: 7, secret: secret)
    grants.grant(session: 8, secret: secret)
    grants.grant(session: 7, secret: other)
    grants.end(session: 7)
    #expect(!grants.needsAsking(.oncePerSession, session: 8, secret: secret))
    grants.grant(session: 7, secret: secret)
    grants.forget(secret: secret)
    #expect(grants.needsAsking(.oncePerSession, session: 8, secret: secret))
    grants.grant(session: 7, secret: other)
    grants.forget(secret: secret)
    #expect(!grants.needsAsking(.oncePerSession, session: 7, secret: other))
  }

  private func activity(_ index: Int) -> SecretActivity {
    SecretActivity(date: Date(timeIntervalSince1970: Double(index)), session: "acme", folder: nil,
                   secret: "GITHUB_TOKEN", method: "GET", host: "api.github.com", path: "/\(index)",
                   outcome: "200", bytes: index)
  }

  private func temporaryLog() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("secrets-log-\(UUID().uuidString).jsonl")
  }

  @Test func theLogKeepsTheNewestThousand() throws {
    let url = temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let log = SecretActivityLog(url: url)
    for index in 0..<1_210 { log.append(activity(index)) }
    let recent = log.recent(limit: 2_000)
    #expect(recent.count <= 1_200 && recent.count >= SecretActivityLog.keep)
    #expect(recent.first?.path == "/1209")
    #expect(log.recent(limit: 2).map(\.path) == ["/1209", "/1208"])
  }

  @Test func theLogFileIsPrivateBeforeAndAfterATrim() throws {
    let url = temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let log = SecretActivityLog(url: url)
    func mode() throws -> Int {
      (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    log.append(activity(0))
    #expect(try mode() == 0o600)
    for index in 1..<1_250 { log.append(activity(index)) }
    #expect(try mode() == 0o600)
    #expect(log.recent(limit: 5).count == 5)
  }

  @Test func oneEntryIsOneLineWhateverItsTextHolds() throws {
    let url = temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let log = SecretActivityLog(url: url)
    var tricky = activity(1)
    tricky.outcome = "failed: line one\nline two\u{2028}end"
    tricky.path = "/a\nb"
    log.append(tricky)
    log.append(activity(2))
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.split(separator: "\n", omittingEmptySubsequences: true).count == 2)
    #expect(log.recent(limit: 10).count == 2)
    #expect(log.recent(limit: 10).last == tricky)
  }

  @Test func aHugeFieldIsClippedSoTheFileCannotGrowWithoutBound() throws {
    let url = temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let log = SecretActivityLog(url: url)
    var huge = activity(1)
    huge.path = "/" + String(repeating: "a", count: 1_000_000)
    huge.outcome = "failed: " + String(repeating: "e\u{301}", count: 500_000)
    log.append(huge)
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? .max
    #expect(size < 20_000)
    let stored = try #require(log.recent(limit: 1).first)
    #expect(stored.path.unicodeScalars.count == SecretActivity.fieldLimit)
    #expect(stored.host == "api.github.com")
  }

  @Test func theLogKeepsHostAndPathNeverAQueryOrFragment() {
    let url = temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let log = SecretActivityLog(url: url)
    var entry = activity(1)
    entry.path = "/repos/x?token=abc#frag"
    log.append(entry)
    var fragmentOnly = activity(2)
    fragmentOnly.path = "/a#b?c"
    log.append(fragmentOnly)
    #expect(log.recent(limit: 2).map(\.path) == ["/a", "/repos/x"])
  }

  @Test func aDelimiterFollowedByACombiningMarkStillCutsThePath() {
    let url = temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let log = SecretActivityLog(url: url)
    var question = activity(1)
    question.path = "/a?\u{301}t=1"
    log.append(question)
    var hash = activity(2)
    hash.path = "/a#\u{301}x"
    log.append(hash)
    #expect(log.recent(limit: 2).map(\.path) == ["/a", "/a"])
  }

  @Test func aTornLastLineCannotSwallowTheNextEntry() throws {
    let url = temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let log = SecretActivityLog(url: url)
    log.append(activity(1))
    let handle = try FileHandle(forWritingTo: url)
    handle.seekToEndOfFile()
    handle.write(Data("{\"date\":\"1970-01-01T00:00:0".utf8))
    try handle.close()
    log.append(activity(2))
    log.append(activity(3))
    #expect(log.recent(limit: 10).map(\.path) == ["/3", "/2", "/1"])
  }

  @Test func anUnwritableLogIsSilentNotFatal() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("secrets-ro-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
      try? FileManager.default.removeItem(at: folder)
    }
    let url = folder.appendingPathComponent("log.jsonl")
    let log = SecretActivityLog(url: url)
    log.append(activity(1))
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
    log.append(activity(2))
    #expect(log.recent(limit: 5).map(\.path) == ["/1"])
  }

  @Test func aDamagedLineIsSkippedNotFatal() throws {
    let url = temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let log = SecretActivityLog(url: url)
    log.append(activity(1))
    let handle = try FileHandle(forWritingTo: url)
    handle.seekToEndOfFile()
    handle.write(Data("{not json\n".utf8))
    try handle.close()
    log.append(activity(2))
    #expect(log.recent(limit: 10).map(\.path) == ["/2", "/1"])
  }

  @Test func theProcessTableKnowsThisProcess() {
    let me = getpid()
    #expect(ProcessTable.parent(of: me) == getppid())
    let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
    #expect(ProcessTable.cwd(of: me).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == here)
    #expect(ProcessTable.parent(of: -1) == nil)
    #expect(ProcessTable.cwd(of: -1) == nil)
    #expect(ProcessTable.parent(of: 0) == nil)
    #expect(ProcessTable.cwd(of: 0) == nil)
  }

  @Test func theProcessTableReportsAChildsOwnFolderNotOurs() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("proc-table-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/cat")
    child.currentDirectoryURL = folder
    let stdin = Pipe()
    child.standardInput = stdin
    child.standardOutput = FileHandle.nullDevice
    try child.run()
    defer {
      try? stdin.fileHandleForWriting.close()
      child.waitUntilExit()
    }
    let pid = child.processIdentifier
    #expect(ProcessTable.parent(of: pid) == getpid())
    let reported = ProcessTable.cwd(of: pid).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    #expect(reported == folder.resolvingSymlinksInPath().path)
  }
}
