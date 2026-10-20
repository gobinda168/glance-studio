import Foundation

/// A project's uncommitted changes against HEAD, as `git status` lists them, and a file's text at HEAD. For the
/// editors' Changes views (spec 2026-10-06-changes-view-design.md).
public enum GitChanges {
  public struct Change: Equatable, Sendable {
    public enum Status: String, Sendable { case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "U" }

    public let path: String
    public let status: Status
    /// For a rename, the path at HEAD.
    public let oldPath: String?

    public init(path: String, status: Status, oldPath: String? = nil) {
      self.path = path
      self.status = status
      self.oldPath = oldPath
    }
  }

  /// The Changes panel's two lists: what is staged (the index against HEAD) and what isn't (the work tree against the
  /// index, and untracked files). A file staged and then edited again is in both.
  public struct Lists: Equatable, Sendable {
    public var staged: [Change]
    public var unstaged: [Change]

    public init(staged: [Change], unstaged: [Change]) {
      self.staged = staged
      self.unstaged = unstaged
    }
  }

  /// `git status --porcelain=v1 -z` output, sorted by path. Ignored files are skipped.
  public static func parse(_ output: String) -> [Change] {
    var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
    var changes: [Change] = []
    while let entry = fields.popFirst() {
      guard entry.count > 3 else { continue }
      let x = entry[entry.startIndex]
      let y = entry[entry.index(after: entry.startIndex)]
      let path = String(entry.dropFirst(3))
      switch (x, y) {
      case ("!", _):
        continue
      case ("R", _), ("C", _):
        let old = fields.popFirst()
        changes.append(x == "R" ? Change(path: path, status: .renamed, oldPath: old) : Change(path: path, status: .added))
      case ("?", _):
        changes.append(Change(path: path, status: .untracked))
      case ("D", _), (_, "D"):
        changes.append(Change(path: path, status: .deleted))
      case ("A", _):
        changes.append(Change(path: path, status: .added))
      default:
        changes.append(Change(path: path, status: .modified))
      }
    }
    return changes.sorted { $0.path < $1.path }
  }

  /// `git status --porcelain=v1 -z` output split into staged and unstaged, each sorted by path. A merge conflict is an
  /// unstaged change (staging it marks it resolved); ignored files are skipped.
  public static func parseLists(_ output: String) -> Lists {
    var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
    var lists = Lists(staged: [], unstaged: [])
    while let entry = fields.popFirst() {
      guard entry.count > 3 else { continue }
      let x = entry[entry.startIndex]
      let y = entry[entry.index(after: entry.startIndex)]
      let path = String(entry.dropFirst(3))
      let old = "RC".contains(x) || "RC".contains(y) ? fields.popFirst() : nil
      switch (x, y) {
      case ("!", _):
        continue
      case ("?", _):
        lists.unstaged.append(Change(path: path, status: .untracked))
      case ("U", _), (_, "U"), ("A", "A"), ("D", "D"):
        lists.unstaged.append(Change(path: path, status: .modified))
      default:
        if let status = side(x) { lists.staged.append(Change(path: path, status: status, oldPath: x == "R" ? old : nil)) }
        if let status = side(y) { lists.unstaged.append(Change(path: path, status: status, oldPath: y == "R" ? old : nil)) }
      }
    }
    lists.staged.sort { $0.path < $1.path }
    lists.unstaged.sort { $0.path < $1.path }
    return lists
  }

  /// One side of a porcelain status code; nil when that side has no change.
  private static func side(_ code: Character) -> Change.Status? {
    switch code {
    case "M", "T": .modified
    case "A", "C": .added
    case "D": .deleted
    case "R": .renamed
    default: nil
    }
  }

  /// Paths made relative to a root that is `prefix` inside the repository (as `git rev-parse --show-prefix` prints
  /// it); changes outside it are dropped.
  public static func relative(_ changes: [Change], prefix: String) -> [Change] {
    guard !prefix.isEmpty else { return changes }
    return changes.compactMap { change in
      guard change.path.hasPrefix(prefix) else { return nil }
      let old = change.oldPath.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
      return Change(path: String(change.path.dropFirst(prefix.count)), status: change.status, oldPath: old)
    }
  }

  /// The changes of `root`'s repository, relative to `root`. Nil when `root` isn't in a git repository.
  public static func status(root: String) -> [Change]? {
    guard let prefix = git(root, ["rev-parse", "--show-prefix"]),
          let output = git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) else { return nil }
    let trimmed = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return relative(parse(String(decoding: output, as: UTF8.self)), prefix: trimmed)
  }

  /// The staged and unstaged changes of `root`'s repository, relative to `root`. Nil when `root` isn't in a git
  /// repository.
  public static func lists(root: String) -> Lists? {
    guard let prefix = git(root, ["rev-parse", "--show-prefix"]),
          let output = git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) else { return nil }
    let trimmed = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let lists = parseLists(String(decoding: output, as: UTF8.self))
    return Lists(staged: relative(lists.staged, prefix: trimmed), unstaged: relative(lists.unstaged, prefix: trimmed))
  }

  /// A file's staged text (path relative to `root`). Nil when it isn't in the index or isn't UTF-8.
  public static func indexText(root: String, path: String) -> String? {
    git(root, ["show", ":./" + path]).flatMap { String(data: $0, encoding: .utf8) }
  }

  /// Stages files (paths relative to `root`), new and deleted ones included. Nil when it worked, else git's message.
  public static func stage(root: String, paths: [String]) -> String? {
    action(root, ["add", "-A", "--"] + paths, failure: "git add failed")
  }

  /// Takes files out of the index, back to HEAD (or out of it, before the first commit). Nil when it worked.
  public static func unstage(root: String, paths: [String]) -> String? {
    action(root, ["reset", "-q", "--"] + paths, failure: "git reset failed")
  }

  /// Throws away unstaged changes: tracked files go back to their staged text (HEAD's, when nothing is staged) and
  /// untracked files go to the Trash. Nil when it worked, else what went wrong.
  public static func discard(root: String, tracked: [String], untracked: [String]) -> String? {
    let base = URL(fileURLWithPath: root).standardizedFileURL.path + "/"
    let urls = untracked.map { URL(fileURLWithPath: root).appendingPathComponent($0).standardizedFileURL }
    guard urls.allSatisfy({ $0.path.hasPrefix(base) }) else { return "That file isn't in the project" }
    if !tracked.isEmpty, let error = action(root, ["restore", "--"] + tracked, failure: "git restore failed") { return error }
    for url in urls {
      do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { return error.localizedDescription }
    }
    return nil
  }

  /// Commits what is staged, with git's hooks. Nil when it worked, else git's (or a hook's) message.
  public static func commit(root: String, message: String) -> String? {
    action(root, ["commit", "-q", "-F", "-"], input: message, failure: "git commit failed")
  }

  /// What a commit message is drafted from: the staged diff (or, with nothing staged, every uncommitted change and
  /// the new files' names) and the latest ten commit subjects, newest first. Nil outside a git repository.
  public static func draftContext(root: String) -> (diff: String, recent: [String], staged: Bool)? {
    guard let staged = git(root, ["diff", "--cached", "--no-color", "--no-ext-diff"]) else { return nil }
    let recent = git(root, ["log", "-10", "--format=%s"]).map {
      String(decoding: $0, as: UTF8.self).split(separator: "\n").map(String.init)
    } ?? []
    if !staged.isEmpty { return (String(decoding: staged, as: UTF8.self), recent, true) }
    var diff = String(decoding: git(root, ["diff", "--no-color", "--no-ext-diff"]) ?? Data(), as: UTF8.self)
    let untracked = lists(root: root)?.unstaged.filter { $0.status == .untracked }.map(\.path) ?? []
    if !untracked.isEmpty { diff += "\nNew files:\n" + untracked.joined(separator: "\n") }
    return (diff, recent, false)
  }

  /// A file's text at HEAD (path relative to `root`). Nil when it isn't in HEAD, there's no HEAD yet, or it isn't UTF-8.
  public static func headText(root: String, path: String) -> String? {
    git(root, ["show", "HEAD:./" + path]).flatMap { String(data: $0, encoding: .utf8) }
  }

  /// A git command that changes something, paths taken literally (no pathspec magic in file names). Nil when it
  /// worked, else git's output (stdout and stderr together: hooks print to either) or `failure`.
  private static func action(_ root: String, _ arguments: [String], input: String? = nil, failure: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["--literal-pathspecs", "-C", root] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let stdin = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    do { try process.run() } catch { return "git couldn't be run" }
    if let input {
      stdin.fileHandleForWriting.write(Data(input.utf8))
      try? stdin.fileHandleForWriting.close()
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus != 0 else { return nil }
    let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? failure : message
  }

  private static func git(_ root: String, _ arguments: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
  }
}
