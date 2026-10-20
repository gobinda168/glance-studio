import Foundation

/// What a folder's repo has changed since its last commit, staged or not, new files included: the top bar's
/// "▤ 25 · +282 −385".
public enum WorkingChanges {
  public struct Summary: Equatable, Sendable {
    public let files: Int
    public let additions: Int
    public let deletions: Int

    public init(files: Int, additions: Int, deletions: Int) {
      self.files = files
      self.additions = additions
      self.deletions = deletions
    }

    public var isClean: Bool { files == 0 }

    /// "25 files changed in glance: 282 lines added, 385 removed", for the tooltip and VoiceOver.
    public func sentence(folder: String) -> String {
      "\(files) \(files == 1 ? "file" : "files") changed in \(folder): "
        + "\(additions) \(additions == 1 ? "line" : "lines") added, \(deletions) removed"
    }
  }

  /// git only reads: a refresh every few seconds mustn't hold `index.lock` while a commit wants it.
  public static let environment = ["GIT_OPTIONAL_LOCKS": "0"]
  public static let rootArguments = ["rev-parse", "--show-toplevel"]
  /// Tracked files against the last commit, staged and unstaged together. Fails before the first commit.
  public static let numstatArguments = ["diff", "HEAD", "--numstat", "--no-renames", "--no-ext-diff", "-z"]
  /// New files git doesn't ignore, as paths from the repo's root.
  public static let untrackedArguments = ["ls-files", "--others", "--exclude-standard", "--full-name", "-z"]

  /// New files bigger than this, or past the first `untrackedLimit`, count as a file without lines.
  static let untrackedByteLimit = 1 << 20
  static let untrackedLimit = 500

  /// `numstat` from `git diff --numstat -z`, `untracked` from `git ls-files -z`, `lines` each new file's line count.
  public static func summary(numstat: String, untracked: String, lines: [String: Int]) -> Summary {
    let tracked = BranchCompare.fileStats(numstat)
    let totals = BranchCompare.totals(tracked)
    let seen = Set(tracked.map(\.path))
    let new = untrackedPaths(untracked).filter { !seen.contains($0) }
    return Summary(files: tracked.count + new.count,
                   additions: totals.additions + new.reduce(0) { $0 + (lines[$1] ?? 0) },
                   deletions: totals.deletions)
  }

  static func untrackedPaths(_ output: String) -> [String] {
    output.split(separator: "\0").map(String.init)
  }

  /// A new file's lines, as git would count them added; nil for a binary file (a NUL byte).
  public static func lineCount(_ data: Data) -> Int? {
    guard !data.contains(0) else { return nil }
    let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
    return newlines + (data.last.map { $0 == 0x0A ? 0 : 1 } ?? 0)
  }

  /// Asks git about the repo holding `folder`; nil outside a repo, before its first commit, or when git can't run.
  /// Blocks: call it off the main thread.
  struct LineEntry: Sendable {
    let size: Int
    let modified: Date?
    let lines: Int?
  }

  /// The last read's untracked-file line counts per repo root, so a repeat read only opens the files that changed.
  private final class LineCache: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String: [String: LineEntry]] = [:]

    func entries(for root: String) -> [String: LineEntry] {
      lock.lock(); defer { lock.unlock() }
      return roots[root] ?? [:]
    }

    func set(_ entries: [String: LineEntry], for root: String) {
      lock.lock(); defer { lock.unlock() }
      roots[root] = entries
      if roots.count > 16 { roots = roots.filter { $0.key == root } }
    }
  }

  private static let lineCache = LineCache()

  public static func read(folder: String) -> Summary? {
    func git(_ arguments: [String], in directory: String) -> String? {
      guard let result = GitHubCLI.execute("/usr/bin/git", ["-C", directory] + arguments, environment: environment),
            result.status == 0 else { return nil }
      return String(decoding: result.output, as: UTF8.self)
    }
    guard let root = git(rootArguments, in: folder)?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty,
          let numstat = git(numstatArguments, in: root) else { return nil }
    let untracked = git(untrackedArguments, in: root) ?? ""
    var lines: [String: Int] = [:]
    // Polled every few seconds: a file whose size and mtime haven't moved keeps its last count instead of being read again.
    let previous = lineCache.entries(for: root)
    var kept: [String: LineEntry] = [:]
    for path in untrackedPaths(untracked).prefix(untrackedLimit) {
      let url = URL(fileURLWithPath: root).appendingPathComponent(path)
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize, size <= untrackedByteLimit else { continue }
      let modified = values.contentModificationDate
      if let hit = previous[path], hit.size == size, hit.modified == modified {
        kept[path] = hit
        if let count = hit.lines { lines[path] = count }
        continue
      }
      let count = (try? Data(contentsOf: url)).flatMap(lineCount)
      kept[path] = LineEntry(size: size, modified: modified, lines: count)
      if let count { lines[path] = count }
    }
    lineCache.set(kept, for: root)
    return summary(numstat: numstat, untracked: untracked, lines: lines)
  }
}
