import CryptoKit
import Darwin
import Foundation

/// Proof records on disk (spec §1 "Storage"): `<folder>/<session>/record.json` and `media/`, outside any repo. Writers
/// are the `glance` CLI (hooks, the MCP shim), each under the record's flock; the file is replaced atomically, so a
/// reader never sees half a record.
public struct WorkStore: Sendable {
  public static var defaultFolder: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance/Work", isDirectory: true)
  }
  public static let keepDays = 60

  public let folder: URL
  public init(folder: URL = WorkStore.defaultFolder) { self.folder = folder }

  /// Claude's session ids are UUIDs; anything that could leave the folder is refused.
  public static func isSessionID(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 64 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
  }

  public func sessionFolder(_ session: String) -> URL { folder.appendingPathComponent(session, isDirectory: true) }
  public func mediaFolder(session: String) -> URL { sessionFolder(session).appendingPathComponent("media", isDirectory: true) }
  /// Where Studio keeps what it fetched for a session (the PR's images and videos): apart from `media`, which holds
  /// only what the hooks and proof tools captured.
  public func cacheFolder(session: String) -> URL { sessionFolder(session).appendingPathComponent("cache", isDirectory: true) }
  private func file(_ session: String) -> URL { sessionFolder(session).appendingPathComponent("record.json") }

  /// When the session's record or summary was last written, whichever is later: two `stat`s, no decoding, for
  /// `RecordFreshness`. `RecordFreshness.none` when neither exists or the id is unsafe.
  public func stamp(session: String, summaries: URL = SessionName.summaries) -> Date {
    guard Self.isSessionID(session) else { return RecordFreshness.none }
    func modified(_ url: URL) -> Date {
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? RecordFreshness.none
    }
    return max(modified(file(session)), modified(summaries.appendingPathComponent(session + ".json")))
  }

  public func record(session: String) -> WorkRecord? {
    guard Self.isSessionID(session), let data = try? Data(contentsOf: file(session)) else { return nil }
    return try? WorkRecord.decoder.decode(WorkRecord.self, from: data)
  }

  /// Reads, changes and writes the record under its lock. Nil when the id is unsafe, the lock wasn't free within
  /// `budget` seconds, or the write failed. Keeps only the latest `WorkRecord.runsKept` runs per check x environment.
  @discardableResult
  public func update(session: String, now: Date = Date(), budget: TimeInterval = 0.5,
                     _ change: (inout WorkRecord) -> Void) -> WorkRecord? {
    guard Self.isSessionID(session) else { return nil }
    guard let written = locked(session: session, budget: budget, { (dir: URL) -> WorkRecord? in
      var record = self.record(session: session) ?? WorkRecord(session: session, updated: now)
      change(&record)
      record.updated = now
      record.trimChecks()
      guard let data = try? WorkRecord.encoder.encode(record),
            (try? data.write(to: file(session), options: .atomic)) != nil else { return nil }
      // The folder's time is what `prune` reads, so a hook never has to decode a record to age it.
      try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dir.path)
      return record
    }) else { return nil }
    prune(now: now)
    return written
  }

  private func locked<T>(session: String, budget: TimeInterval, _ body: (URL) -> T?) -> T? {
    let dir = sessionFolder(session)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.appendingPathComponent("record.lock").path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    let deadline = Date().addingTimeInterval(budget)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      if Date() > deadline { return nil }
      usleep(1_000)
    }
    defer { flock(fd, LOCK_UN) }
    return body(dir)
  }

  public func records() -> [WorkRecord] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter(Self.isSessionID).compactMap { record(session: $0) }
  }

  /// Removes sessions whose folder was last changed more than 60 days ago; runs at most once a day (a `.pruned`
  /// stamp) unless forced. It runs inside hooks, so it reads folder times only and never decodes a record.
  public func prune(now: Date, force: Bool = false) {
    let fm = FileManager.default
    let stamp = folder.appendingPathComponent(".pruned")
    if !force, let date = (try? fm.attributesOfItem(atPath: stamp.path))?[.modificationDate] as? Date,
       now.timeIntervalSince(date) < 86_400 { return }
    fm.createFile(atPath: stamp.path, contents: nil)
    try? fm.setAttributes([.modificationDate: now], ofItemAtPath: stamp.path)
    let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
    let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for url in entries where Self.isSessionID(url.lastPathComponent) {
      guard let changed = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            changed < cutoff else { continue }
      try? fm.removeItem(at: url)
    }
  }
}

extension WorkStore {
  /// Bytes of what Clear old media can free and what a half-written clip holds: every session's `media/` and `cache/`,
  /// and `.tmp-clips`. Records are a few KB and stay out of it. Walks the folder, so call it off the main thread.
  public func mediaSize() -> Int64 {
    let fm = FileManager.default
    var total = Self.bytes(in: folder.appendingPathComponent(".tmp-clips", isDirectory: true))
    for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where Self.isSessionID(name) {
      total += Self.bytes(in: mediaFolder(session: name)) + Self.bytes(in: cacheFolder(session: name))
    }
    return total
  }

  /// Removes the `media/` and `cache/` of every session whose folder was last changed more than `days` days before
  /// `now`, except the sessions in `liveSessions`. The records stay, so their captures read as missing. Returns the
  /// bytes freed. The folder's time is put back afterwards: it is what ageing reads (see `prune`), and deleting inside
  /// it would otherwise make an old session look new.
  @discardableResult
  public func clearOldMedia(olderThan days: Int, liveSessions: Set<String>, now: Date) -> Int64 {
    let fm = FileManager.default
    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    var freed: Int64 = 0
    for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where Self.isSessionID(name) {
      let dir = sessionFolder(name)
      guard !liveSessions.contains(name),
            let changed = try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            changed < cutoff else { continue }
      for target in [mediaFolder(session: name), cacheFolder(session: name)] {
        let size = Self.bytes(in: target)
        if (try? fm.removeItem(at: target)) != nil { freed += size }
      }
      try? fm.setAttributes([.modificationDate: changed], ofItemAtPath: dir.path)
    }
    return freed
  }

  /// The sessions whose `claude` process is still running, from the tracking ledger's state files (the hooks write a
  /// pid for each session): their media is in use and is never cleared.
  public static func liveSessions(ledger: Ledger = Ledger(), alive: (Int32) -> Bool = ProcessTree.isClaude) -> Set<String> {
    var live = Set<String>()
    for repo in ledger.repos() {
      for session in ledger.state(repo: repo).sessions.values where session.isLive(alive) { live.insert(session.id) }
    }
    return live
  }

  private static func bytes(in folder: URL) -> Int64 {
    guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
    var total: Int64 = 0
    for case let url as URL in walk {
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
      total += Int64(values.fileSize ?? 0)
    }
    return total
  }
}

extension WorkStore {
  /// Files bigger than this are not copied into a record (a screen recording is the realistic case).
  public static let maxCaptureBytes = 200 * 1024 * 1024
  /// A hook (a browser screenshot) hashes a file only up to this size, so its cost stays small whatever the file; above
  /// it the capture is recorded with `sha256` nil, which readers treat as "unknown".
  public static let hookHashLimit = 16 * 1024 * 1024

  /// Copies the file at `file` into the session's media folder and adds a capture for it: the one path a hook's browser
  /// screenshot and the proof tools' `proof_capture` both take. Named after `id` (stripped to letters, digits, `-`
  /// and `_`, so a tool-supplied id cannot leave the folder) and kept as the file's own extension. The same id twice
  /// adds one capture. Nil, and no file left behind, when the source is missing, not a plain file, too big, or the
  /// record's lock wasn't free within `budget`. The file's SHA-256 is stored unless it is bigger than `hashLimit`.
  @discardableResult
  public func addCapture(session: String, id: String, from file: URL, kind: ProofCapture.Kind, url: String?,
                         environment: String?, caption: String, purpose: ProofCapture.Purpose, source: ProofSource,
                         cwd: String? = nil, worktree: String? = nil, branch: String? = nil, commonDir: String?,
                         now: Date = Date(),
                         budget: TimeInterval = 0.5, hashLimit: Int? = nil) -> ProofCapture? {
    guard Self.isSessionID(session) else { return nil }
    let fm = FileManager.default
    guard let attributes = try? fm.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType == .typeRegular,
          let size = attributes[.size] as? Int, size <= Self.maxCaptureBytes else { return nil }
    let safe = String(id.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" ? $0 : "_" })
    let stem = safe.isEmpty ? UUID().uuidString : String(safe.prefix(100))
    let ext = file.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8)
    let name = ext.isEmpty ? stem : stem + "." + ext
    // A hook passes `hashLimit` to keep its cost small; a bigger file is recorded with no hash (unknown).
    let digest = (hashLimit.map { size <= $0 } ?? true) ? Self.sha256(of: file) : nil
    let media = mediaFolder(session: session)
    try? fm.createDirectory(at: media, withIntermediateDirectories: true)
    let target = media.appendingPathComponent(name)
    var copied = false
    if !fm.fileExists(atPath: target.path) {
      guard (try? fm.copyItem(at: file, to: target)) != nil else { return nil }
      copied = true
    }
    var added: ProofCapture?
    let written = update(session: session, now: now, budget: budget) { record in
      record.place(cwd: cwd, worktree: worktree, branch: branch, commonDir: commonDir)
      guard !record.captures.contains(where: { $0.id == id }) else { return }
      let capture = ProofCapture(id: id, kind: kind, file: name, url: url, environment: environment, caption: caption,
                                 purpose: purpose, at: now, source: source, sha256: digest)
      record.captures.append(capture)
      added = capture
    }
    if written == nil, copied { try? fm.removeItem(at: target) }
    return added
  }

  /// Lowercase hex SHA-256 of a file, read in 1 MB pieces so a screen recording never sits in memory. Nil when the file
  /// can't be read.
  public static func sha256(of file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    do {
      // `read` answers nil, not empty data, at the end of the file.
      while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    } catch {
      return nil
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
