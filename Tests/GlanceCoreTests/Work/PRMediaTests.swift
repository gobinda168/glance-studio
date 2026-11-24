import Darwin
import Foundation
import Testing
@testable import GlanceCore

// PR media: what a hostile PR body can make Glance download. Nothing here touches the network or a real `gh`: gh is a
// shell script in a temporary folder, and the plain-web path talks to a server on this Mac's loopback.

// MARK: - Helpers

private func temporaryFolder() -> URL {
  let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prmedia-" + UUID().uuidString, isDirectory: true)
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func entries(_ folder: URL) -> [String] {
  ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

private func failureMessage<T>(_ result: Result<T, ProofPR.Failure>) -> String? {
  if case .failure(let failure) = result { return failure.message }
  return nil
}

/// Runs blocking work on a thread of its own. These tests wait on processes and sockets, and a test that parks one of the
/// cooperative threads for that long starves the rest of the suite.
private func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
  await withCheckedContinuation { continuation in
    Thread.detachNewThread { continuation.resume(returning: work()) }
  }
}

private let attachment = URL(string: "https://github.com/user-attachments/assets/8f2c1d3e-1111-4222-8333-444455556666")!

// MARK: - The gh -i header block

@Suite struct PRMediaHeaderTests {
  private func parse(_ text: String) -> PRMedia.HeaderParse { PRMedia.parseHeaders(Data(text.utf8)) }

  @Test func aFinal200WithTypeAndLength() {
    let text = "HTTP/2.0 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 6563354\r\nServer: x\r\n\r\nBYTES"
    guard case .headers(let headers, let bodyStart) = parse(text) else { Issue.record("not parsed"); return }
    #expect(headers.status == 200 && headers.contentType == "video/mp4" && headers.contentLength == 6_563_354)
    #expect(String(decoding: Data(text.utf8).dropFirst(bodyStart), as: UTF8.self) == "BYTES")
  }

  @Test func headerNamesAreCaseInsensitiveAndBareNewlinesWork() {
    let text = "HTTP/1.1 200 OK\ncontent-type: Image/PNG; charset=binary\ncontent-length: 12\n\nabc"
    guard case .headers(let headers, let bodyStart) = parse(text) else { Issue.record("not parsed"); return }
    #expect(headers.contentType == "Image/PNG; charset=binary" && headers.contentLength == 12)
    #expect(String(decoding: Data(text.utf8).dropFirst(bodyStart), as: UTF8.self) == "abc")
  }

  @Test func noLengthIsNilNotZero() {
    guard case .headers(let headers, _) = parse("HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\n\r\n") else { Issue.record("not parsed"); return }
    #expect(headers.contentLength == nil)
  }

  @Test func aRedirectIsReportedAsItsStatusNotFollowed() {
    // gh follows redirects, so the block is the final answer; a 3xx here means gh gave up, and is not media.
    guard case .headers(let headers, _) = parse("HTTP/1.1 302 Found\r\nLocation: https://example.com/x\r\n\r\n") else {
      Issue.record("not parsed"); return
    }
    #expect(headers.status == 302 && headers.contentType == nil)
  }

  @Test func anInterimResponseIsSkipped() {
    guard case .headers(let headers, _) = parse("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\nx") else {
      Issue.record("not parsed"); return
    }
    #expect(headers.status == 200 && headers.contentType == "image/png")
  }

  @Test func halfAHeaderNeedsMore() {
    #expect(parse("HTTP/1.1 200 OK\r\nContent-Type: image/p") == .needMore)
    #expect(parse("") == .needMore)
  }

  @Test func malformedBlocksAreRefused() {
    #expect(parse("not http at all\r\n\r\nbody") == .malformed)
    #expect(parse("HTTP/1.1 abc OK\r\n\r\n") == .malformed)
    #expect(parse("\u{89}PNG\r\n\u{1a}\n\r\n\r\n") == .malformed) // the file itself, with no headers in front
    #expect(PRMedia.parseHeaders(Data(repeating: 0x61, count: 64 * 1024)) == .malformed) // no end of headers in sight
  }

  @Test func aHostileLengthIsNotTrusted() {
    guard case .headers(let headers, _) = parse("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: -5\r\n\r\n") else {
      Issue.record("not parsed"); return
    }
    #expect(headers.contentLength == nil)
    guard case .headers(let big, _) = parse("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 99999999999999999999999\r\n\r\n") else {
      Issue.record("not parsed"); return
    }
    #expect(big.contentLength == nil)
  }
}

// MARK: - What counts as media

@Suite struct PRMediaTypeTests {
  @Test func imagesAndVideosOnly() {
    #expect(PRMedia.mediaType(contentType: "image/png")?.ext == "png")
    #expect(PRMedia.mediaType(contentType: "image/jpeg")?.ext == "jpg")
    #expect(PRMedia.mediaType(contentType: "image/gif")?.ext == "gif")
    #expect(PRMedia.mediaType(contentType: "image/webp")?.kind == .image)
    #expect(PRMedia.mediaType(contentType: "video/mp4")?.ext == "mp4")
    #expect(PRMedia.mediaType(contentType: "video/quicktime")?.ext == "mov")
    #expect(PRMedia.mediaType(contentType: "video/webm")?.kind == .video)
    #expect(PRMedia.mediaType(contentType: "text/html") == nil)
    #expect(PRMedia.mediaType(contentType: "application/pdf") == nil)
    #expect(PRMedia.mediaType(contentType: "application/octet-stream") == nil)
    #expect(PRMedia.mediaType(contentType: "") == nil)
  }

  @Test func parametersAndCaseAreIgnored() {
    #expect(PRMedia.mediaType(contentType: " Image/PNG ; charset=binary")?.ext == "png")
    #expect(PRMedia.mediaType(contentType: "VIDEO/MP4")?.kind == .video)
  }

  @Test func svgIsRefusedFromTheNetwork() {
    // An SVG is a document: it can carry script and external references.
    #expect(PRMedia.mediaType(contentType: "image/svg+xml") == nil)
    #expect(PRMedia.mediaType(contentType: "image/svg+xml; charset=utf-8") == nil)
    #expect(PRMedia.mediaType(contentType: "IMAGE/SVG+XML") == nil)
  }

  @Test func aSubtypeWithoutAKnownFileExtensionIsRefused() {
    #expect(PRMedia.mediaType(contentType: "image/x-evil") == nil)
    #expect(PRMedia.mediaType(contentType: "image/") == nil)
    #expect(PRMedia.mediaType(contentType: "image") == nil)
    #expect(PRMedia.mediaType(contentType: "image/png/../x") == nil)
  }
}

// MARK: - Where a download lives

@Suite struct PRMediaCacheTests {
  @Test func theCacheNameIsTheHashOfTheURL() {
    let name = PRMedia.cacheName(attachment)
    #expect(name.count == 64 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(name == PRMedia.cacheName(URL(string: attachment.absoluteString)!))
    #expect(name != PRMedia.cacheName(URL(string: attachment.absoluteString + "x")!))
  }

  @Test func aFetchLandsAsHashDotExtensionAndIsFoundAgain() throws {
    let folder = temporaryFolder().appendingPathComponent("pr")
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    let result = PRMedia.fetch(url: attachment, into: folder, limit: 1_000) { _, destination, _ in
      try? Data("PNGDATA".utf8).write(to: destination)
      return .success((contentType: "image/png", bytes: 7))
    }
    let fetched = try result.get()
    #expect(fetched.file.lastPathComponent == PRMedia.cacheName(attachment) + ".png")
    #expect(fetched.kind == .image && fetched.bytes == 7 && fetched.contentType == "image/png")
    #expect(entries(folder) == [PRMedia.cacheName(attachment) + ".png"]) // no temp file left
    #expect(PRMedia.cachedFile(for: attachment, in: folder)?.lastPathComponent == PRMedia.cacheName(attachment) + ".png")
    #expect(PRMedia.cachedFile(for: URL(string: "https://example.com/other.png")!, in: folder) == nil)
  }

  @Test func aVideoGetsItsExtensionFromTheContentType() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fetched = try PRMedia.fetch(url: attachment, into: folder, limit: 1_000) { _, destination, _ in
      try? Data("MP4".utf8).write(to: destination)
      return .success((contentType: "video/mp4", bytes: 3))
    }.get()
    #expect(fetched.file.pathExtension == "mp4" && fetched.kind == .video)
  }

  @Test func aDownloaderThatSaysSvgOrHtmlLeavesNothing() {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for type in ["image/svg+xml", "text/html", "application/pdf"] {
      let result = PRMedia.fetch(url: attachment, into: folder, limit: 1_000) { _, destination, _ in
        try? Data("<svg/>".utf8).write(to: destination)
        return .success((contentType: type, bytes: 6))
      }
      #expect(failureMessage(result) != nil, "\(type)")
    }
    #expect(entries(folder).isEmpty)
  }

  @Test func aFailureLeavesNoFile() {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let result = PRMedia.fetch(url: attachment, into: folder, limit: 1_000) { _, destination, _ in
      try? Data("half".utf8).write(to: destination)
      return .failure(ProofPR.Failure("connection lost"))
    }
    #expect(failureMessage(result) == "connection lost")
    #expect(entries(folder).isEmpty)
  }

  @Test func aFileOverTheLimitIsRefusedEvenIfTheDownloaderAllowedIt() {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let result = PRMedia.fetch(url: attachment, into: folder, limit: 4) { _, destination, _ in
      try? Data("123456789".utf8).write(to: destination)
      return .success((contentType: "image/png", bytes: 9))
    }
    #expect(failureMessage(result) != nil)
    #expect(entries(folder).isEmpty)
  }
}

// MARK: - Routing: a GitHub token goes to GitHub attachments and nowhere else

@Suite struct PRMediaRoutingTests {
  private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [(via: String, url: String)] = []
    func add(_ via: String, _ url: URL) { lock.lock(); urls.append((via, url.absoluteString)); lock.unlock() }
    var all: [(via: String, url: String)] { lock.lock(); defer { lock.unlock() }; return urls }
  }

  private func route(_ address: String) -> [(via: String, url: String)] {
    let calls = Calls()
    let destination = URL(fileURLWithPath: "/nonexistent/never-written")
    _ = PRMedia.download(url: URL(string: address)!, to: destination, limit: 10,
                         gh: { url, _, _ in calls.add("gh", url); return .failure(ProofPR.Failure("stub")) },
                         web: { url, _, _ in calls.add("web", url); return .failure(ProofPR.Failure("stub")) })
    return calls.all
  }

  @Test func aGitHubAttachmentGoesThroughGhAndOnlyGh() {
    let calls = route(attachment.absoluteString)
    #expect(calls.count == 1 && calls[0].via == "gh")
  }

  @Test func everyOtherHostGoesThroughThePlainWebAndNeverGh() {
    for address in ["https://example.com/a.png", "https://raw.githubusercontent.com/o/r/main/a.png",
                    "https://user-images.githubusercontent.com/1/a.png", "https://camo.githubusercontent.com/abc",
                    "https://github.com.evil.example/user-attachments/assets/8f2c1d3e",
                    "https://evil.example/github.com/user-attachments/assets/8f2c1d3e"] {
      let calls = route(address)
      #expect(calls.count == 1 && calls[0].via == "web", "\(address)")
    }
  }

  @Test func lookalikesOfAnAttachmentOnGitHubItselfAreNotAttachments() {
    for address in ["https://github.com/user-attachments/files/123/report.pdf", "https://github.com/user-attachments/assets/a/b",
                    "https://github.com/user-attachments/assets/../../settings", "https://github.com/user-attachments/assets/%2e%2e/x",
                    "https://www.github.com/user-attachments/assets/8f2c1d3e", "https://github.com:8443/user-attachments/assets/8f2c1d3e",
                    "https://github.com/octocat/hello/raw/main/a.png"] {
      #expect(route(address).allSatisfy { $0.via == "web" }, "\(address)")
    }
  }

  @Test func ghItselfRefusesAnythingButAnAttachment() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let marker = folder.appendingPathComponent("ran")
    let script = folder.appendingPathComponent("gh")
    try "#!/bin/sh\ntouch '\(marker.path)'\nprintf 'HTTP/1.1 200 OK\\r\\nContent-Type: image/png\\r\\n\\r\\nx'\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    for address in ["https://example.com/a.png", "https://api.github.com/user", "http://github.com/user-attachments/assets/x",
                    "https://github.com/user-attachments/files/1/x.png", "file:///etc/passwd"] {
      let result = GitHubCLI.download(url: URL(string: address)!, to: folder.appendingPathComponent("out"), limit: 100,
                                      executable: script.path)
      #expect(failureMessage(result) != nil, "\(address)")
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path), "gh was started for a URL that is not an attachment")
  }
}

// MARK: - GitHubCLI.download against a stand-in gh

@Suite struct GitHubCLIDownloadTests {
  /// A `gh` that prints `output` (printf format) for any arguments, then exits with `status`.
  private func fakeGh(in folder: URL, _ body: String, status: Int = 0, stderr: String = "") throws -> String {
    let script = folder.appendingPathComponent("gh")
    try "#!/bin/sh\n\(body)\n[ -n '\(stderr)' ] && echo '\(stderr)' >&2\nexit \(status)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script.path
  }

  private func run(_ body: String, status: Int = 0, stderr: String = "", limit: Int64 = 1_000, timeout: TimeInterval = 20) async throws
    -> (result: Result<(contentType: String, bytes: Int64), ProofPR.Failure>, folder: URL, out: URL) {
    let folder = temporaryFolder()
    let gh = try fakeGh(in: folder, body, status: status, stderr: stderr)
    let out = folder.appendingPathComponent("download")
    let result = await offPool { GitHubCLI.download(url: attachment, to: out, limit: limit, executable: gh, timeout: timeout) }
    return (result, folder, out)
  }

  private func files(_ folder: URL) -> [String] { entries(folder).filter { $0 != "gh" } }

  @Test func aMediaAnswerIsWrittenAndRenamedIntoPlace() async throws {
    let (result, folder, out) = try await run(#"printf 'HTTP/2.0 200 OK\r\nContent-Type: image/png\r\nContent-Length: 11\r\n\r\nhello world'"#)
    defer { try? FileManager.default.removeItem(at: folder) }
    let done = try result.get()
    #expect(done.contentType == "image/png" && done.bytes == 11)
    #expect(try Data(contentsOf: out) == Data("hello world".utf8))
    #expect(files(folder) == ["download"])
  }

  @Test func anAnswerWithNoLengthIsAcceptedWhenItEndsInTime() async throws {
    let (result, folder, out) = try await run(#"printf 'HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\n\r\n0123456789'"#)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(try result.get().bytes == 10)
    #expect(FileManager.default.fileExists(atPath: out.path))
  }

  @Test func a404WithABodyIsNotTheFile() async throws {
    // gh exits 1 and prints the error body on stdout.
    let (result, folder, _) = try await run(#"printf 'HTTP/2.0 404 Not Found\r\nContent-Type: image/png\r\n\r\n{"message":"Not Found"}'"#,
                                      status: 1, stderr: "gh: Not Found (HTTP 404)")
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(files(folder).isEmpty)
  }

  @Test func a200ThatGhThenFailedOnIsNotTheFile() async throws {
    let (result, folder, _) = try await run(#"printf 'HTTP/2.0 200 OK\r\nContent-Type: image/png\r\n\r\nabc'"#, status: 1, stderr: "gh: stream error")
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result)?.contains("stream error") == true)
    #expect(files(folder).isEmpty)
  }

  @Test func aBodyShorterThanItsLengthIsNotTheFile() async throws {
    let (result, folder, _) = try await run(#"printf 'HTTP/2.0 200 OK\r\nContent-Type: image/png\r\nContent-Length: 500\r\n\r\nshort'"#)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(files(folder).isEmpty)
  }

  @Test func nonMediaAndSvgAreRefusedBeforeAnyByteIsKept() async throws {
    for type in ["text/html", "application/octet-stream", "image/svg+xml", "application/pdf"] {
      let (result, folder, _) = try await run(#"printf 'HTTP/2.0 200 OK\r\nContent-Type: \#(type)\r\n\r\n<svg onload=alert(1)>'"#)
      defer { try? FileManager.default.removeItem(at: folder) }
      #expect(failureMessage(result) != nil, "\(type)")
      #expect(files(folder).isEmpty, "\(type)")
    }
  }

  @Test func aMissingContentTypeIsRefused() async throws {
    let (result, folder, _) = try await run(#"printf 'HTTP/2.0 200 OK\r\nContent-Length: 3\r\n\r\nabc'"#)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(files(folder).isEmpty)
  }

  @Test func aRedirectHeaderBlockIsRefused() async throws {
    let (result, folder, _) = try await run(#"printf 'HTTP/2.0 302 Found\r\nLocation: https://example.com/x.png\r\n\r\n'"#)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(files(folder).isEmpty)
  }

  @Test func malformedOutputIsRefused() async throws {
    let (result, folder, _) = try await run(#"printf 'this is not http\r\n\r\nbytes'"#)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(files(folder).isEmpty)
  }

  @Test func aDeclaredLengthOverTheLimitIsRefusedWithoutReadingTheBody() async throws {
    let started = Date()
    let (result, folder, _) = try await run(#"printf 'HTTP/2.0 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 2147483648\r\n\r\n'; sleep 15"#, limit: 1_000)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(files(folder).isEmpty)
    #expect(Date().timeIntervalSince(started) < 10, "gh was waited on instead of stopped")
  }

  @Test func aStreamWithNoLengthIsCutAtTheLimitAndGhIsStopped() async throws {
    let started = Date()
    let (result, folder, _) = try await run(#"printf 'HTTP/2.0 200 OK\r\nContent-Type: video/mp4\r\n\r\n'; yes 0123456789abcdef | head -c 4000000; sleep 15"#,
                                      limit: 100_000)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(files(folder).isEmpty) // not even the first 100 KB stay
    #expect(Date().timeIntervalSince(started) < 10)
  }

  @Test func aGhThatHangsIsStoppedAtTheTimeout() async throws {
    let started = Date()
    let (result, folder, _) = try await run(#"printf 'HTTP/2.0 200 OK\r\nContent-Type: video/mp4\r\n\r\nabc'; sleep 30"#, timeout: 1.5)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(files(folder).isEmpty)
    #expect(Date().timeIntervalSince(started) < 15)
  }

  @Test func ghMissingOrSignedOutReadsAsAFailure() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let out = folder.appendingPathComponent("o")
    let missing = folder.appendingPathComponent("no-such-gh").path
    #expect(failureMessage(GitHubCLI.download(url: attachment, to: out, limit: 10, executable: nil)) != nil)
    #expect(failureMessage(GitHubCLI.download(url: attachment, to: out, limit: 10, executable: missing)) != nil)
    let (signedOut, other, _) = try await run("echo 'To get started with GitHub CLI, please run: gh auth login' >&2", status: 4)
    defer { try? FileManager.default.removeItem(at: other) }
    #expect(failureMessage(signedOut) == PullRequests.Failure.signedOut.message)
  }
}

// MARK: - The plain web path, against a server on the loopback

/// A one-purpose HTTP server on 127.0.0.1: `respond` gets the request path and writes the whole answer to the socket.
private final class LoopbackServer: @unchecked Sendable {
  let port: UInt16
  private let listener: Int32
  private let lock = NSLock()
  private var seen: [(path: String, headers: String)] = []
  private let respond: @Sendable (String, Int32) -> Void

  var requests: [(path: String, headers: String)] { lock.lock(); defer { lock.unlock() }; return seen }

  init(_ respond: @escaping @Sendable (String, Int32) -> Void) {
    self.respond = respond
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    listener = fd
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    address.sin_port = 0
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    listen(fd, 16)
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    port = UInt16(bigEndian: bound.sin_port)
    Thread.detachNewThread { [self] in
      while true {
        let connection = accept(listener, nil, nil)
        if connection < 0 { return }
        var off: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &off, socklen_t(MemoryLayout<Int32>.size))
        Thread.detachNewThread { [self] in serve(connection) }
      }
    }
  }

  deinit { close(listener) }

  func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

  private func serve(_ connection: Int32) {
    defer { close(connection) }
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !request.suffix(4).elementsEqual([13, 10, 13, 10]) && request.count < 16_384 {
      let n = read(connection, &buffer, buffer.count)
      if n <= 0 { return }
      request.append(contentsOf: buffer[0..<n])
    }
    let text = String(decoding: request, as: UTF8.self)
    let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
    lock.lock(); seen.append((path, text)); lock.unlock()
    respond(path, connection)
  }

  static func send(_ connection: Int32, _ text: String) { send(connection, Data(text.utf8)) }
  static func send(_ connection: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = write(connection, raw.baseAddress! + offset, raw.count - offset)
        if n <= 0 { return }
        offset += n
      }
    }
  }
}

@Suite struct PRMediaWebTests {
  private func get(_ server: LoopbackServer, _ path: String, limit: Int64 = 10_000, folder: URL? = nil) async
    -> (result: Result<(contentType: String, bytes: Int64), ProofPR.Failure>, folder: URL, out: URL) {
    let folder = folder ?? temporaryFolder()
    let out = folder.appendingPathComponent("download")
    let address = server.url(path)
    // The first request may go to the loopback in a test; every redirect after it is judged by the real rules.
    let result = await offPool { PRMedia.fetchPublic(url: address, to: out, limit: limit, allowsFirst: { $0.host == "127.0.0.1" }) }
    return (result, folder, out)
  }

  private let png = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcd"

  @Test func aPlainImageIsDownloadedWithNoCredentialsOrCookies() async throws {
    let server = LoopbackServer { path, connection in
      if path == "/cookie" {
        LoopbackServer.send(connection, "HTTP/1.1 200 OK\r\nSet-Cookie: session=secret; Path=/\r\nContent-Type: image/png\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcd")
      } else {
        LoopbackServer.send(connection, "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcd")
      }
    }
    let (first, folder, out) = await get(server, "/cookie")
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(try first.get().bytes == 4 && (try Data(contentsOf: out)) == Data("abcd".utf8))
    _ = await get(server, "/next", folder: folder)
    let headers = (server.requests.last?.headers ?? "").lowercased()
    #expect(!headers.contains("cookie:"), "a cookie from one fetch was sent on the next")
    #expect(!headers.contains("authorization:"))
    #expect(files(folder) == ["download"])
  }

  private func files(_ folder: URL) -> [String] { entries(folder) }

  @Test func aRedirectToHttpIsRefusedAndNeverFollowed() async throws {
    let target = LoopbackServer { _, connection in LoopbackServer.send(connection, "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcd") }
    let server = LoopbackServer { _, connection in
      LoopbackServer.send(connection, "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(target.port)/stolen.png\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }
    let (result, folder, _) = await get(server, "/r")
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(target.requests.isEmpty, "the redirect target was contacted")
    #expect(files(folder).isEmpty)
  }

  @Test func aRedirectToALoopbackOrIpLiteralOrLocalHostIsRefused() async throws {
    for location in ["https://127.0.0.1/a.png", "https://localhost/a.png", "https://printer.local/a.png", "https://[::1]/a.png",
                     "https://10.0.0.5/a.png", "https://169.254.169.254/latest/meta-data/", "https://user:pw@example.com/a.png",
                     "https://example.com:8443/a.png", "https://intranet.corp/a.png", "ftp://example.com/a.png", "file:///etc/passwd"] {
      let server = LoopbackServer { _, connection in
        LoopbackServer.send(connection, "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      }
      let (result, folder, _) = await get(server, "/r")
      defer { try? FileManager.default.removeItem(at: folder) }
      #expect(failureMessage(result) != nil, "\(location)")
      #expect(files(folder).isEmpty, "\(location)")
    }
  }

  @Test func aLoopbackOrIpLiteralOrLocalFirstURLIsRefusedWithoutConnecting() async throws {
    let server = LoopbackServer { _, connection in LoopbackServer.send(connection, "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcd") }
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for address in ["http://127.0.0.1:\(server.port)/a.png", "https://127.0.0.1:\(server.port)/a.png", "https://localhost:\(server.port)/a.png",
                    "https://[::1]:\(server.port)/a.png", "https://10.1.2.3/a.png", "https://x.local/a.png", "https://169.254.169.254/x.png",
                    "https://2130706433/a.png", "https://0x7f.1/a.png"] {
      let url = URL(string: address)!, out = folder.appendingPathComponent("o")
      let result = await offPool { PRMedia.fetchPublic(url: url, to: out, limit: 1_000) }
      #expect(failureMessage(result) != nil, "\(address)")
    }
    #expect(server.requests.isEmpty, "the server on this Mac was contacted")
    #expect(files(folder).isEmpty)
  }

  @Test func publicAddressesAreTold() {
    for ip in ["8.8.8.8", "1.1.1.1", "140.82.112.3", "2606:4700:4700::1111", "2a00:1450:4001:81b::200e"] {
      #expect(PRMedia.isPublicAddress(ip), "\(ip)")
    }
    for ip in ["127.0.0.1", "127.9.9.9", "0.0.0.0", "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254",
               "100.64.0.1", "224.0.0.1", "255.255.255.255", "::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1",
               "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:192.168.0.1", "64:ff9b::7f00:1", "not an address"] {
      #expect(!PRMedia.isPublicAddress(ip), "\(ip)")
    }
    #expect(PRMedia.isPublicAddress("::ffff:8.8.8.8"))
  }

  @Test func aBodyPastTheLimitIsAbortedAndNothingStays() async throws {
    // No Content-Length: the limit has to be enforced while reading.
    let server = LoopbackServer { _, connection in
      LoopbackServer.send(connection, "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nConnection: close\r\n\r\n")
      let chunk = Data(repeating: 0x41, count: 16 * 1024)
      for _ in 0..<2_000 { LoopbackServer.send(connection, chunk) } // 32 MB offered
    }
    let (result, folder, _) = await get(server, "/big", limit: 100_000)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(files(folder).isEmpty)
  }

  @Test func aDeclaredLengthPastTheLimitIsRefusedAtTheHeaders() async throws {
    let server = LoopbackServer { _, connection in
      LoopbackServer.send(connection, "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 2147483648\r\nConnection: close\r\n\r\n")
      LoopbackServer.send(connection, Data(repeating: 0x41, count: 4096))
    }
    let (result, folder, _) = await get(server, "/huge", limit: 50 << 20)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(files(folder).isEmpty)
  }

  @Test func theNormalLimitIs50MB() {
    #expect(PRMedia.maxBytes == 50 << 20)
    #expect(PRMedia.maxItems == 20)
  }

  @Test func nonMediaSvgAndErrorsAreRefused() async throws {
    for (label, head) in [("html", "200 OK\r\nContent-Type: text/html"), ("svg", "200 OK\r\nContent-Type: image/svg+xml"),
                          ("no type", "200 OK"), ("404", "404 Not Found\r\nContent-Type: image/png"),
                          ("octet", "200 OK\r\nContent-Type: application/octet-stream")] {
      let server = LoopbackServer { _, connection in
        LoopbackServer.send(connection, "HTTP/1.1 \(head)\r\nContent-Length: 6\r\nConnection: close\r\n\r\n<svg/>")
      }
      let (result, folder, _) = await get(server, "/x")
      defer { try? FileManager.default.removeItem(at: folder) }
      #expect(failureMessage(result) != nil, "\(label)")
      #expect(files(folder).isEmpty, "\(label)")
    }
  }

  @Test func aConnectionThatDropsMidBodyIsNotAFile() async throws {
    let server = LoopbackServer { _, connection in
      LoopbackServer.send(connection, "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 1000\r\nConnection: close\r\n\r\nonly a little")
    }
    let (result, folder, _) = await get(server, "/cut")
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(failureMessage(result) != nil)
    #expect(files(folder).isEmpty)
  }

  @Test func aRedirectToAnAllowedURLIsStillCheckedByHostRules() {
    // The rule a redirect target faces is AssetLinks.find's, plus: it must resolve to a public address.
    #expect(PRMedia.allowsRedirect(to: URL(string: "https://example.com/a.png")!, resolves: { _ in true }))
    #expect(!PRMedia.allowsRedirect(to: URL(string: "https://example.com/a.png")!, resolves: { _ in false }))
    #expect(!PRMedia.allowsRedirect(to: URL(string: "http://example.com/a.png")!, resolves: { _ in true }))
    #expect(!PRMedia.allowsRedirect(to: URL(string: "https://example.com/a.pdf")!, resolves: { _ in true }))
    #expect(!PRMedia.allowsRedirect(to: URL(string: "https://127.0.0.1/a.png")!, resolves: { _ in true }))
  }
}

// MARK: - The PR text gh returns

@Suite struct PRBodiesTests {
  // `gh pr view 143 --json body,comments,updatedAt` (trimmed to the fields that matter).
  private let json = """
    {"body":"Fixes the header.\\n\\n![before](https://github.com/user-attachments/assets/aaaa-1111)","comments":[\
    {"author":{"login":"octocat"},"body":"Looks good ![shot](https://example.com/b.png)","createdAt":"2026-11-01T10:00:00Z"},\
    {"author":{"login":"bot"},"body":""},{"author":{"login":"x"},"body":"https://github.com/user-attachments/assets/bbbb-2222"}],\
    "updatedAt":"2026-11-02T09:30:00Z"}
    """

  @Test func theBodyThenEachCommentInOrder() throws {
    let parsed = try ProofPR.parseBodies(Data(json.utf8)).get()
    #expect(parsed.updatedAt == "2026-11-02T09:30:00Z")
    #expect(parsed.texts.count == 3) // the empty comment is dropped
    #expect(parsed.texts[0].hasPrefix("Fixes the header."))
    #expect(parsed.texts[1].contains("example.com/b.png") && parsed.texts[2].contains("bbbb-2222"))
  }

  @Test func aNullBodyIsAnEmptyDescription() throws {
    let parsed = try ProofPR.parseBodies(Data(#"{"body":null,"comments":[],"updatedAt":"t"}"#.utf8)).get()
    #expect(parsed.texts.isEmpty && parsed.updatedAt == "t")
  }

  @Test func aMissingUpdatedAtIsEmptyNotAnError() throws {
    #expect(try ProofPR.parseBodies(Data(#"{"body":"x","comments":[]}"#.utf8)).get().updatedAt == "")
  }

  @Test func notJsonOrNotAnObjectFails() {
    #expect(failureMessage(ProofPR.parseBodies(Data("nope".utf8))) != nil)
    #expect(failureMessage(ProofPR.parseBodies(Data("[1,2]".utf8))) != nil)
  }

  @Test func hugeTextIsBounded() throws {
    let big = String(repeating: "a", count: 500_000)
    let comments = (0..<400).map { _ in #"{"body":"c"}"# }.joined(separator: ",")
    let parsed = try ProofPR.parseBodies(Data(#"{"body":"\#(big)","comments":[\#(comments)],"updatedAt":"t"}"#.utf8)).get()
    #expect(parsed.texts.count <= 101)
    #expect(parsed.texts.allSatisfy { $0.count <= 100_000 })
  }

  @Test func theUpdatedAtOfThePRIsReadFromGhPrView() throws {
    let view = #"{"headRefName":"f","number":3,"state":"OPEN","statusCheckRollup":[],"updatedAt":"2026-11-02T09:30:00Z","url":"https://github.com/o/r/pull/3"}"#
    #expect(try #require(ProofPR.parse(Data(view.utf8))).updatedAt == "2026-11-02T09:30:00Z")
    #expect(ProofPR.fields.contains("updatedAt"))
  }
}
