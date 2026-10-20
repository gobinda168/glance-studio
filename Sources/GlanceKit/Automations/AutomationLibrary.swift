import Foundation
import GlanceCore

/// One package as the library read it.
public struct AutomationLoaded: Equatable, Sendable {
  public var id: String
  public var manifest: AutomationManifest?
  /// `AutomationCheck`'s problems; empty means valid.
  public var problems: [AutomationProblem]
  public var readme: String
  /// automation.json's text (what an approval records).
  public var manifestText: String?
}

/// A save, restore or delete that landed.
public struct AutomationSaved: Equatable, Sendable {
  public var id: String
  public var version: Int
  public var manifest: AutomationManifest?
  /// The commit, or nil when there's no git (the files are written anyway) or nothing changed.
  public var commit: String?
}

/// The automations folder (spec 2026-10-09-automations-design.md, "The package format"): a git repository made on
/// first use. Reads packages, saves / restores / deletes them as commits by "Glance", keeps approvals.json and
/// schedule-state.json (outside git), and reads and prunes the run logs. Plain synchronous file and git work: the
/// engine calls it on the main thread (small files), `glance` directly. The rules are GlanceCore's
/// (`AutomationSave`, `AutomationGit`, `AutomationLibraryLayout`); this type does the disk.
public struct AutomationLibrary: Sendable {
  public let root: URL

  public init(root: URL) {
    self.root = root.standardizedFileURL
  }

  /// ~/Library/Application Support/Glance/Automations
  public static var standard: AutomationLibrary {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return AutomationLibrary(root: support.appendingPathComponent("Glance/Automations", isDirectory: true))
  }

  /// The root as FSEvents reports paths under it (/private/var/… for /var/…).
  public var realPath: String { Self.realPath(root.path) }

  /// A path as FSEvents reports it: symlinks resolved, /private kept (`URL.resolvingSymlinksInPath` drops it, so
  /// /var/folders/… would never match /private/var/folders/…). The path itself when it doesn't exist.
  public static func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  public func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
  public var stateDirectory: String { AutomationLibraryLayout.stateDirectory(root: root.path) }

  // MARK: Setup

  /// Makes the folder, its .runs/ and state/, its .gitignore, and (when git is installed) its repository with a
  /// first commit. False when there's no git: saves still write files and History says "History needs git".
  @discardableResult
  public func prepare() -> Bool {
    let files = FileManager.default
    for folder in [AutomationLibraryLayout.runsFolder, AutomationLibraryLayout.stateFolder] {
      try? files.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let ignore = root.appendingPathComponent(".gitignore")
    if !files.fileExists(atPath: ignore.path) {
      try? Data(AutomationLibraryLayout.gitignore.utf8).write(to: ignore, options: .atomic)
    }
    guard Self.gitPath != nil else { return false }
    if !isRepository {
      guard git(AutomationGit.initRepository()).status == 0 else { return false }
      _ = git(AutomationGit.stage(".gitignore"))
      _ = git(AutomationGit.commit(".gitignore", message: AutomationGit.startMessage))
    }
    return true
  }

  /// The library folder is itself a git repository: not merely inside someone's (a dotfiles repo at ~), which Glance
  /// must never commit into.
  var isRepository: Bool {
    guard Self.gitPath != nil else { return false }
    let top = git(AutomationGit.isRepository())
    return top.status == 0 && AutomationGit.isLibraryRoot(top.output, root: root.resolvingSymlinksInPath().path)
  }

  // MARK: Packages

  /// The package folders, sorted.
  public func ids() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.filter { name in
      var isFolder: ObjCBool = false
      return AutomationLibraryLayout.isPackageFolder(name)
        && FileManager.default.fileExists(atPath: folder(name).path, isDirectory: &isFolder) && isFolder.boolValue
    }.sorted()
  }

  /// Every file of a package, path → text (automation.json included).
  public func files(_ id: String) -> [String: String] { Self.readFiles(folder(id)) }

  /// Every file under a folder, relative path → text. Hidden files are skipped; a file over 1 MB or not UTF-8 reads
  /// as "".
  public static func readFiles(_ folder: URL) -> [String: String] {
    let base = folder.resolvingSymlinksInPath()
    var found: [String: String] = [:]
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])
    while let url = walker?.nextObject() as? URL {
      let values = try? url.resourceValues(forKeys: Set(keys))
      guard values?.isRegularFile == true else { continue }
      let full = url.resolvingSymlinksInPath().path
      guard full.hasPrefix(base.path + "/") else { continue }
      let small = (values?.fileSize ?? 0) <= 1_000_000
      found[String(full.dropFirst(base.path.count + 1))] = small
        ? (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } ?? "" : ""
    }
    return found
  }

  /// Every package's callees (id → the ids its steps call), for validation's missing-callee and loop checks.
  public func calls() -> [String: Set<String>] {
    var calls: [String: Set<String>] = [:]
    for id in ids() {
      let url = folder(id).appendingPathComponent(AutomationManifest.fileName)
      guard let data = try? Data(contentsOf: url) else { continue }
      calls[id] = AutomationManifest.parse(data).manifest?.callees ?? []
    }
    return calls
  }

  /// Reads and checks one package. `calls` comes from `calls()` (read once per reload).
  public func load(_ id: String, calls: [String: Set<String>]) -> AutomationLoaded {
    var files = files(id)
    guard let text = files.removeValue(forKey: AutomationManifest.fileName) else {
      return AutomationLoaded(id: id, manifest: nil, problems: [AutomationProblem(AutomationManifest.fileName,
                                                                                  "is missing")],
                              readme: files["README.md"] ?? "", manifestText: nil)
    }
    let package = AutomationPackage(folderName: id, directory: folder(id).path, manifest: Data(text.utf8),
                                    files: files)
    let result = AutomationCheck.run(package, library: calls, inputs: [:])
    // The form's saved values stand in for the inputs' defaults (AutomationSettings).
    let manifest = AutomationManifest.parse(Data(text.utf8)).manifest.map(loadSettings().applied(to:))
    return AutomationLoaded(id: id, manifest: manifest,
                            problems: result.problems, readme: files["README.md"] ?? "", manifestText: text)
  }

  /// The package files a run reads: its prompts, its scripts (for their #! line) and its watcher scripts.
  public func texts(for manifest: AutomationManifest) -> [String: String] {
    var paths = Set<String>()
    for step in manifest.steps {
      switch step.kind {
      case .script(let path), .claude(let path): paths.insert(path)
      default: break
      }
    }
    for trigger in manifest.triggers { if let script = trigger.script { paths.insert(script) } }
    var texts: [String: String] = [:]
    for path in paths {
      let url = folder(manifest.id).appendingPathComponent(path)
      if let text = (try? Data(contentsOf: url)).flatMap({ String(data: $0, encoding: .utf8) }) { texts[path] = text }
    }
    return texts
  }

  // MARK: Approvals and schedule state

  var approvalsURL: URL { root.appendingPathComponent(AutomationApprovalBook.fileName) }

  /// approvals.json's bytes (the engine compares them to tell another process's write from its own).
  func approvalsData() -> Data? { try? Data(contentsOf: approvalsURL) }

  /// approvals.json; a corrupt file is moved to approvals.json.bak and everything starts unapproved (spec "Errors").
  public func loadApprovals() -> AutomationApprovalBook {
    guard let data = try? Data(contentsOf: approvalsURL) else { return AutomationApprovalBook() }
    if let book = AutomationApprovalBook.decode(data) { return book }
    let backup = root.appendingPathComponent(AutomationApprovalBook.fileName + ".bak")
    try? FileManager.default.removeItem(at: backup)
    try? FileManager.default.moveItem(at: approvalsURL, to: backup)
    return AutomationApprovalBook()
  }

  /// False when the file couldn't be written: the caller says so (an approval that didn't stick must not look done).
  public func saveApprovals(_ book: AutomationApprovalBook) -> Bool {
    (try? book.encoded().write(to: approvalsURL, options: .atomic)) != nil
  }

  var scheduleStateURL: URL { root.appendingPathComponent(AutomationLibraryLayout.scheduleStateFile) }

  /// schedule-state.json; a missing or broken file starts over (every schedule armed now, nothing caught up).
  public func loadScheduleState() -> AutomationScheduleState {
    (try? Data(contentsOf: scheduleStateURL)).flatMap(AutomationScheduleState.decode) ?? AutomationScheduleState()
  }

  /// False when the file couldn't be written.
  public func saveScheduleState(_ state: AutomationScheduleState) -> Bool {
    (try? state.encoded().write(to: scheduleStateURL, options: .atomic)) != nil
  }

  var settingsURL: URL { root.appendingPathComponent(AutomationSettings.fileName) }

  /// settings.json; a missing or broken file means nothing saved (every input has its own default).
  public func loadSettings() -> AutomationSettings {
    (try? Data(contentsOf: settingsURL)).flatMap(AutomationSettings.decode) ?? AutomationSettings()
  }

  /// False when the file couldn't be written.
  public func saveSettings(_ settings: AutomationSettings) -> Bool {
    (try? settings.encoded().write(to: settingsURL, options: .atomic)) != nil
  }

  // MARK: Save, restore, delete, history

  /// Writes `files` over the package (and removes `delete`), bumps the version, validates, commits. Any problem and
  /// nothing is written. A new id makes a new package.
  public func save(_ id: String, files: [String: String], delete: [String] = [])
    -> Result<AutomationSaved, AutomationSaveError> {
    prepare()
    var others = calls()
    others[id] = nil
    let existing = FileManager.default.fileExists(atPath: folder(id).path) ? self.files(id) : [:]
    let plan: AutomationSavePlan
    switch AutomationSave.plan(id: id, existing: existing, files: files, delete: delete, library: others,
                               directory: folder(id).path) {
    case .failure(let error): return .failure(error)
    case .success(let made): plan = made
    }
    // Nothing is written until every path resolves inside the package's own folder (no symlinked folders or files).
    for path in Array(plan.writes.keys) + plan.deletes where !staysInside(id, path) {
      return .failure(.problems([AutomationProblem(path, "is a symbolic link or goes through one; it can't be written")]))
    }
    do {
      // automation.json goes last: a reload in the middle of a save never sees a new manifest with old scripts.
      let manifestName = AutomationManifest.fileName
      let ordered = plan.writes.sorted { $0.key < $1.key }
      for (path, text) in ordered where path != manifestName { try write(text, to: path, in: id) }
      for path in plan.deletes { try FileManager.default.removeItem(at: folder(id).appendingPathComponent(path)) }
      if let text = plan.writes[manifestName] { try write(text, to: manifestName, in: id) }
    } catch {
      return .failure(.failed("Couldn't write \(id): \(error.localizedDescription)"))
    }
    let commit = commit(id, message: AutomationGit.saveMessage(id: id, name: plan.manifest.name,
                                                               version: plan.version))
    return .success(AutomationSaved(id: id, version: plan.version, manifest: plan.manifest, commit: commit))
  }

  private func write(_ text: String, to path: String, in id: String) throws {
    let url = folder(id).appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
  }

  /// A package path a save may touch: its parent folder resolves (symlinks and all) to somewhere inside
  /// `<library>/<id>/`, and the file itself isn't a symbolic link. A folder that doesn't exist yet is judged by its
  /// nearest existing ancestor.
  func staysInside(_ id: String, _ path: String) -> Bool {
    let inside = Self.realPath(root.path) + "/" + id
    let target = folder(id).appendingPathComponent(path)
    if Self.isSymbolicLink(target.path) { return false }
    var ancestor = target.deletingLastPathComponent()
    var tail: [String] = []
    while !Self.exists(ancestor.path) {
      tail.insert(ancestor.lastPathComponent, at: 0)
      ancestor = ancestor.deletingLastPathComponent()
    }
    guard let resolved = realpath(ancestor.path, nil) else { return false }  // a dangling link
    defer { free(resolved) }
    let parent = ([String(cString: resolved)] + tail).joined(separator: "/")
    return parent == inside || parent.hasPrefix(inside + "/")
  }

  /// lstat: true for a link itself, dangling or not.
  static func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  static func isSymbolicLink(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
  }

  /// The package as it was at `commit` (a whole hash or its start), saved as a new version on top: a new commit.
  public func restore(_ id: String, commit: String) -> Result<AutomationSaved, AutomationSaveError> {
    guard case .entries(let entries) = history(id) else { return .failure(.failed(AutomationHistory.needsGitMessage)) }
    guard !commit.isEmpty, let entry = entries.first(where: { $0.commit.hasPrefix(commit) }) else {
      return .failure(.failed("`\(commit)` isn't in \(id)'s history."))
    }
    let manifestURL = folder(id).appendingPathComponent(AutomationManifest.fileName)
    let current = (try? Data(contentsOf: manifestURL)).flatMap { AutomationManifest.parse($0).manifest }
    guard let arguments = AutomationGit.checkout(id, commit: entry.commit) else {
      return .failure(.failed("`\(commit)` isn't a commit."))
    }
    // The package as it is now (hand edits included) waits in a backup until the restore has landed.
    let backup = FileManager.default.temporaryDirectory
      .appendingPathComponent("glance-restore-\(UUID().uuidString)", isDirectory: true)
    var hasBackup = false
    if FileManager.default.fileExists(atPath: folder(id).path) {
      do {
        try FileManager.default.moveItem(at: folder(id), to: backup)
        hasBackup = true
      } catch {
        return .failure(.failed("Couldn't restore \(id): \(error.localizedDescription)"))
      }
    }
    /// Puts the package back as it was before the restore started.
    func giveUp(_ reason: String) -> Result<AutomationSaved, AutomationSaveError> {
      if let back = AutomationGit.checkout(id, commit: git(AutomationGit.head()).output
        .trimmingCharacters(in: .whitespacesAndNewlines)) { _ = git(back) }
      if hasBackup {
        try? FileManager.default.removeItem(at: folder(id))
        try? FileManager.default.moveItem(at: backup, to: folder(id))
      }
      return .failure(.failed("Couldn't restore \(id): \(reason)"))
    }
    let clear = git(AutomationGit.clear(id))
    guard clear.status == 0 else { return giveUp(clear.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    let checkout = git(arguments)
    let text = (try? Data(contentsOf: manifestURL)).flatMap { String(data: $0, encoding: .utf8) }
    guard checkout.status == 0, let text else {
      return giveUp(checkout.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let restored = AutomationManifest.parse(Data(text.utf8)).manifest
    let version = max(current?.version ?? 0, entries.compactMap(\.version).max() ?? 0, restored?.version ?? 0) + 1
    do {
      try Data(AutomationVersionText.setting(version, in: text).utf8).write(to: manifestURL, options: .atomic)
    } catch {
      return giveUp(error.localizedDescription)
    }
    if hasBackup { try? FileManager.default.removeItem(at: backup) }
    let name = restored?.name ?? current?.name ?? id
    let hash = self.commit(id, message: AutomationGit.restoreMessage(id: id, name: name, version: version, from: entry))
    let manifest = (try? Data(contentsOf: manifestURL)).flatMap { AutomationManifest.parse($0).manifest }
    return .success(AutomationSaved(id: id, version: version, manifest: manifest, commit: hash))
  }

  /// Removes the package: a commit, so History can bring it back. Its runs and state stay.
  public func delete(_ id: String) -> Result<AutomationSaved, AutomationSaveError> {
    guard ids().contains(id) else { return .failure(.notFound(id)) }
    let manifestURL = folder(id).appendingPathComponent(AutomationManifest.fileName)
    let manifest = (try? Data(contentsOf: manifestURL)).flatMap { AutomationManifest.parse($0).manifest }
    do {
      try FileManager.default.removeItem(at: folder(id))
    } catch {
      return .failure(.failed("Couldn't delete \(id): \(error.localizedDescription)"))
    }
    let commit = commit(id, message: AutomationGit.deleteMessage(id: id, name: manifest?.name ?? id))
    return .success(AutomationSaved(id: id, version: manifest?.version ?? 0, manifest: nil, commit: commit))
  }

  /// The package's commits, newest first; `.needsGit` without git or a repository.
  public func history(_ id: String) -> AutomationHistory {
    guard Self.gitPath != nil, isRepository else { return .needsGit }
    let result = git(AutomationGit.history(id))
    return .entries(result.status == 0 ? AutomationGit.parseHistory(result.output) : [])
  }

  /// Stages and commits the package folder; the new commit, or nil (no git, no repository, nothing changed).
  func commit(_ id: String, message: String) -> String? {
    guard Self.gitPath != nil, isRepository else { return nil }
    _ = git(AutomationGit.stage("\(id)/"))
    guard git(AutomationGit.commit("\(id)/", message: message)).status == 0 else { return nil }
    let head = git(AutomationGit.head())
    return head.status == 0 ? head.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
  }

  // MARK: git

  /// git without macOS's "install the command line developer tools?" prompt (/usr/bin/git is only a shim that asks):
  /// the selected developer directory's git, the Command Line Tools', or Homebrew's.
  static let gitPath: String? = {
    var candidates = ["/Library/Developer/CommandLineTools/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
    if let developer = developerDirectory() { candidates.insert(developer + "/usr/bin/git", at: 0) }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }()

  /// `xcode-select -p` (it never prompts).
  static func developerDirectory() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return process.terminationStatus == 0 && !path.isEmpty ? path : nil
  }

  /// The variables that point git at a repository, index or object store: dropped from every git process.
  static let gitLocation = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR",
                            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX"]

  /// Runs git in the library folder as "Glance"; stdout and stderr together.
  func git(_ arguments: [String]) -> (status: Int32, output: String) {
    guard let gitPath = Self.gitPath else { return (127, "git isn't installed") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: gitPath)
    process.arguments = arguments
    process.currentDirectoryURL = root
    var environment = ProcessInfo.processInfo.environment
    // A caller's own repository (a hook, a script run from one) must never redirect git away from the library.
    for name in Self.gitLocation { environment[name] = nil }
    process.environment = environment.merging(AutomationGit.environment) { $1 }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return (127, error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  // MARK: Runs

  var runsRoot: URL { root.appendingPathComponent(AutomationLibraryLayout.runsFolder, isDirectory: true) }

  /// A new run's id, log file and run folder (both created). Two runs in the same millisecond get the next one.
  public func newRun(_ id: String, start: Date) -> (ref: AutomationRunRef, log: URL, directory: URL)? {
    var start = start
    for _ in 0..<1000 {
      let run = AutomationLibraryLayout.runID(start: start)
      let log = URL(fileURLWithPath: AutomationLibraryLayout.runLog(root: root.path, automation: id, run: run))
      let directory = URL(fileURLWithPath: AutomationLibraryLayout.runDirectory(root: root.path, automation: id,
                                                                                 run: run))
      if !FileManager.default.fileExists(atPath: log.path) {
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          guard FileManager.default.createFile(atPath: log.path, contents: nil) else { return nil }
        } catch {
          return nil
        }
        return (AutomationRunRef(automation: id, run: run), log, directory)
      }
      start = start.addingTimeInterval(0.001)
    }
    return nil
  }

  public func logURL(_ ref: AutomationRunRef) -> URL {
    URL(fileURLWithPath: AutomationLibraryLayout.runLog(root: root.path, automation: ref.automation, run: ref.run))
  }

  /// Its runs' ids, newest first.
  public func runIDs(_ id: String) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: runsRoot.appendingPathComponent(id).path)) ?? []
    return names.filter { RunLog.start(ofFile: $0) != nil }.map { String($0.dropLast(".jsonl".count)) }
      .sorted(by: >)
  }

  public func runLines(_ ref: AutomationRunRef) -> [RunLogLine] {
    guard let data = try? Data(contentsOf: logURL(ref)) else { return [] }
    return RunLog.decode(String(decoding: data, as: UTF8.self))
  }

  /// The newest runs; `live` are the run ids the engine is still running (a log without run.end that isn't live
  /// reads as interrupted).
  public func runs(_ id: String, limit: Int, live: Set<String>) -> [RunRecord] {
    runIDs(id).prefix(limit).compactMap { run in
      RunLog.summarize(runLines(AutomationRunRef(automation: id, run: run)), id: run, live: live.contains(run))
    }
  }

  /// Run logs older than 30 days or beyond the newest 200 per automation, with their run folders (at launch).
  public func prune(now: Date) {
    let automations = (try? FileManager.default.contentsOfDirectory(atPath: runsRoot.path)) ?? []
    for id in automations where !id.hasPrefix(".") {
      let folder = runsRoot.appendingPathComponent(id)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
      for name in RunLog.prune(names, now: now) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(String(name.dropLast(".jsonl".count))))
      }
    }
  }

  /// Claude's cost across every run that started in [from, to).
  public func claudeCost(from: Date, to: Date) -> Double {
    let automations = (try? FileManager.default.contentsOfDirectory(atPath: runsRoot.path)) ?? []
    var total = 0.0
    for id in automations where !id.hasPrefix(".") {
      for run in runIDs(id) {
        guard let start = RunLog.start(ofFile: run + ".jsonl"), start >= from, start < to else { continue }
        let ref = AutomationRunRef(automation: id, run: run)
        total += RunLog.summarize(runLines(ref), id: run, live: true)?.costUSD ?? 0
      }
    }
    return total
  }
}
