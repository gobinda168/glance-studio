import CryptoKit
import Darwin
import Foundation

/// A worktree's uncommitted files at one moment: per path (relative to the worktree's top folder) its git status,
/// size, mtime and content hash. Comparing two says what changed in between (spec §1, "Fingerprints").
public struct Fingerprint: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public var status: String
    public var size: Int64
    public var mtime: Double
    public var hash: String

    public init(status: String, size: Int64, mtime: Double, hash: String) {
      self.status = status
      self.size = size
      self.mtime = mtime
      self.hash = hash
    }
  }

  /// Above this many uncommitted files a worktree is "too many to track".
  public static let limit = 2000

  public var entries: [String: Entry]
  public var tooMany: Bool

  public init(entries: [String: Entry] = [:], tooMany: Bool = false) {
    self.entries = entries
    self.tooMany = tooMany
  }

  /// Paths and XY statuses from `git status --porcelain=v2 -z --untracked-files=all` ("??" for untracked). Ignored
  /// files aren't listed by that command.
  public static func parseStatus(_ data: Data) -> [(path: String, status: String)] {
    let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    var out: [(path: String, status: String)] = []
    var index = 0
    while index < fields.count {
      let line = fields[index]
      index += 1
      switch line.first {
      case "1": if let path = tail(line, after: 8) { out.append((path, xy(line))) }
      case "2":
        if let path = tail(line, after: 9) { out.append((path, xy(line))) }
        index += 1 // the original path, its own field
      case "u": if let path = tail(line, after: 10) { out.append((path, xy(line))) }
      case "?": out.append((String(line.dropFirst(2)), "??"))
      default: break
      }
    }
    return out
  }

  /// The text after the first `count` space-separated fields (a path may contain spaces).
  static func tail(_ line: String, after count: Int) -> String? {
    var rest = Substring(line)
    for _ in 0..<count {
      guard let space = rest.firstIndex(of: " ") else { return nil }
      rest = rest[rest.index(after: space)...]
    }
    return rest.isEmpty ? nil : String(rest)
  }

  static func xy(_ line: String) -> String { String(line.dropFirst(2).prefix(2)) }

  /// The fingerprint of `status`'s files under `root`. A file whose status, size and mtime match `previous` keeps
  /// its hash without being read; others get `describe`'s hash, and only a regular file of at most `bigFile` bytes
  /// goes through `hash` (which reads it).
  public static func take(root: String, status: [(path: String, status: String)], previous: Fingerprint?,
                          hash: (String) -> String = Fingerprint.contentHash(file:)) -> Fingerprint {
    guard status.count <= limit else { return Fingerprint(tooMany: true) }
    var entries: [String: Entry] = [:]
    for (path, code) in status {
      let full = root + "/" + path
      let stamp = stat(of: full)
      let size = stamp?.size ?? -1
      let mtime = stamp?.mtime ?? 0
      if let old = previous?.entries[path], old.status == code, old.size == size, old.mtime == mtime {
        entries[path] = old
      } else {
        entries[path] = Entry(status: code, size: size, mtime: mtime, hash: describe(full, stamp: stamp, read: hash))
      }
    }
    return Fingerprint(entries: entries)
  }

  /// Above this many bytes a file isn't read on the hook path: its hash is "big:<size>:<mtime>".
  public static let bigFile: Int64 = 8 * 1024 * 1024

  /// What one `lstat` says about a file: its size, mtime and type (`S_IFREG`, `S_IFLNK`, …).
  struct Stamp {
    var size: Int64
    var mtime: Double
    var type: mode_t
  }

  /// A file's size, mtime and type from one `lstat` (a symlink is described, not followed); nil when it is missing.
  /// Much cheaper than `FileManager.attributesOfItem`, which a hook pays for every uncommitted file.
  static func stat(of path: String) -> Stamp? {
    var info = Darwin.stat()
    guard lstat(path, &info) == 0 else { return nil }
    let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    return Stamp(size: Int64(info.st_size), mtime: mtime, type: info.st_mode & S_IFMT)
  }

  /// A file's hash from its `lstat` result: "deleted" when missing, "link:<target>" for a symlink, "special" for
  /// anything else that isn't a regular file (a folder, a FIFO: never opened), "big:<size>:<mtime>" for a regular
  /// file over `bigFile`, else `read`'s content hash.
  static func describe(_ path: String, stamp: Stamp?, read: (String) -> String) -> String {
    guard let stamp else { return "deleted" }
    switch stamp.type {
    case S_IFREG:
      return stamp.size > bigFile ? "big:\(stamp.size):\(stamp.mtime)" : read(path)
    case S_IFLNK:
      return "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "")
    default:
      return "special"
    }
  }

  /// The worktree's fingerprint now, from git; nil when git fails.
  public static func current(root: String, previous: Fingerprint?) -> Fingerprint? {
    GitRun.data(root, ["status", "--porcelain=v2", "-z", "--untracked-files=all"])
      .map { take(root: root, status: parseStatus($0), previous: previous) }
  }

  /// A file's hash as a fingerprint records it (see `describe`): only a regular file of at most `bigFile` bytes is
  /// read.
  public static func hash(file path: String) -> String {
    describe(path, stamp: stat(of: path), read: contentHash(file:))
  }

  /// The SHA-256 of a file's bytes, "unreadable" when it can't be read.
  public static func contentHash(file path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path) else { return "unreadable" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Each path's content hash.
  public var hashes: [String: String] { entries.mapValues(\.hash) }

  /// The paths whose content changed: a different hash, newly uncommitted, or no longer uncommitted. Sorted. Staging
  /// (status) or touching (mtime) a file isn't a change.
  public func changedContent(to after: Fingerprint) -> [String] {
    Self.changed(from: hashes, to: after.hashes)
  }

  /// The paths of two path → hash maps that are in only one of them or whose hashes differ. Sorted.
  public static func changed(from before: [String: String], to after: [String: String]) -> [String] {
    Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
  }
}
