import CryptoKit
import Darwin
import Foundation

/// Bringing the images and videos a PR shows onto this Mac, for the Assets section. A PR body is written by anyone who
/// can comment, so every rule here assumes a hostile one:
///
/// - Only links `AssetLinks.find` passes are asked for, and a GitHub upload (`AssetLinks.isGitHubAttachment`) is the
///   only thing fetched with `gh`, so the user's GitHub token is never sent to another host. Everything else goes
///   through a plain `URLSession` that has no credentials, no cookies and no cache, and judges each redirect by the
///   same rules as the link itself.
/// - Only `image/*` and `video/*` that have a known file extension are kept, and never `image/svg+xml`.
/// - At most `maxBytes` per file, counted while reading; a file that ends early, or was cut, is not kept.
/// - Whatever fails leaves no file behind.
///
/// Everything blocks: call off the main thread.
public enum PRMedia {
  /// The most one file may be.
  public static let maxBytes: Int64 = 50 << 20
  /// The most media one PR brings in.
  public static let maxItems = 20

  public typealias Downloaded = (contentType: String, bytes: Int64)
  /// Fetches `url` into the file `to` (whole, or not at all), at most `limit` bytes. `GitHubCLI.download` is one; the plain
  /// web fetch below is the other.
  public typealias Downloader = @Sendable (_ url: URL, _ to: URL, _ limit: Int64) -> Result<Downloaded, ProofPR.Failure>

  // MARK: - The routing

  /// `url` into `destination`. A GitHub upload goes through `gh` and only through `gh`; any other address goes through the
  /// plain web fetch and never `gh`, which would send the user's token along.
  public static func download(url: URL, to destination: URL, limit: Int64,
                              gh: Downloader = { GitHubCLI.download(url: $0, to: $1, limit: $2) },
                              web: Downloader = { fetchPublic(url: $0, to: $1, limit: $2) }) -> Result<Downloaded, ProofPR.Failure> {
    AssetLinks.isGitHubAttachment(url) ? gh(url, destination, limit) : web(url, destination, limit)
  }

  // MARK: - What counts as media

  public struct MediaType: Equatable, Sendable {
    public let ext: String
    public let kind: AssetItem.Kind
  }

  private static let types: [String: MediaType] = [
    "image/png": MediaType(ext: "png", kind: .image), "image/jpeg": MediaType(ext: "jpg", kind: .image),
    "image/gif": MediaType(ext: "gif", kind: .image), "image/webp": MediaType(ext: "webp", kind: .image),
    "image/avif": MediaType(ext: "avif", kind: .image), "image/heic": MediaType(ext: "heic", kind: .image),
    "video/mp4": MediaType(ext: "mp4", kind: .video), "video/quicktime": MediaType(ext: "mov", kind: .video),
    "video/webm": MediaType(ext: "webm", kind: .video), "video/x-m4v": MediaType(ext: "m4v", kind: .video),
  ]
  private static let extensions = ["png", "jpg", "gif", "webp", "avif", "heic", "mp4", "mov", "webm", "m4v"]

  /// What a `Content-Type` allows to be kept: an image or video with a known extension. `image/svg+xml` (a document that
  /// can carry script and references), every other type and anything odd is nil.
  public static func mediaType(contentType: String) -> MediaType? {
    let essence = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    return types[essence]
  }

  // MARK: - The `gh api -i` header block

  public struct Headers: Equatable, Sendable {
    public var status: Int
    public var contentType: String?
    /// Nil when absent, negative, not a number or too big to be one.
    public var contentLength: Int64?
  }

  public enum HeaderParse: Equatable, Sendable {
    /// The header block isn't complete yet.
    case needMore
    /// Not an HTTP response, or a header block that is far too long.
    case malformed
    /// The final response's headers, and where its body starts in the data.
    case headers(Headers, bodyStart: Int)
  }

  /// The header block at the start of `gh api -i`'s output: the status line and headers of the final response, a blank
  /// line, then the body. (gh follows redirects, so the block of a redirect is not printed; one that is has a 3xx status
  /// and the caller refuses it.) A `100 Continue` block in front is skipped.
  public static func parseHeaders(_ data: Data) -> HeaderParse {
    let limit = 16 * 1024
    let bytes = Array(data.prefix(limit + 4))
    let signature = Array("HTTP/".utf8)
    var offset = 0
    while true {
      let remaining = bytes.count - offset
      let compared = min(remaining, signature.count)
      guard Array(bytes[offset..<(offset + compared)]) == Array(signature[0..<compared]) else { return .malformed }
      guard let end = blockEnd(in: bytes, from: offset) else { return bytes.count > limit ? .malformed : .needMore }
      let block = String(decoding: bytes[offset..<end.lineEnd], as: UTF8.self)
      let lines = block.split(whereSeparator: \.isNewline).map(String.init)
      guard let statusLine = lines.first else { return .malformed }
      let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
      guard parts.count >= 2, parts[1].count == 3, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let status = Int(parts[1]),
            status >= 100 else { return .malformed }
      if status < 200 { offset = end.next; continue }
      var headers = Headers(status: status, contentType: nil, contentLength: nil)
      for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if name == "content-type", headers.contentType == nil { headers.contentType = value }
        if name == "content-length", headers.contentLength == nil, !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) {
          headers.contentLength = Int64(value)
        }
      }
      return .headers(headers, bodyStart: end.next)
    }
  }

  /// The first blank line at or after `from`: where the headers end (`lineEnd`) and the body begins (`next`).
  private static func blockEnd(in bytes: [UInt8], from: Int) -> (lineEnd: Int, next: Int)? {
    var i = from
    while i < bytes.count {
      if bytes[i] == 10 {
        if i + 1 < bytes.count, bytes[i + 1] == 10 { return (i + 1, i + 2) }
        if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { return (i + 1, i + 3) }
      }
      i += 1
    }
    return nil
  }

  // MARK: - Where a download lives

  /// The file name for `url` in the cache: the hash of the address, so the same picture is one file and a name chosen by
  /// the PR can never be a path.
  public static func cacheName(_ url: URL) -> String {
    SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// The file already fetched for `url` in `folder` (`<hash>.<ext>`), nil when there is none.
  public static func cachedFile(for url: URL, in folder: URL) -> URL? {
    let name = cacheName(url)
    for ext in extensions {
      let file = folder.appendingPathComponent(name + "." + ext)
      if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
         values.isRegularFile == true, values.isSymbolicLink != true { return file }
    }
    return nil
  }

  public struct Fetched: Equatable, Sendable {
    public let file: URL
    public let kind: AssetItem.Kind
    public let contentType: String
    public let bytes: Int64
  }

  /// Fetches `url` into `folder` as `<hash>.<extension from the content type>` with `download`. Nothing but a whole, media
  /// file within `limit` stays: a temporary file is made and then renamed, and removed on any failure.
  public static func fetch(url: URL, into folder: URL, limit: Int64, download: Downloader) -> Result<Fetched, ProofPR.Failure> {
    do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
      return .failure(ProofPR.Failure("Couldn't make the media folder."))
    }
    let name = cacheName(url)
    let partial = folder.appendingPathComponent(".\(name).\(UUID().uuidString.prefix(8)).part")
    defer { try? FileManager.default.removeItem(at: partial) }
    let done: Downloaded
    switch download(url, partial, limit) {
    case .failure(let failure): return .failure(failure)
    case .success(let value): done = value
    }
    guard let type = mediaType(contentType: done.contentType) else {
      return .failure(ProofPR.Failure("That isn't an image or video (\(done.contentType.prefix(60)))."))
    }
    let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? -1
    guard size >= 0, size <= limit, done.bytes <= limit else { return .failure(ProofPR.Failure("That file is too big.")) }
    let file = folder.appendingPathComponent(name + "." + type.ext)
    do {
      try? FileManager.default.removeItem(at: file)
      try FileManager.default.moveItem(at: partial, to: file)
    } catch {
      return .failure(ProofPR.Failure("Couldn't keep the file."))
    }
    return .success(Fetched(file: file, kind: type.kind, contentType: done.contentType, bytes: size))
  }

  // MARK: - A file being written

  /// A download in progress: bytes go to a temporary file beside `destination` that becomes `destination` on `commit` and
  /// is gone on `discard`. Not thread-safe: one writer.
  final class Sink {
    private(set) var count: Int64 = 0
    private let destination: URL
    private let partial: URL
    private var handle: FileHandle?

    init?(destination: URL) {
      self.destination = destination
      partial = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8)).part")
      guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]),
            let handle = try? FileHandle(forWritingTo: partial) else { return nil }
      self.handle = handle
    }

    /// False when the write failed.
    func write(_ data: Data) -> Bool {
      guard let handle else { return false }
      do { try handle.write(contentsOf: data) } catch { return false }
      count += Int64(data.count)
      return true
    }

    func commit() -> Bool {
      try? handle?.close()
      handle = nil
      do {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return true
      } catch {
        try? FileManager.default.removeItem(at: partial)
        return false
      }
    }

    func discard() {
      try? handle?.close()
      handle = nil
      try? FileManager.default.removeItem(at: partial)
    }
  }

  // MARK: - The plain web

  /// `url` fetched with no GitHub token, no credentials, no cookies and no cache. The address must pass `allowsPublic`
  /// first, and every redirect `allowsRedirect`. `allowsFirst` is the first check, replaceable only so a test can reach a
  /// server on this Mac; redirects are always judged by the real rules.
  public static func fetchPublic(url: URL, to destination: URL, limit: Int64,
                                 allowsFirst: (URL) -> Bool = { allowsPublic($0) }) -> Result<Downloaded, ProofPR.Failure> {
    guard allowsFirst(url) else { return .failure(ProofPR.Failure("That address isn't a public https image.")) }
    guard let sink = Sink(destination: destination) else { return .failure(ProofPR.Failure("Couldn't start the download.")) }
    let fetch = PublicFetch(sink: sink, limit: limit)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 120
    configuration.waitsForConnectivity = false
    configuration.httpAdditionalHeaders = nil
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: fetch, delegateQueue: queue)
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
    request.httpShouldHandleCookies = false
    request.setValue("image/*,video/*", forHTTPHeaderField: "Accept")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let task = session.dataTask(with: request)
    task.resume()
    // The request and resource timeouts end the task; this wait is only a stop for a task that never reports.
    let ended = fetch.finished.wait(timeout: .now() + 150) == .success
    if !ended { fetch.fail("The download took too long."); task.cancel() }
    session.finishTasksAndInvalidate()
    return fetch.result()
  }

  /// A first address the plain fetch will ask: https, a public name, no credentials or odd port, a media extension (or
  /// none), and every address the name resolves to a public one.
  public static func allowsPublic(_ url: URL) -> Bool { allowsRedirect(to: url) }

  /// The rules a link must pass in a PR body (`AssetLinks`), and a name that resolves only to public addresses.
  public static func allowsRedirect(to url: URL, resolves: (String) -> Bool = { resolvesPublicly($0) }) -> Bool {
    guard AssetLinks.allows(url), let host = url.host else { return false }
    return resolves(host)
  }

  /// True when `host` resolves, and only to public addresses. (A name can be changed between this look and the request;
  /// this stops the ordinary case, a name pointed at 127.0.0.1 or the cloud metadata address.)
  public static func resolvesPublicly(_ host: String) -> Bool {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var found: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &found) == 0, let first = found else { return false }
    defer { freeaddrinfo(found) }
    var any = false
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let entry = cursor {
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard let address = entry.pointee.ai_addr,
            getnameinfo(address, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
            isPublicAddress(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) else { return false }
      any = true
      cursor = entry.pointee.ai_next
    }
    return any
  }

  /// A numeric IPv4 or IPv6 address that is on the public internet: not loopback, private, link-local, shared (CGNAT),
  /// multicast or reserved, and not one of those wrapped in an IPv6 form (`::ffff:`, NAT64, 6to4).
  public static func isPublicAddress(_ text: String) -> Bool {
    var v4 = in_addr()
    if inet_pton(AF_INET, text, &v4) == 1 { return publicV4(withUnsafeBytes(of: &v4) { Array($0) }) }
    var v6 = in6_addr()
    guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
    let b = withUnsafeBytes(of: &v6) { Array($0) }
    if b.allSatisfy({ $0 == 0 }) { return false } // ::
    if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return false } // ::1
    if b[0..<12].allSatisfy({ $0 == 0 }) { return false } // ::a.b.c.d
    if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return publicV4(Array(b[12..<16])) } // ::ffff:a.b.c.d
    if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) { return publicV4(Array(b[12..<16])) } // 64:ff9b::/96
    if b[0] == 0x20, b[1] == 0x02 { return publicV4(Array(b[2..<6])) } // 6to4
    if b[0] == 0xfe, b[1] & 0x80 != 0 { return false } // fe80::/10 and the old site-local range
    if b[0] & 0xfe == 0xfc { return false } // fc00::/7
    if b[0] == 0xff { return false } // multicast
    return true
  }

  private static func publicV4(_ b: [UInt8]) -> Bool {
    guard b.count == 4 else { return false }
    switch (b[0], b[1], b[2]) {
    case (0, _, _), (10, _, _), (127, _, _): return false
    case (100, 64...127, _): return false
    case (169, 254, _): return false
    case (172, 16...31, _): return false
    case (192, 168, _), (192, 0, 0): return false
    case (224...255, _, _): return false
    default: return true
    }
  }
}

/// One plain-web download: checks the answer's status, type and length, and every redirect, and counts what is read.
private final class PublicFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let finished = DispatchSemaphore(value: 0)
  private let sink: PRMedia.Sink
  private let limit: Int64
  private let lock = NSLock()
  private var failure: String?
  private var error: Error?
  private var contentType = ""
  private var expected: Int64 = -1
  private var redirects = 0

  init(sink: PRMedia.Sink, limit: Int64) {
    self.sink = sink
    self.limit = limit
  }

  fileprivate func fail(_ message: String) {
    lock.lock(); if failure == nil { failure = message }; lock.unlock()
  }

  private var failed: Bool { lock.lock(); defer { lock.unlock() }; return failure != nil }

  /// The outcome once the task has ended: the file is in place, or gone.
  func result() -> Result<PRMedia.Downloaded, ProofPR.Failure> {
    lock.lock(); let failure = failure, error = error, contentType = contentType, expected = expected; lock.unlock()
    if let failure { sink.discard(); return .failure(ProofPR.Failure(failure)) }
    if let error { sink.discard(); return .failure(ProofPR.Failure(error.localizedDescription)) }
    if expected >= 0, sink.count != expected { sink.discard(); return .failure(ProofPR.Failure("The download ended early.")) }
    let bytes = sink.count
    guard sink.commit() else { return .failure(ProofPR.Failure("Couldn't keep the file.")) }
    return .success((contentType, bytes))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    redirects += 1
    guard redirects <= 5, let next = request.url, PRMedia.allowsRedirect(to: next) else {
      fail("The image redirects somewhere Glance won't go.")
      task.cancel()
      completionHandler(nil)
      return
    }
    var clean = request
    clean.httpShouldHandleCookies = false
    completionHandler(clean)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      fail("The server answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
      return completionHandler(.cancel)
    }
    let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
    guard PRMedia.mediaType(contentType: type) != nil else {
      fail("That isn't an image or video (\(type.prefix(60))).")
      return completionHandler(.cancel)
    }
    if http.expectedContentLength > limit {
      fail("That file is too big.")
      return completionHandler(.cancel)
    }
    lock.lock(); contentType = type; expected = http.expectedContentLength; lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !failed else { return }
    if sink.count + Int64(data.count) > limit {
      fail("That file is too big.")
      dataTask.cancel()
      return
    }
    if !sink.write(data) {
      fail("Couldn't write the file.")
      dataTask.cancel()
    }
  }

  /// No credentials, ever: a server asking for them is refused.
  func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { lock.lock(); self.error = error; lock.unlock() }
    finished.signal()
  }
}
