import Foundation

/// The commits the user authored, for Journal (spec 2026-10-09-journal-design.md, "Capture"): which repositories to
/// look in, the `git log` that lists a day's commits with their line counts, and how to read it.
public enum JournalGit {
  public static let git = "/usr/bin/git"

  public static func rootArguments(folder: String) -> [String] {
    ["-C", folder, "rev-parse", "--show-toplevel"]
  }

  public static func emailArguments(root: String) -> [String] {
    ["-C", root, "config", "user.email"]
  }

  /// Every branch's commits by `email` (matched literally) in `range`, merges left out: one record per commit
  /// (`\u{1e}hash\u{1f}author date\u{1f}subject`) followed by its `--shortstat` line.
  public static func logArguments(root: String, email: String, range: DateInterval, calendar: Calendar) -> [String] {
    let format = Date.ISO8601FormatStyle(timeZone: calendar.timeZone)
    return ["-C", root, "log", "--all", "--no-merges", "--fixed-strings", "--author=<\(email)>",
            "--since=\(range.start.formatted(format))", "--until=\(range.end.formatted(format))",
            "--format=%x1e%H%x1f%aI%x1f%s", "--shortstat"]
  }

  /// The repositories to look in: each folder's git root (`resolve`), once, never `/` or the home folder (a dotfiles
  /// repository there would make git walk the whole disk).
  public static func roots(_ folders: [String], home: String, resolve: (String) -> String?) -> [String] {
    let homePath = SessionMatch.normalize(home, home: home)
    var seen = Set<String>()
    var roots: [String] = []
    for folder in folders {
      let path = SessionMatch.normalize(folder, home: home)
      guard path != "/", path != homePath,
            let root = resolve(path).map({ SessionMatch.normalize($0, home: home) }),
            root != "/", root != homePath, seen.insert(root).inserted else { continue }
      roots.append(root)
    }
    return roots
  }

  /// The commits in `output` (from `logArguments`) whose author date falls in `range`.
  public static func parse(_ output: String, root: String, range: DateInterval, calendar: Calendar) -> [JournalEvent] {
    output.split(separator: "\u{1e}").compactMap { block -> JournalEvent? in
      let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
      guard let head = lines.first else { return nil }
      let fields = head.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
      guard fields.count == 3, let date = JournalTime.parse(String(fields[1])), date >= range.start,
            date < range.end else { return nil }
      let hash = String(fields[0])
      let stat = lines.dropFirst().first { $0.contains("changed") }.map(String.init) ?? ""
      return JournalEvent(
        source: .git, externalID: hash, day: JournalDay(date, calendar: calendar), start: date, project: root,
        title: JournalText.clean(String(fields[2]), limit: 200),
        detail: JournalDetail(hash: hash, filesChanged: count(stat, "file"), insertions: count(stat, "insertion"),
                              deletions: count(stat, "deletion")))
    }
  }

  /// The number before `word` in a `--shortstat` line ("3 files changed, 40 insertions(+), 2 deletions(-)").
  static func count(_ stat: String, _ word: String) -> Int? {
    for part in stat.split(separator: ",") where part.contains(word) {
      return part.trimmingCharacters(in: .whitespaces).split(separator: " ").first.flatMap { Int($0) }
    }
    return nil
  }
}
