import Foundation

/// Where things live in the library folder (spec "The package format"): `<id>/` packages, `.runs/<id>/<run>.jsonl`
/// logs with each run's folder beside its log, `state/<id>.json`, approvals.json and schedule-state.json.
public enum AutomationLibraryLayout {
  public static let runsFolder = ".runs"
  public static let stateFolder = "state"
  public static let scheduleStateFile = "schedule-state.json"
  /// What git leaves alone: the user's runs, approvals, settings and state, never part of a package's history.
  public static let gitignore = ".runs/\napprovals.json\napprovals.json.bak\nschedule-state.json\nsettings.json\nstate/\n"
  /// A watcher's working folder under `.runs/<id>/` (it may keep its own files there between polls).
  public static let watcherFolder = "watcher"
  /// Folder names in the library that aren't automations: an automation with this id would never load.
  public static let reservedIDs: Set<String> = [stateFolder]

  /// A run's id: its start time as RunLog names files ("2026-10-09T09-00-00.120Z").
  public static func runID(start: Date) -> String {
    String(RunLog.fileName(for: start).dropLast(".jsonl".count))
  }

  public static func runLog(root: String, automation: String, run: String) -> String {
    "\(root)/\(runsFolder)/\(automation)/\(run).jsonl"
  }

  /// `{{run.dir}}`: next to the log, pruned with it.
  public static func runDirectory(root: String, automation: String, run: String) -> String {
    "\(root)/\(runsFolder)/\(automation)/\(run)"
  }

  public static func stateDirectory(root: String) -> String { "\(root)/\(stateFolder)" }

  /// A folder in the library that holds a package: not hidden, not state/.
  public static func isPackageFolder(_ name: String) -> Bool {
    !name.hasPrefix(".") && name != stateFolder
  }

  /// The package a changed path belongs to, or nil for runs, state, approvals and the library's own files: only
  /// package edits reload the library.
  public static func package(ofChange path: String, root: String) -> String? {
    guard path.hasPrefix(root + "/") else { return nil }
    let relative = path.dropFirst(root.count + 1)
    let first = relative.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    guard isPackageFolder(first), relative.contains("/") || !first.contains(".") else { return nil }
    return first
  }
}

/// One commit in an automation's history (the Setup page's History, Restore).
public struct AutomationHistoryEntry: Equatable, Sendable {
  public var commit: String
  public var date: Date
  public var message: String
  /// The version the commit wrote ("Save Fix red CI (fix-red-ci) v4" → 4); nil for a delete.
  public var version: Int?

  public init(commit: String, date: Date, message: String, version: Int?) {
    self.commit = commit
    self.date = date
    self.message = message
    self.version = version
  }

  public var shortCommit: String { String(commit.prefix(7)) }
}

/// What History shows.
public enum AutomationHistory: Equatable, Sendable {
  case entries([AutomationHistoryEntry])
  /// The library isn't a git repository or git isn't installed: saves still write files.
  case needsGit

  public static let needsGitMessage = "History needs git"
}

/// The git commands the library runs (in its folder, as "Glance"), and what their output means. Every command
/// names its paths, so another automation's uncommitted hand edit is never swept into a commit.
public enum AutomationGit {
  public static let environment = [
    "GIT_AUTHOR_NAME": "Glance", "GIT_AUTHOR_EMAIL": "glance@localhost",
    "GIT_COMMITTER_NAME": "Glance", "GIT_COMMITTER_EMAIL": "glance@localhost",
    "GIT_TERMINAL_PROMPT": "0",
  ]
  /// No signing prompts, no user hooks.
  static let base = ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]

  public static func initRepository() -> [String] { base + ["init", "-q"] }
  /// Prints the repository's top folder. Run it in the library folder and pass the output to `isLibraryRoot`:
  /// `--is-inside-work-tree` would also say yes for a library inside someone's unrelated repository (a dotfiles
  /// repo at ~), and Glance must never commit into that.
  public static func isRepository() -> [String] { base + ["rev-parse", "--show-toplevel"] }

  /// `isRepository()`'s output names the library folder itself (not a parent's repository). macOS reports
  /// "/private/var/…" for "/var/…", so that prefix is ignored on both sides.
  public static func isLibraryRoot(_ output: String, root: String) -> Bool {
    func normal(_ path: String) -> String {
      var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
      while text.count > 1, text.hasSuffix("/") { text.removeLast() }
      if text.hasPrefix("/private/") { text.removeFirst("/private".count) }
      return text
    }
    let top = normal(output)
    return !top.isEmpty && top == normal(root)
  }
  /// Stages a package folder ("fix-red-ci/") or one file (".gitignore"): new, changed and deleted files.
  public static func stage(_ path: String) -> [String] { base + ["add", "-A", "--", path] }
  /// Commits only that path.
  public static func commit(_ path: String, message: String) -> [String] {
    base + ["commit", "-q", "--no-verify", "-m", message, "--", path]
  }
  public static let startMessage = "Start the automations library"
  public static func head() -> [String] { base + ["rev-parse", "HEAD"] }
  public static func history(_ id: String) -> [String] {
    base + ["log", "--format=%H%x1f%at%x1f%s", "--", "\(id)/"]
  }
  /// Empties the package folder (files and index), so files added after `commit` don't survive a restore. `-f`:
  /// without it git refuses (and removes nothing) when a tracked file has uncommitted edits.
  public static func clear(_ id: String) -> [String] {
    base + ["rm", "-r", "-f", "-q", "--ignore-unmatch", "--", "\(id)/"]
  }
  /// nil unless `commit` is a hex commit id (7–40 characters): a value like "-f" must never become an option.
  public static func checkout(_ id: String, commit: String) -> [String]? {
    guard (7...40).contains(commit.count), commit.allSatisfy(\.isHexDigit) else { return nil }
    return base + ["checkout", commit, "--", "\(id)/"]
  }

  /// `git commit` says this when the package didn't change: not a failure.
  public static func isNothingToCommit(_ output: String) -> Bool {
    output.contains("nothing to commit") || output.contains("no changes added to commit")
      || output.contains("nothing added to commit")
  }

  public static func saveMessage(id: String, name: String, version: Int) -> String {
    "Save \(name) (\(id)) v\(version)"
  }

  public static func restoreMessage(id: String, name: String, version: Int, from entry: AutomationHistoryEntry)
    -> String {
    let restored = entry.version.map { "v\($0)" } ?? entry.shortCommit
    return "Restore \(name) (\(id)) \(restored) from \(entry.shortCommit) as v\(version)"
  }

  public static func deleteMessage(id: String, name: String) -> String { "Delete \(name) (\(id))" }

  /// `git log --format=%H%x1f%at%x1f%s` lines, newest first.
  public static func parseHistory(_ output: String) -> [AutomationHistoryEntry] {
    output.split(separator: "\n").compactMap { line in
      let fields = line.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 3, !fields[0].isEmpty, let seconds = TimeInterval(fields[1]) else { return nil }
      return AutomationHistoryEntry(commit: fields[0], date: Date(timeIntervalSince1970: seconds),
                                    message: fields[2], version: version(in: fields[2]))
    }
  }

  /// The last "v<number>" word: "… as v5" → 5; "Delete …" → nil.
  static func version(in message: String) -> Int? {
    guard !message.hasPrefix("Delete ") else { return nil }
    let words = message.split(separator: " ")
    for word in words.reversed() where word.hasPrefix("v") {
      if let number = Int(word.dropFirst()) { return number }
    }
    return nil
  }
}

/// The `"version"` number inside automation.json's text. A save bumps it by editing that number only: re-encoding
/// would lose the inputs' order and the author's layout (A0 plan decision).
public enum AutomationVersionText {
  /// The next version a save writes: one past what's on disk, or what the new text says when that is higher; a new
  /// automation keeps its own.
  public static func next(onDisk: Int?, given: Int) -> Int {
    guard let onDisk else { return max(given, 1) }
    return max(onDisk + 1, given)
  }

  /// `text` with its top-level `"version"` set to `version`; when it has none, `"version": N,` goes right after the
  /// opening brace. Text that isn't a JSON object comes back unchanged.
  public static func setting(_ version: Int, in text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var depth = 0
    var index = 0
    var openBrace: Int?
    var expectKey = false
    while index < scalars.count {
      let scalar = scalars[index]
      switch scalar {
      case "\"":
        let start = index
        index += 1
        while index < scalars.count, scalars[index] != "\"" { index += scalars[index] == "\\" ? 2 : 1 }
        guard index < scalars.count else { return text }
        if depth == 1, expectKey {
          let key = String(String.UnicodeScalarView(scalars[(start + 1)..<index]))
          expectKey = false
          if key == "version", let range = numberAfterColon(scalars, from: index + 1) {
            var view = String.UnicodeScalarView(scalars[..<range.lowerBound])
            view.append(contentsOf: String(version).unicodeScalars)
            view.append(contentsOf: scalars[range.upperBound...])
            return String(view)
          }
        }
      case "{", "[":
        depth += 1
        expectKey = scalar == "{"
        if depth == 1, scalar == "{", openBrace == nil { openBrace = index }
      case "}", "]":
        depth -= 1
      case ",":
        expectKey = depth == 1 || expectKey
      default:
        break
      }
      index += 1
    }
    guard let openBrace else { return text }
    let rest = scalars[(openBrace + 1)...]
    let empty = rest.first { !CharacterSet.whitespacesAndNewlines.contains($0) } == "}"
    var view = String.UnicodeScalarView(scalars[...openBrace])
    view.append(contentsOf: "\n  \"version\": \(version)\(empty ? "" : ",")".unicodeScalars)
    view.append(contentsOf: rest)
    return String(view)
  }

  /// The number's range after `: ` (whitespace allowed), or nil when the value isn't a number.
  static func numberAfterColon(_ scalars: [Unicode.Scalar], from start: Int) -> Range<Int>? {
    var index = start
    func skipSpace() {
      while index < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[index]) { index += 1 }
    }
    skipSpace()
    guard index < scalars.count, scalars[index] == ":" else { return nil }
    index += 1
    skipSpace()
    let begin = index
    while index < scalars.count, "-+.0123456789eE".unicodeScalars.contains(scalars[index]) { index += 1 }
    return index > begin ? begin..<index : nil
  }
}

/// Why a save, restore or delete didn't happen.
public enum AutomationSaveError: Error, Equatable, Sendable {
  /// Validation: nothing was written.
  case problems([AutomationProblem])
  case notFound(String)
  case failed(String)

  public var message: String {
    switch self {
    case .problems(let problems): AutomationCheck.report(problems)
    case .notFound(let id): "There's no automation `\(id)` in the library."
    case .failed(let reason): reason
    }
  }
}

/// A save, worked out before anything is written.
public struct AutomationSavePlan: Equatable, Sendable {
  /// Package path → text, automation.json included (with its new version).
  public var writes: [String: String]
  public var deletes: [String]
  public var manifest: AutomationManifest
  public var version: Int
}

/// `automation_save` and the library's save (spec "Claude: skill + Glance MCP"): merge the new files over the package,
/// bump the version in the text, validate the result with `AutomationCheck`; any problem and nothing is written.
public enum AutomationSave {
  /// `existing`: the package's files now, automation.json included (empty for a new automation). `library`: the
  /// other automations, id → the ids they call.
  public static func plan(id: String, existing: [String: String], files: [String: String], delete: [String],
                          library: [String: Set<String>], directory: String)
    -> Result<AutomationSavePlan, AutomationSaveError> {
    var problems: [AutomationProblem] = []
    if !AutomationManifest.isID(id) {
      problems.append(AutomationProblem("id", "`\(id)` must be 1–48 lowercase letters, digits or dashes"))
    } else if AutomationLibraryLayout.reservedIDs.contains(id) {
      problems.append(AutomationProblem("id", "`\(id)` is reserved by the library; pick another id"))
    }
    // A file written and deleted in one save is written.
    let delete = delete.filter { files[$0] == nil }
    let kept = existing.keys.filter { !delete.contains($0) }
    var byLowercase: [String: Set<String>] = [:]
    for path in Array(files.keys) + kept { byLowercase[path.lowercased(), default: []].insert(path) }
    for path in files.keys.sorted() where (byLowercase[path.lowercased()]?.count ?? 0) > 1 {
      problems.append(AutomationProblem(path, "differs only in letter case from another file in the package"))
    }
    for path in (Array(files.keys) + delete).sorted() {
      if let problem = pathProblem(path) { problems.append(problem) }
    }
    if delete.contains(AutomationManifest.fileName) {
      problems.append(AutomationProblem(AutomationManifest.fileName, "can't be deleted; delete the automation"))
    }
    guard problems.isEmpty else { return .failure(.problems(problems)) }
    var merged = existing
    for path in delete { merged[path] = nil }
    merged.merge(files) { $1 }
    guard let text = merged[AutomationManifest.fileName] else {
      return .failure(.problems([AutomationProblem(AutomationManifest.fileName, "is missing")]))
    }
    let onDisk = existing[AutomationManifest.fileName].flatMap { AutomationManifest.parse(Data($0.utf8)).manifest }
    guard let given = AutomationManifest.parse(Data(text.utf8)).manifest else {
      return .failure(.problems(AutomationManifest.parse(Data(text.utf8)).problems))
    }
    let version = AutomationVersionText.next(onDisk: onDisk?.version, given: given.version)
    let bumped = AutomationVersionText.setting(version, in: text)
    merged[AutomationManifest.fileName] = bumped
    var others = merged
    others[AutomationManifest.fileName] = nil
    let package = AutomationPackage(folderName: id, directory: directory, manifest: Data(bumped.utf8), files: others)
    let result = AutomationCheck.run(package, library: library, inputs: [:])
    guard result.problems.isEmpty, let manifest = AutomationManifest.parse(Data(bumped.utf8)).manifest else {
      return .failure(.problems(result.problems))
    }
    var writes = files
    writes[AutomationManifest.fileName] = bumped
    return .success(AutomationSavePlan(writes: writes, deletes: delete.filter { existing[$0] != nil }.sorted(),
                                       manifest: manifest, version: version))
  }

  /// A file path a save may write: relative, inside the package, no hidden files (`.git`, `.runs`), no `..`.
  public static func pathProblem(_ path: String) -> AutomationProblem? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") || parts.contains("..") || parts.contains("")
      || parts.contains(where: { $0.hasPrefix(".") }) {
      return AutomationProblem(path, "must be a file inside the package (no `..`, no leading `/`, no hidden files)")
    }
    return nil
  }
}
