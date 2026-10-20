import Foundation

/// One line of a Browser tab's console or network log (spec 2026-10-12-web-logs-design.md). Studio writes them as
/// JSON lines while the page runs; `glance browser` and Claude Code read them back. A network request is written
/// when it starts and again when it ends: the last line with an `id` is its current state.
public struct WebLogEntry: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case console, network, navigation }

  public var id: Int
  public var kind: Kind
  /// Seconds since 1970.
  public var time: Double
  /// console: log, info, warn, error or debug.
  public var level: String?
  /// console: the message. navigation: the address the page moved to.
  public var text: String?
  public var method: String?
  public var url: String?
  /// network: nil while the request is running; 0 when it never got an answer.
  public var status: Int?
  public var statusText: String?
  public var durationMs: Int?
  public var failed: Bool?
  public var error: String?
  public var requestHeaders: [String: String]?
  public var requestBody: String?
  public var responseHeaders: [String: String]?
  public var responseBody: String?
  public var contentType: String?
  /// How the page made the request: fetch, xhr or document.
  public var via: String?

  public init(id: Int, kind: Kind, time: Double) {
    self.id = id
    self.kind = kind
    self.time = time
  }

  public var isPending: Bool { kind == .network && status == nil && failed != true }

  /// A request that failed, or that the server answered with 400 or more.
  public var isFailedRequest: Bool {
    guard kind == .network else { return false }
    return failed == true || (status ?? 0) >= 400
  }
}

/// A tab in `tabs.json`, beside the log files.
public struct WebLogTab: Codable, Equatable, Sendable {
  /// The Browser tab's key (`tab:3`, `app:…`).
  public var key: String
  public var title: String
  public var url: String
  public var file: String
  /// When the tab last came to the front, seconds since 1970: the tab a bare `glance browser console` reads.
  public var focused: Double

  public init(key: String, title: String, url: String, file: String, focused: Double) {
    self.key = key
    self.title = title
    self.url = url
    self.file = file
    self.focused = focused
  }
}

public enum WebLogFiles {
  public static let indexName = "tabs.json"

  /// ~/Library/Application Support/Glance Studio/Browser/logs; `home` is for tests.
  public static func folder(home: String = NSHomeDirectory()) -> URL {
    URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Glance Studio/Browser/logs",
                                                       isDirectory: true)
  }

  /// The log file's name for a tab key: `tab:3` → `tab-3.jsonl`.
  public static func fileName(forTab key: String) -> String {
    let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "-" }.joined()
    return safe + ".jsonl"
  }

  public static func readIndex(in folder: URL) -> [WebLogTab] {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent(indexName)) else { return [] }
    return (try? JSONDecoder().decode([WebLogTab].self, from: data)) ?? []
  }

  public static func writeIndex(_ tabs: [WebLogTab], in folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(tabs) else { return }
    try? data.write(to: folder.appendingPathComponent(indexName), options: .atomic)
  }

  /// Removes every log: Studio does this once per launch, so no page's data outlives the session that saw it.
  public static func purge(in folder: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
  }
}

/// Appends entries to one tab's log. A file that passes `limit` bytes moves to `<name>.old` (replacing the older
/// one), so a chatty page keeps its latest few megabytes and nothing grows without end.
public final class WebLogWriter: @unchecked Sendable {
  public static let limit = 4_000_000

  private let file: URL
  private let queue = DispatchQueue(label: "dev.glance.weblog", qos: .utility)
  private var handle: FileHandle?
  private var written = 0

  public init(file: URL) { self.file = file }

  public func append(_ entry: WebLogEntry) {
    guard let encoded = try? JSONEncoder().encode(entry) else { return }
    let line = encoded + Data([0x0A])
    queue.async { self.write(line) }
  }

  /// Deletes the log (a closed tab's).
  public func remove() {
    queue.async {
      try? self.handle?.close()
      self.handle = nil
      try? FileManager.default.removeItem(at: self.file)
      try? FileManager.default.removeItem(at: WebLogReader.older(file: self.file))
    }
  }

  private func write(_ data: Data) {
    if handle == nil {
      try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: file.path) {
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      handle = try? FileHandle(forWritingTo: file)
      if let end = try? handle?.seekToEnd() { written = Int(end) }
    }
    guard let handle else { return }
    if written > Self.limit {
      try? handle.close()
      self.handle = nil
      let old = WebLogReader.older(file: file)
      try? FileManager.default.removeItem(at: old)
      try? FileManager.default.moveItem(at: file, to: old)
      written = 0
      return write(data)
    }
    try? handle.write(contentsOf: data)
    written += data.count
  }
}
