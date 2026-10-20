import Foundation

public protocol SecretRecordSource: Sendable { func records() -> [SecretRecord] }
extension SecretVault: SecretRecordSource {}

public struct SecretCaller: Equatable, Sendable {
  public var session: Int32
  public var label: String
  /// Verified by Studio from the `claude` process; nil when it couldn't be.
  public var folder: String?
  public init(session: Int32, label: String, folder: String?) {
    self.session = session
    self.label = label
    self.folder = folder
  }
}

public struct SecretApprovalAsk: Equatable, Sendable {
  public var caller: SecretCaller
  public var secretID: UUID
  public var secret: String
  public var approval: SecretApproval
  public var method: String
  public var url: String
  /// The first ~2 KB of a text body.
  public var bodyPreview: String?
  /// The whole body's size in bytes (nil without a body), so the card can say a binary body is there.
  public var bodyBytes: Int?
  /// The record's `updated` as the broker read it: an approval for a secret changed since is void.
  public var updated: Date?

  public init(caller: SecretCaller, secretID: UUID, secret: String, approval: SecretApproval, method: String,
              url: String, bodyPreview: String?, bodyBytes: Int? = nil, updated: Date? = nil) {
    self.caller = caller
    self.secretID = secretID
    self.secret = secret
    self.approval = approval
    self.method = method
    self.url = url
    self.bodyPreview = bodyPreview
    self.bodyBytes = bodyBytes
    self.updated = updated
  }
}

/// What the approver decided about one use.
public enum SecretApprovalDecision: Equatable, Sendable {
  case allow, deny
  /// Not asked: too many approval cards are waiting already.
  case tooManyWaiting
}

public protocol SecretApprover: Sendable {
  /// True when the use is allowed (by a grant, `always`, or the user on the card with Touch ID).
  func approve(_ ask: SecretApprovalAsk) async -> Bool
  /// The decision, when there's more to say than yes or no. By default, `approve`'s answer.
  func decide(_ ask: SecretApprovalAsk) async -> SecretApprovalDecision
}

extension SecretApprover {
  public func decide(_ ask: SecretApprovalAsk) async -> SecretApprovalDecision { await approve(ask) ? .allow : .deny }
}

/// Runs one `http_request` end to end (spec "Request flow"): find, fence, check, approve, send with the header in its
/// slot, scrub, log. The value is read here and in Settings only, and leaves only in the outgoing request.
///
/// Claude is hostile: it writes every argument and has a shell in its folder, so it can race the file system while
/// the request waits for approval (files are opened by descriptor at the moment of use, `SecretFolderFile`) and can
/// pick any URL on an allowed host (echo endpoints are scrubbed; downloads are capped while they stream). Everything
/// that goes back to Claude passes the scrubber; the activity log gets only metadata.
public struct SecretBroker: Sendable {
  public static let inlineLimit = 1_048_576
  public static let saveLimit = 20_971_520
  public static let bodyLimit = 10_485_760

  let source: SecretRecordSource
  let transport: SecretTransport
  let approver: SecretApprover
  let log: SecretActivityLog?

  public init(records: SecretRecordSource, transport: SecretTransport, approver: SecretApprover,
              log: SecretActivityLog?) {
    source = records
    self.transport = transport
    self.approver = approver
    self.log = log
  }

  /// The first 2 KB of a UTF-8 body for the approval card, backing off a character cut at the edge; nil for binary.
  static func preview(_ body: Data) -> String? {
    let head = body.prefix(2_048)
    // Only a cut at the edge backs off: a short body that ends in a broken character is binary, not text.
    for drop in 0...(body.count > head.count ? 3 : 0) {
      if let text = String(data: head.dropLast(drop), encoding: .utf8) { return text }
    }
    return nil
  }

  public func list(caller: SecretCaller) -> JSONValue {
    let usable = source.records().filter { $0.allows(folder: caller.folder) }
    return ["secrets": .array(usable.map { record in
      ["name": .string(record.name), "note": .string(record.note), "hosts": .array(record.hosts.map(JSONValue.string)),
       "sent_as": .string(record.slot.summary), "approval": .string(record.approval.rawValue)]
    })]
  }

  public func request(_ call: SecretHTTPCall, caller: SecretCaller) async -> (value: JSONValue, isError: Bool) {
    let records = source.records()
    let usable = records.filter { $0.allows(folder: caller.folder) }
    // A usable record first, so one of the same name fenced to another folder can't shadow it.
    guard let record = usable.first(where: { $0.name == call.secret })
      ?? records.first(where: { $0.name == call.secret }) else {
      let names = usable.map(\.name)
      return (.string("No secret called \(SecretRequestPolicy.display(call.secret)). Usable here: "
                      + (names.isEmpty ? "none" : names.joined(separator: ", ")) + "."), true)
    }
    let scrubber = SecretScrubber(name: record.name, value: record.value)
    let host = URL(string: call.url)?.host() ?? "?"
    let path = URL(string: call.url)?.path() ?? ""
    func note(_ outcome: String, bytes: Int = 0) {
      log?.append(SecretActivity(date: Date(), session: caller.label, folder: caller.folder, secret: record.name,
                                 method: call.method, host: scrubber.scrub(host), path: scrubber.scrub(path),
                                 outcome: outcome, bytes: bytes))
    }
    func fail(_ outcome: String, _ message: String) -> (value: JSONValue, isError: Bool) {
      note(outcome)
      return (.string(scrubber.scrub(message)), true)
    }
    func refuse(_ refusal: SecretRequestPolicy.Refusal, _ kind: String) -> (value: JSONValue, isError: Bool) {
      fail("refused: \(kind)", refusal.message(secret: record.name))
    }
    func fileFailure(_ failure: SecretFolderFile.Failure, _ path: String, writing: Bool) -> (value: JSONValue, isError: Bool) {
      let shown = SecretRequestPolicy.display(path)
      switch failure {
      case .outside: return refuse(.pathOutsideFolder(path), "file")
      case .notAFile:
        return fail("refused: file", "\(shown) must be a plain file inside this session's project folder (not a folder, link or pipe).")
      case .tooLarge:
        return writing ? fail("refused: size", "The response is over 20 MB.")
          : fail("refused: size", "The request body is over 10 MB.")
      case .failed: return fail("failed: file", writing ? "Couldn't write \(shown)." : "Couldn't read \(shown).")
      }
    }

    guard record.allows(folder: caller.folder) else {
      return fail("refused: folder", "\(record.name) can't be used from this session's folder.")
    }
    // ChannelTools checks this too; the broker is public, so it doesn't rely on that.
    guard SecretRequestPolicy.methods.contains(call.method) else {
      return fail("refused: method", "The method must be one of "
                  + SecretRequestPolicy.methods.sorted().joined(separator: ", ") + ".")
    }
    let url: URL
    switch SecretRequestPolicy.checkURL(call.url, record: record) {
    case .success(let checked): url = checked
    case .failure(let refusal): return refuse(refusal, "host")
    }
    if let refusal = SecretRequestPolicy.checkHeaders(call.headers, record: record) { return refuse(refusal, "header") }

    var body: Data?
    if let text = call.body { body = Data(text.utf8) }
    if let file = call.bodyFile {
      // Read now, by descriptor: what the approval card previews is exactly what is sent.
      switch SecretFolderFile.locate(file, inside: caller.folder) {
      case .failure(let refusal): return refuse(refusal, "file")
      case .success(let located):
        switch located.read(limit: Self.bodyLimit) {
        case .failure(let failure): return fileFailure(failure, file, writing: false)
        case .success(let data): body = data
        }
      }
    }
    if let body, body.count > Self.bodyLimit {
      return fail("refused: size", "The request body is over 10 MB.")
    }
    // Located (and the folder pinned) now; written by descriptor after the response.
    var saveFile: SecretFolderFile?
    if let saveTo = call.saveTo {
      switch SecretFolderFile.locate(saveTo, inside: caller.folder) {
      case .failure(let refusal): return refuse(refusal, "file")
      case .success(let located): saveFile = located
      }
    }

    let preview = body.flatMap(Self.preview)
    let ask = SecretApprovalAsk(caller: caller, secretID: record.id, secret: record.name, approval: record.approval,
                                method: call.method, url: url.absoluteString, bodyPreview: preview,
                                bodyBytes: body?.count, updated: record.updated)
    switch await approver.decide(ask) {
    case .allow: break
    case .deny: return fail("denied", "The user denied this use of \(record.name).")
    case .tooManyWaiting:
      return fail("refused: too many waiting", "Too many requests are waiting for you; try again in a moment.")
    }

    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = call.method
    for (name, value) in call.headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = body
    let slot = record.slot.header(value: record.value)
    request.setValue(slot.value, forHTTPHeaderField: slot.name)

    let tooLarge = saveFile == nil ? "The response is binary or over 1 MB: call again with save_to."
      : "The response is over 20 MB."
    let maxBytes = saveFile == nil ? Self.inlineLimit : Self.saveLimit
    let response: HTTPURLResponse
    let data: Data
    do {
      (response, data) = try await transport.send(request, maxBytes: maxBytes) {
        SecretRequestPolicy.mayFollow(redirectTo: $0, record: record)
      }
    } catch SecretTransportError.tooLarge {
      return fail("refused: size", tooLarge)
    } catch {
      return fail("failed", "The request failed: \(error.localizedDescription)")
    }
    // Held to the cap even when a transport doesn't honour it.
    guard data.count <= maxBytes else { return fail("refused: size", tooLarge) }

    // A body URLSession didn't decode (zstd, say) would carry an echo of the header past the scrubber.
    if let encoding = SecretRequestPolicy.unreadableEncoding(response.value(forHTTPHeaderField: "Content-Encoding")) {
      return fail("refused: encoding", "The response came back in an encoding Glance can't check ("
                  + SecretRequestPolicy.display(encoding) + ").")
    }
    // A body in a character set the scrubber doesn't know (UTF-7, UTF-32) would too.
    if let charset = SecretRequestPolicy.unreadableCharset(response.value(forHTTPHeaderField: "Content-Type")) {
      return fail("refused: charset", "The response came back in a character set Glance can't check ("
                  + SecretRequestPolicy.display(charset) + ").")
    }

    let scrubbed = scrubber.scrub(data)
    var headers: [String: JSONValue] = [:]
    for (name, value) in response.allHeaderFields {
      headers[scrubber.scrub((name.base as? String) ?? "\(name)")] = .string(scrubber.scrub("\(value)"))
    }
    var result: [String: JSONValue] = ["status": .number(Double(response.statusCode)), "headers": .object(headers)]
    if let saveFile, let saveTo = call.saveTo {
      guard scrubbed.count <= Self.saveLimit else { return fail("refused: size", tooLarge) }
      if let failure = saveFile.write(scrubbed) { return fileFailure(failure, saveTo, writing: true) }
      result["saved_to"] = .string(scrubber.scrub(saveFile.url.path))
      result["bytes"] = .number(Double(scrubbed.count))
    } else {
      guard scrubbed.count <= Self.inlineLimit, let text = String(data: scrubbed, encoding: .utf8) else {
        note("refused: size", bytes: data.count)
        return (.string(tooLarge), true)
      }
      result["body"] = .string(text)
    }
    note("\(response.statusCode)", bytes: data.count)
    return (.object(result), false)
  }
}
