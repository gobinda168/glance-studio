import Foundation

/// One use of a secret, or a refusal: never the value (spec "Request flow", step 8).
public struct SecretActivity: Codable, Equatable, Sendable {
  public var date: Date
  public var session: String
  public var folder: String?
  public var secret: String
  public var method: String
  public var host: String
  /// Without the query.
  public var path: String
  /// The status code, or why it didn't go: "denied", "refused: …", "failed: …".
  public var outcome: String
  public var bytes: Int

  public init(date: Date, session: String, folder: String?, secret: String, method: String, host: String,
              path: String, outcome: String, bytes: Int) {
    self.date = date
    self.session = session
    self.folder = folder
    self.secret = secret
    self.method = method
    self.host = host
    self.path = path
    self.outcome = outcome
    self.bytes = bytes
  }

  /// The longest any text field is kept. The host, path and outcome come from a request Claude wrote, so a hostile
  /// one could otherwise make the file grow without bound.
  static let fieldLimit = 2_048

  /// The entry as it is stored: the path cut at the first `?` or `#` (the log keeps host + path, never a query, which
  /// could carry a token), and every text field clipped.
  static func withoutQuery(_ path: String) -> String {
    // Unicode scalars, not Characters: "?" followed by a combining mark is one Character that is not "?".
    let scalars = path.unicodeScalars
    guard let cut = scalars.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return path }
    return String(scalars[..<cut])
  }

  func clipped() -> SecretActivity {
    func clip(_ text: String) -> String {
      let scalars = text.unicodeScalars
      guard scalars.count > Self.fieldLimit else { return text }
      return String(String.UnicodeScalarView(scalars.prefix(Self.fieldLimit)))
    }
    return SecretActivity(date: date, session: clip(session), folder: folder.map(clip), secret: clip(secret),
                          method: clip(method), host: clip(host), path: clip(Self.withoutQuery(path)),
                          outcome: clip(outcome), bytes: bytes)
  }
}

/// The activity log: a JSONL file of the newest entries, rewritten to the newest `keep` once it grows 200 past it.
/// The file is owner-only (0600), and each text field is clipped to `SecretActivity.fieldLimit`.
public final class SecretActivityLog: @unchecked Sendable {
  public static let keep = 1_000
  public static let standard = SecretActivityLog(url: FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Glance/secrets-activity.jsonl"))

  let url: URL
  private let lock = NSLock()

  public init(url: URL) { self.url = url }

  public func append(_ activity: SecretActivity) {
    lock.lock()
    defer { lock.unlock() }
    guard let line = try? Self.encoder.encode(activity.clipped()) else { return }
    let manager = FileManager.default
    try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !manager.fileExists(atPath: url.path) {
      manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    // A write error (a full disk) must never crash the app, so only the throwing FileHandle calls are used.
    guard let handle = try? FileHandle(forUpdating: url) else { return }
    do {
      defer { try? handle.close() }
      let end = try handle.seekToEnd()
      var entry = line + Data("\n".utf8)
      if end > 0 {
        // A torn last line (no newline) must not swallow this entry.
        try handle.seek(toOffset: end - 1)
        if try handle.read(upToCount: 1) != Data("\n".utf8) { entry = Data("\n".utf8) + entry }
        try handle.seekToEnd()
      }
      try handle.write(contentsOf: entry)
    } catch {
      return
    }
    let lines = readLines()
    if lines.count > Self.keep + 200 {
      try? (lines.suffix(Self.keep).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
      try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
  }

  /// Newest first.
  public func recent(limit: Int) -> [SecretActivity] {
    lock.lock()
    defer { lock.unlock() }
    return readLines().reversed().prefix(limit).compactMap { try? Self.decoder.decode(SecretActivity.self, from: Data($0.utf8)) }
  }

  private func readLines() -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()
  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
