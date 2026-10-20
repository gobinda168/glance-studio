import Darwin
import Foundation
import Testing
@testable import GlanceCore

@Suite struct SecretRequestPolicyTests {
  let record = SecretRecordTests.record(hosts: ["api.github.com", "*.githubusercontent.com"])

  func url(_ text: String) -> Result<URL, SecretRequestPolicy.Refusal> {
    SecretRequestPolicy.checkURL(text, record: record)
  }

  @Test func httpsToAnAllowedHostPasses() {
    #expect((try? url("https://api.github.com/user").get())?.absoluteString == "https://api.github.com/user")
    #expect((try? url("https://raw.githubusercontent.com/a/b").get()) != nil)
    #expect((try? url("https://api.github.com:443/x?y=1").get()) != nil)
  }

  @Test func otherHostsAreRefusedWithTheAllowedList() {
    #expect(url("https://api.stripe.com/v1") == .failure(.hostNotAllowed(host: "api.stripe.com",
                                                                          allowed: ["api.github.com", "*.githubusercontent.com"])))
    #expect(url("https://api.stripe.com/v1").failureMessage(secret: "GITHUB_TOKEN")
      == "GITHUB_TOKEN isn't allowed for api.stripe.com (allowed: api.github.com, *.githubusercontent.com).")
  }

  @Test func userInfoAndOddHostsAreRefused() {
    #expect(url("http://api.github.com/user") == .failure(.notHTTPS))
    #expect(url("https://api.github.com@evil.com/") == .failure(.userInfo))
    #expect(url("https://user:pw@api.github.com/") == .failure(.userInfo))
    #expect(url("https://127.0.0.1/") == .failure(.refusedHost("127.0.0.1")))
    #expect(url("https://[::1]/") == .failure(.refusedHost("[::1]")))
    #expect(url("https://localhost:3000/") == .failure(.refusedHost("localhost")))
    #expect(url("https://bücher.de/") == .failure(.badURL))
    #expect(url("not a url") == .failure(.badURL))
  }

  @Test func disguisedHostsNeverReachAnAllowedHost() {
    // Whatever each of these is, it must not succeed: the only hosts allowed are api.github.com and *.githubusercontent.com.
    let disguised = [
      "https://@api.github.com/", "https://:@api.github.com/", "https://api.github.com:@evil.com/",
      "https://evil.com\\@api.github.com/", "https://api.github.com\\@evil.com/",
      "https://evil.com#@api.github.com/", "https://evil.com?@api.github.com/",
      "https://api.github.com%2f@evil.com/", "https://api.github.com%40evil.com/",
      "https://evil.com%23.api.github.com/", "https://api.github.com.evil.com/", "https://evil.com/.githubusercontent.com",
      "https://githubusercontent.com/", "https://evilgithubusercontent.com/", "https://*.githubusercontent.com/",
      "https://api.github.com\n@evil.com/", "https://api.github.com\r\n.evil.com/", "https://api.github.com\t/",
      "https://api.github.com /", " https://api.github.com/", "https://api.github.com/\n", "https://api.github.com/\u{0}",
      "https://api.github.com\u{212A}.evil.com/", "https://api.github.com\u{FF0E}evil.com/",
      "https://2130706433/", "https://0x7f.0.0.1/", "https://127.1/", "https://[::ffff:127.0.0.1]/",
      "https:api.github.com", "https:/api.github.com/", "https:///api.github.com/", "//api.github.com/", "api.github.com",
      "javascript:alert(1)", "file:///etc/passwd", "ftp://api.github.com/", "HTTP://api.github.com/",
      "https://api.github.com:99999999/", "https://api.github.com:abc/", "",
    ]
    for text in disguised {
      #expect((try? url(text).get()) == nil, "\(text.debugDescription)")
    }
  }

  @Test func theReturnedURLGoesToTheCheckedHost() throws {
    for text in ["https://API.GitHub.com/x", "HTTPS://api.github.com./x", "https://api.github.com:8443/x#frag",
                 "https://api.github.com?q=1", "https://a.b.githubusercontent.com/%2e%2e/x"] {
      let ok = try url(text).get()
      #expect(ok.scheme?.lowercased() == "https", "\(text)")
      let host = ok.host(percentEncoded: true)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      #expect(host == "api.github.com" || host?.hasSuffix(".githubusercontent.com") == true, "\(text)")
      #expect(ok.user == nil && ok.password == nil, "\(text)")
    }
  }

  @Test func claudeCantSetTheSlotOrAuthHeaders() {
    #expect(SecretRequestPolicy.checkHeaders(["Accept": "application/json"], record: record) == nil)
    #expect(SecretRequestPolicy.checkHeaders(["authorization": "x"], record: record) == .headerNotAllowed("authorization"))
    #expect(SecretRequestPolicy.checkHeaders(["Proxy-Authorization": "x"], record: record)
      == .headerNotAllowed("Proxy-Authorization"))
    let keyed = SecretRecordTests.record(slot: .header(name: "X-API-Key", prefix: ""))
    #expect(SecretRequestPolicy.checkHeaders(["x-api-key": "x"], record: keyed) == .headerNotAllowed("x-api-key"))
    #expect(SecretRequestPolicy.checkHeaders(["Host": "evil.com"], record: record) == .headerNotAllowed("Host"))
    #expect(SecretRequestPolicy.checkHeaders(["X-A": "1\r\nAuthorization: x"], record: record) == .badHeader("X-A"))
    #expect(SecretRequestPolicy.checkHeaders(["X A": "1"], record: record) == .badHeader("X A"))
  }

  @Test func headerEdgeCasesAreRefused() {
    let keyed = SecretRecordTests.record(slot: .header(name: "X-API-Key", prefix: ""))
    #expect(SecretRequestPolicy.checkHeaders(["X-API-KEY": "x"], record: keyed) == .headerNotAllowed("X-API-KEY"))
    // The slot's own header stays Claude's to set when the slot is another header (Authorization is still reserved).
    #expect(SecretRequestPolicy.checkHeaders(["Authorization": "x"], record: keyed) == .headerNotAllowed("Authorization"))
    #expect(SecretRequestPolicy.checkHeaders(["Accept": "x"], record: keyed) == nil)
    for name in ["Content-Length", "Transfer-Encoding", "Connection"] {
      #expect(SecretRequestPolicy.checkHeaders([name: "x"], record: record) == .headerNotAllowed(name))
    }
    for name in ["Authorization ", " Authorization", "Authorization:", "Authori\u{200B}zation", "Authorizatioñ", ""] {
      #expect(SecretRequestPolicy.checkHeaders([name: "x"], record: record) != nil, "\(name.debugDescription)")
    }
    for value in ["a\nb", "a\rb", "a\r\nb", "a\u{0}b", "a\u{85}b", "a\u{2028}b", "a\u{7F}b"] {
      #expect(SecretRequestPolicy.checkHeaders(["X-A": value], record: record) == .badHeader("X-A"), "\(value.debugDescription)")
    }
    #expect(SecretRequestPolicy.checkHeaders(["X-A": "a\tb"], record: record) == nil)
    // Several headers: the offending one is named, whatever the order.
    #expect(SecretRequestPolicy.checkHeaders(["Accept": "x", "Authorization": "y", "X-B": "z"], record: record)
      == .headerNotAllowed("Authorization"))
  }

  // An echo endpoint answering compressed (zstd), in pieces (Range) or re-encoded would carry the header past the
  // scrubber, so Claude can't ask for any of that.
  @Test func encodingAndRangeHeadersAreGlances() {
    for name in ["Accept-Encoding", "accept-encoding", "Range", "If-Range", "TE", "te", "Accept-Charset"] {
      #expect(SecretRequestPolicy.checkHeaders([name: "x"], record: record) == .encodingHeader(name), "\(name)")
    }
    let message = SecretRequestPolicy.Refusal.encodingHeader("Accept-Encoding").message(secret: "GITHUB_TOKEN")
    #expect(message.contains("Accept-Encoding") && message.contains("GITHUB_TOKEN"))
    #expect(SecretRequestPolicy.checkHeaders(["Content-Encoding": "gzip", "Accept": "x"], record: record) == nil)
  }

  // CFNetwork decodes by the first token only, so a list could leave a layer of compression the scrubber can't read.
  @Test func onlyOneReadableContentEncodingIsReadable() {
    for header in [nil, "", "identity", "gzip", "GZIP", " gzip ", "x-gzip", "deflate", "br"] {
      #expect(SecretRequestPolicy.unreadableEncoding(header) == nil, "\(header ?? "nil")")
    }
    for header in ["zstd", "gzip, br", "identity, gzip", ", gzip", "gzip, gzip", "gzip,", "compress", "x-custom",
                   "\u{A0}gzip", "gzip\u{3000}", "gzip\u{2003}", "gzïp"] {
      #expect(SecretRequestPolicy.unreadableEncoding(header) == header, "\(header)")
    }
  }

  @Test func onlyCheckableCharsetsAreReadable() {
    for type in [nil, "application/json", "text/html; charset=UTF-8", "text/plain;charset=\"iso-8859-15\"",
                 "text/plain; charset=windows-1252", "text/plain; charset=utf-16le", "text/plain; Charset=US-ASCII",
                 "text/plain; charset=utf-16", "text/plain; charset=UTF-16BE", "text/plain; charset=iso-8859-1",
                 "text/plain;\tcharset=utf-8 ", "text/plain;;charset=utf-8"] {
      #expect(SecretRequestPolicy.unreadableCharset(type) == nil, "\(type ?? "nil")")
    }
    for (type, charset) in [("text/plain; charset=utf-7", "utf-7"), ("text/plain; charset=\"UTF-32\"", "UTF-32"),
                            ("text/plain; charset=", ""), ("text/plain; charset=utf-8; charset=ebcdic-cp-us", "ebcdic-cp-us"),
                            ("text/plain; charset=iso-8859-17", "iso-8859-17"), ("text/plain; charset=windows-1259", "windows-1259"),
                            (";charset=utf-7", "utf-7"), ("charset=utf-7", "utf-7"),
                            ("text/plain, charset=utf-7", "text/plain, charset=utf-7"),
                            ("text/plain;\u{A0}charset=utf-7", "text/plain;\u{A0}charset=utf-7"),
                            ("text/plain; charset=\u{A0}utf-8", "text/plain; charset=\u{A0}utf-8")] {
      #expect(SecretRequestPolicy.unreadableCharset(type) == charset, "\(type)")
    }
  }

  @Test func acceptCantNameACharset() {
    #expect(SecretRequestPolicy.checkHeaders(["Accept": "text/plain; charset=utf-7"], record: record) == .acceptCharset)
    #expect(SecretRequestPolicy.checkHeaders(["accept": "text/plain;CHARSET=utf-32"], record: record) == .acceptCharset)
    #expect(SecretRequestPolicy.checkHeaders(["Accept": "application/json"], record: record) == nil)
    #expect(SecretRequestPolicy.Refusal.acceptCharset.message(secret: "GITHUB_TOKEN").contains("GITHUB_TOKEN"))
  }

  @Test func onlyHTTPSRedirectsToAllowedHostsAreFollowed() {
    #expect(SecretRequestPolicy.mayFollow(redirectTo: URL(string: "https://api.github.com/other")!, record: record))
    #expect(SecretRequestPolicy.mayFollow(redirectTo: URL(string: "https://x.githubusercontent.com/f")!, record: record))
    #expect(!SecretRequestPolicy.mayFollow(redirectTo: URL(string: "http://api.github.com/other")!, record: record))
    #expect(!SecretRequestPolicy.mayFollow(redirectTo: URL(string: "https://evil.com/")!, record: record))
    #expect(!SecretRequestPolicy.mayFollow(redirectTo: URL(string: "https://a@api.github.com/")!, record: record))
    #expect(!SecretRequestPolicy.mayFollow(redirectTo: URL(string: "https://127.0.0.1/")!, record: record))
    #expect(!SecretRequestPolicy.mayFollow(redirectTo: URL(string: "file:///etc/passwd")!, record: record))
    #expect(!SecretRequestPolicy.mayFollow(redirectTo: URL(string: "https://api.github.com.evil.com/")!, record: record))
    #expect(!SecretRequestPolicy.mayFollow(redirectTo: URL(string: "/relative")!, record: record))
  }

  @Test func malformedHostsAreBadURLsNotPrivateAddresses() {
    for text in ["https://exa_mple.com/", "https://api.github.com%2eevil.com/", "https://a..b/", "https://exa%6dple.com/"] {
      #expect(url(text) == .failure(.badURL), "\(text)")
    }
    #expect(url("https://10.0.0.1/") == .failure(.refusedHost("10.0.0.1")))
    #expect(url("https://printer.local/") == .failure(.refusedHost("printer.local")))
  }

  @Test func echoedTextIsEscapedAndShort() {
    let hostile = "evil\r\nAuthorization: x\u{85}" + String(repeating: "a", count: 500)
    for refusal in [SecretRequestPolicy.Refusal.pathOutsideFolder(hostile), .badHeader(hostile), .headerNotAllowed(hostile)] {
      let message = refusal.message(secret: "GITHUB_TOKEN")
      #expect(!message.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }, "\(message)")
      #expect(message.contains("evil\\u{D}\\u{A}Authorization: x\\u{85}"))
      #expect(message.count < 330)
    }
  }

  @Test func methodsAreTheSixVerbs() {
    #expect(SecretRequestPolicy.methods == ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"])
  }

  @Test func refusalsNameTheSecretAndNeverAValue() {
    let all: [SecretRequestPolicy.Refusal] = [.badURL, .notHTTPS, .userInfo, .refusedHost("localhost"),
      .hostNotAllowed(host: "x.com", allowed: ["a.com"]), .headerNotAllowed("Host"), .badHeader("X"),
      .pathOutsideFolder("../x"), .noFolder]
    for refusal in all { #expect(!refusal.message(secret: "GITHUB_TOKEN").isEmpty) }
    #expect(SecretRequestPolicy.Refusal.notHTTPS.message(secret: "GITHUB_TOKEN") == "GITHUB_TOKEN is only sent over https://.")
  }

  @Test func pathsMustStayInsideTheFolder() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("secrets-policy-\(UUID().uuidString)")
    let folder = base.appendingPathComponent("acme")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: base.appendingPathComponent("acme-evil"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("out"), withDestinationURL: base)
    defer { try? FileManager.default.removeItem(at: base) }

    #expect((try? SecretRequestPolicy.path("out.json", inside: folder.path).get())?.path
      == URL(fileURLWithPath: realFolder(folder)).appendingPathComponent("out.json").path)
    #expect((try? SecretRequestPolicy.path(folder.appendingPathComponent("a.json").path, inside: folder.path).get()) != nil)
    for bad in ["../x", base.appendingPathComponent("acme-evil/x").path, "/etc/x", "out/x", "out"] {
      #expect(SecretRequestPolicy.path(bad, inside: folder.path) == .failure(.pathOutsideFolder(bad)), "\(bad)")
    }
    #expect(SecretRequestPolicy.path("a.json", inside: nil) == .failure(.noFolder))
  }

  @Test func siblingFoldersWithTheSamePrefixAreOutside() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("secrets-policy-\(UUID().uuidString)")
    let folder = base.appendingPathComponent("acme")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: base.appendingPathComponent("acme-evil"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    // "<base>/acme-evil/x" starts with "<base>/acme" as text; only a whole-component comparison refuses it.
    let sibling = base.appendingPathComponent("acme-evil/x").path
    #expect(SecretRequestPolicy.path(sibling, inside: folder.path) == .failure(.pathOutsideFolder(sibling)))
    #expect(SecretRequestPolicy.path("../acme-evil/x", inside: folder.path) == .failure(.pathOutsideFolder("../acme-evil/x")))
    let resolved = URL(fileURLWithPath: realFolder(folder)).path
    #expect(SecretRequestPolicy.path(resolved + "-evil/x", inside: folder.path)
      == .failure(.pathOutsideFolder(resolved + "-evil/x")))
  }

  @Test func odditiesInPathsAreRefused() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("secrets-policy-\(UUID().uuidString)")
    let folder = base.appendingPathComponent("acme")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("out"), withDestinationURL: base)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("gone"),
                                               withDestinationURL: base.appendingPathComponent("missing-dir"))
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("loopA"),
                                               withDestinationURL: folder.appendingPathComponent("loopB"))
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("loopB"),
                                               withDestinationURL: folder.appendingPathComponent("loopA"))
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("dangling"),
                                               withDestinationURL: base.appendingPathComponent("nowhere"))
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("sub/up"), withDestinationURL: base)
    defer { try? FileManager.default.removeItem(at: base) }

    for bad in ["", ".", "./", "sub/..", "sub/", "sub/../..", "sub/../../x", "sub/../a.json", "sub/up/x", "out/../x", "dangling",
                "out/new/x", "out/new/deeper/x", "gone/x", "gone/new/x", "loopA/x", "loopA/new/x", "nonexistent/x",
                "a\u{0}b", "x\n", folder.path, folder.path + "/", folder.path + "/../x", "/", "~/../x"] {
      let result = SecretRequestPolicy.path(bad, inside: folder.path)
      #expect(result == .failure(.pathOutsideFolder(bad)), "\(bad.debugDescription)")
    }
    for good in ["sub/a.json", "./a.json", "sub//a.json", "sub/deeper/a.json"] {
      let target = try SecretRequestPolicy.path(good, inside: folder.path).get()
      #expect(target.path.hasPrefix(URL(fileURLWithPath: realFolder(folder)).path + "/"), "\(good)")
      #expect(!target.pathComponents.contains(".."), "\(good)")
    }
    // Nothing was created by the refused paths.
    #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("new").path))
    // The folder itself must be an absolute path.
    #expect(SecretRequestPolicy.path("a.json", inside: "relative/folder") == .failure(.noFolder))
    #expect(SecretRequestPolicy.path("a.json", inside: "") == .failure(.noFolder))
    #expect(SecretRequestPolicy.path("a.json", inside: base.appendingPathComponent("missing").path) == .failure(.noFolder))
  }
}

/// The folder as the kernel names it (/private/var/…), which is what the policy returns paths under.
func realFolder(_ url: URL) -> String {
  guard let resolved = realpath(url.path, nil) else { return url.path }
  defer { free(resolved) }
  return String(cString: resolved)
}

extension Result where Failure == SecretRequestPolicy.Refusal {
  func failureMessage(secret: String) -> String? {
    if case .failure(let refusal) = self { return refusal.message(secret: secret) }
    return nil
  }
}
