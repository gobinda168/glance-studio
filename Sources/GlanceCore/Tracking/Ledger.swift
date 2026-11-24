import CryptoKit
import Darwin
import Foundation

/// The per-repository files under Application Support/Glance/Ledger (spec §1): `<key>.jsonl` (history),
/// `<key>.state.json` (`TrackState`) and `<key>.lock`, which every hook holds while it reads and writes the others.
public struct Ledger: Sendable {
  public let folder: URL

  public init(folder: URL = Ledger.defaultFolder) {
    self.folder = folder
  }

  public static var defaultFolder: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance/Ledger")
  }

  /// A repository's file name stem: the first 16 hex characters of its common git folder's SHA-256.
  public static func key(repo: String) -> String {
    SHA256.hash(data: Data(repo.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  func file(_ repo: String, _ suffix: String) -> URL {
    folder.appendingPathComponent(Self.key(repo: repo) + "." + suffix)
  }

  /// Runs `body` holding the repository's lock; nil when another process holds it beyond `budget` seconds.
  public func locked<T>(repo: String, budget: TimeInterval = 0.02, _ body: () throws -> T) rethrows -> T? {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fd = open(file(repo, "lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    let deadline = Date().addingTimeInterval(budget)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard Date() < deadline else { return nil }
      usleep(1000)
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }

  public func append(_ records: [LedgerRecord], repo: String) {
    guard !records.isEmpty else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = file(repo, "jsonl").path
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Self.lines(records))
  }

  public func records(repo: String) -> [LedgerRecord] {
    guard let data = FileManager.default.contents(atPath: file(repo, "jsonl").path) else { return [] }
    return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(LedgerRecord.self, from: Data($0)) }
  }

  /// Drops the records older than `cutoff`, keeping the rest in order.
  public func prune(repo: String, before cutoff: Date) {
    let kept = records(repo: repo).filter { $0.t >= cutoff }
    try? Self.lines(kept).write(to: file(repo, "jsonl"), options: .atomic)
  }

  public func state(repo: String) -> TrackState {
    FileManager.default.contents(atPath: file(repo, "state.json").path)
      .flatMap { try? Self.decoder.decode(TrackState.self, from: $0) } ?? TrackState(repo: repo)
  }

  public func save(_ state: TrackState) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let data = try? Self.encoder.encode(state) else { return }
    try? data.write(to: file(state.repo, "state.json"), options: .atomic)
  }

  /// Every repository with tracking state, by common git folder.
  public func repos() -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.lastPathComponent.hasSuffix(".state.json") }
      .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(TrackState.self, from: $0) }?.repo }
      .sorted()
  }

  static func lines(_ records: [LedgerRecord]) -> Data {
    var data = Data()
    for record in records {
      guard let line = try? encoder.encode(record) else { continue }
      data.append(line)
      data.append(0x0A)
    }
    return data
  }

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }()

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
