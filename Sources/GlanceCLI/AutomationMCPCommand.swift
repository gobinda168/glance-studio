import Darwin
import Foundation
import GlanceCore
import GlanceKit

/// `glance automation mcp [--library <dir>] [--socket <path>]` (spec 2026-10-09-automations-design.md, "glance mcp"):
/// the Glance MCP server on stdin and stdout, which Claude Code starts from the Glance plugin's .mcp.json. Reads
/// (search, get, events) and saves work on the library folder directly, with the same `AutomationLibrary` code as
/// Studio; run and runs ask Studio's engine over its socket. One JSON-RPC message per line; calls are answered as they
/// finish, so a long automation_run doesn't hold up a search.
enum AutomationMCPCommand {
  /// Library work (search, get, save, events) one at a time.
  static let libraryQueue = DispatchQueue(label: "dev.glance.mcp.library")
  /// Calls that wait on Studio (a run can take minutes), so they never hold up the library queue.
  static let studioQueue = DispatchQueue(label: "dev.glance.mcp.studio", attributes: .concurrent)
  static let output = DispatchQueue(label: "dev.glance.mcp.output")
  /// The most calls waiting on Studio at once (each holds a thread and a connection).
  static let studioCallLimit = 8
  static let studioSlots = Counter()
  /// How long Studio gets to answer a run that doesn't wait, and a list of runs.
  static let quickTimeout: TimeInterval = 15
  static let listTimeout: TimeInterval = 5

  /// A count under a lock.
  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Takes a place when fewer than `limit` are taken.
    func take(limit: Int) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard value < limit else { return false }
      value += 1
      return true
    }

    func release() {
      lock.lock()
      value -= 1
      lock.unlock()
    }
  }

  static func run(_ library: AutomationLibrary, _ arguments: [String]) -> Int32 {
    let usage = "usage: glance automation mcp [--library <dir>] [--socket <path>]\n"
    var socket: String?
    var rest = arguments
    if let flag = rest.firstIndex(of: "--socket") {
      guard flag + 1 < rest.count else {
        FileHandle.standardError.write(Data(usage.utf8))
        return 2
      }
      socket = rest[flag + 1]
      rest.removeSubrange(flag...(flag + 1))
    }
    guard rest.isEmpty else {
      FileHandle.standardError.write(Data(usage.utf8))
      return 2
    }
    // A closed stdout must end a write with an error, not kill the server.
    signal(SIGPIPE, SIG_IGN)
    let path = socket ?? AutomationSocketWire.path(environment: ProcessInfo.processInfo.environment,
                                                   home: NSHomeDirectory())
    let groups = Groups()
    var lines = AutomationMCPLines()
    var chunk = [UInt8](repeating: 0, count: 65536)
    var events: [AutomationMCPLines.Event] = []
    while true {
      let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
      if count < 0, errno == EINTR { continue }
      if count <= 0 {
        events = lines.finish()
      } else {
        events = lines.feed(Data(chunk[0..<count]))
      }
      for event in events { handle(event, library: library, socket: path, groups: groups) }
      if count <= 0 { break }
    }
    // stdin closed: Claude Code is done with the server. A save in flight finishes (half a save is worse than a
    // late exit); calls waiting on Studio get a moment to answer, then go.
    groups.library.wait()
    _ = groups.studio.wait(timeout: .now() + 2)
    return 0
  }

  /// The calls in flight: library work, and calls waiting on Studio.
  struct Groups {
    let library = DispatchGroup()
    let studio = DispatchGroup()
  }

  static func handle(_ event: AutomationMCPLines.Event, library: AutomationLibrary, socket: String,
                     groups: Groups) {
    let message: AutomationMCPMessage
    switch event {
    case .tooLong: message = AutomationMCP.lineTooLong
    case .line(let line):
      guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      message = AutomationMCP.parse(line)
    }
    switch AutomationMCP.reply(to: message, version: AppVersion.current.full) {
    case .none:
      return
    case .send(let text):
      send(text)
    case .call(let id, let call):
      let talksToStudio: Bool
      switch call {
      case .run, .runs: talksToStudio = true
      default: talksToStudio = false
      }
      if talksToStudio, !studioSlots.take(limit: studioCallLimit) {
        send(AutomationMCP.toolResult(id: id, text: "Too many calls are waiting on Glance Studio; try again when "
                                        + "one has finished.", isError: true))
        return
      }
      let queue = talksToStudio ? studioQueue : libraryQueue
      queue.async(group: talksToStudio ? groups.studio : groups.library) {
        let (text, isError) = carryOut(call, library: library, socket: socket)
        if talksToStudio { studioSlots.release() }
        send(AutomationMCP.toolResult(id: id, text: text, isError: isError))
      }
    }
  }

  /// One line to stdout; a closed pipe is ignored.
  static func send(_ line: String) {
    output.sync {
      let bytes = Array((line + "\n").utf8)
      var offset = 0
      while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { return }
        offset += written
      }
    }
  }

  /// A tool's text, and whether it is an error.
  static func carryOut(_ call: AutomationMCPCall, library: AutomationLibrary, socket: String) -> (String, Bool) {
    switch call {
    case .search(let query, let limit):
      return (search(library, query: query, limit: limit), false)
    case .get(let id, let file):
      return get(library, id: id, file: file)
    case .events:
      return (AutomationEvents.markdown(), false)
    case .save(let id, let files, let delete, let from):
      return save(library, id: id, files: files, delete: delete, from: from)
    case .run(let id, let inputs, let wait):
      // Longer than the wait limit: the engine's own answer ("still running") comes before this runs out.
      return answer(AutomationSocket.send(.run(id: id, inputs: inputs, wait: wait), path: socket,
                                          timeout: wait ? AutomationMCP.waitLimit + 30 : quickTimeout))
    case .runs(let id, let run, let limit):
      return answer(AutomationSocket.send(.runs(id: id, run: run, limit: limit), path: socket,
                                          timeout: listTimeout))
    }
  }

  static func answer(_ response: AutomationSocketResponse) -> (String, Bool) {
    switch response {
    case .ok(let value): return (value.json, false)
    case .failed(let reason): return (reason, true)
    }
  }

  /// The valid automations, ranked; broken ones are left out.
  static func search(_ library: AutomationLibrary, query: String, limit: Int) -> String {
    let calls = library.calls()
    let approvals = library.loadApprovals()
    var entries: [AutomationSearchEntry] = []
    for id in library.ids() {
      let loaded = library.load(id, calls: calls)
      guard let manifest = loaded.manifest, loaded.problems.isEmpty else { continue }
      entries.append(AutomationSearchEntry(manifest: manifest, readme: loaded.readme))
    }
    let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.manifest.id, $0.manifest) })
    let listings = AutomationSearch.rank(query, in: entries, limit: limit).compactMap { hit -> AutomationValue? in
      guard let manifest = byID[hit.id] else { return nil }
      return AutomationMCPText.listing(manifest, enabled: approvals.record(hit.id).enabled,
                                       approved: approvals.status(of: manifest).isApproved)
    }
    return AutomationMCPText.search(listings, query: query)
  }

  static func get(_ library: AutomationLibrary, id: String, file: String?) -> (String, Bool) {
    guard library.ids().contains(id) else { return (AutomationMCPText.notFound(id), true) }
    let files = library.files(id)
    if let file {
      guard let text = files[file] else {
        return ("`\(file)` isn't a file of \(id). Its files: \(files.keys.sorted().joined(separator: ", ")).", true)
      }
      return (text, false)
    }
    return (AutomationMCPText.package(manifest: files[AutomationManifest.fileName] ?? "(missing)",
                                      readme: files["README.md"] ?? "", files: Array(files.keys)), false)
  }

  /// The same save as Studio's (validation, path checks, symlink refusal, version bump, commit). Never approves.
  static func save(_ library: AutomationLibrary, id: String, files: [String: String], delete: [String],
                   from: String?) -> (String, Bool) {
    var merged: [String: String] = [:]
    var skipped: [String] = []
    if let from, !from.isEmpty {
      switch AutomationDraftFolder.read(from, id: id, library: library.root) {
      case .failure(let refusal): return (refusal.message, true)
      case .success(let found):
        merged = found.files
        skipped = found.skipped
      }
    }
    merged.merge(files) { $1 }
    switch library.save(id, files: merged, delete: delete) {
    case .failure(let error):
      if case .problems = error { return ("Nothing was saved. Fix these, then save again:\n" + error.message, true) }
      return (error.message, true)
    case .success(let saved):
      let approval = saved.manifest.map { library.loadApprovals().status(of: $0) } ?? .never
      var text = AutomationMCPText.saved(id: id, name: saved.manifest?.name ?? id, version: saved.version,
                                         commit: saved.commit, approval: approval)
      if !skipped.isEmpty {
        let shown = skipped.prefix(10).joined(separator: ", ") + (skipped.count > 10 ? ", and more" : "")
        text += " Hidden files in the draft were left out: \(shown)."
      }
      return (text, false)
    }
  }
}

/// Reads the package out of a draft folder for `automation_save`'s `from`. Only `<library>/.drafts/<id>` qualifies
/// (checked after symbolic links resolve), and it must hold that automation's automation.json. Then the checks a
/// save's own `files` get: every path is a package path (no `..`, no leading `/`; hidden files are left out and
/// named), no symbolic links anywhere, only regular UTF-8 text files, and the size caps of `AutomationMCP`.
enum AutomationDraftFolder {
  static let maxDepth = 16
  /// openat's "no component of the path may be a symbolic link" (macOS 11+).
  static let noFollowAny: Int32 = 0x2000_0000

  struct Found {
    var files: [String: String]
    /// Hidden files and folders left out, as relative paths.
    var skipped: [String]
  }

  static func refusal(_ id: String) -> AutomationMCPArgumentError {
    AutomationMCPArgumentError("`from` must be a draft folder in <library>/.drafts/\(id) holding that automation's "
                                 + "automation.json.")
  }

  /// Where a relative `from` starts: the library's own folder, never the server's working directory.
  static func resolve(_ from: String, library: URL) -> String? {
    let expanded = (from as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return expanded }
    guard !expanded.split(separator: "/").contains("..") else { return nil }
    return library.path + "/" + expanded
  }

  static func read(_ from: String, id: String, library: URL) -> Result<Found, AutomationMCPArgumentError> {
    guard let path = resolve(from, library: library) else { return .failure(refusal(id)) }
    // The drafts folder is a real folder of the library; the draft is a real folder strictly inside it.
    var info = stat()
    let drafts = library.path + "/" + AutomationCommands.draftsFolder
    guard lstat(drafts, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
          let draftsReal = realPath(drafts) else { return .failure(refusal(id)) }
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
          let base = realPath(path), base.hasPrefix(draftsReal + "/") else { return .failure(refusal(id)) }
    var found = Found(files: [:], skipped: [])
    var total = 0
    if let problem = walk(base, relative: "", depth: 0, found: &found, total: &total) {
      return .failure(AutomationMCPArgumentError(problem))
    }
    guard let manifest = found.files[AutomationManifest.fileName],
          case .string(let named)? = AutomationValue.decode(Data(manifest.utf8))?.object?["id"], named == id else {
      return .failure(refusal(id))
    }
    return .success(found)
  }

  static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// Fills `found` with the folder's files; returns why not when something is refused.
  private static func walk(_ folder: String, relative: String, depth: Int, found: inout Found,
                           total: inout Int) -> String? {
    guard depth <= maxDepth else { return "`\(relative)` is nested too deeply (at most \(maxDepth) folders)." }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
      return "`\(relative.isEmpty ? folder : relative)` can't be read."
    }
    for name in names.sorted() {
      let path = folder + "/" + name
      let shown = relative.isEmpty ? name : relative + "/" + name
      if name.hasPrefix(".") {
        found.skipped.append(shown)
        continue
      }
      if let problem = AutomationSave.pathProblem(shown) { return "\(shown) \(problem.message)" }
      var info = stat()
      guard lstat(path, &info) == 0 else { return "`\(shown)` can't be read." }
      switch info.st_mode & S_IFMT {
      case S_IFLNK:
        return "`\(shown)` is a symbolic link; a save reads real files only. Copy the file instead."
      case S_IFDIR:
        if let refusal = walk(path, relative: shown, depth: depth + 1, found: &found, total: &total) {
          return refusal
        }
      case S_IFREG:
        guard found.files.count < AutomationMCP.maxPaths else {
          return "The folder holds too many files: at most \(AutomationMCP.maxPaths) in one save."
        }
        switch text(of: path, shown: shown) {
        case .failure(let refusal): return refusal.message
        case .success(let content):
          total += content.utf8.count
          guard total <= AutomationMCP.maxFilesBytes else {
            return "The folder's files are too large: at most \(AutomationMCP.maxFilesBytes / 1_000_000) MB together."
          }
          found.files[shown] = content
        }
      default:
        return "`\(shown)` isn't a regular file."
      }
    }
    return nil
  }

  /// A regular file's text. Opened with no symbolic link allowed anywhere in the path (`path` is already resolved).
  private static func text(of path: String, shown: String) -> Result<String, AutomationMCPArgumentError> {
    let descriptor = open(path, O_RDONLY | noFollowAny | O_NONBLOCK)
    guard descriptor >= 0 else {
      return .failure(AutomationMCPArgumentError("`\(shown)` can't be read (is it a symbolic link?)."))
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      return .failure(AutomationMCPArgumentError("`\(shown)` isn't a regular file."))
    }
    guard info.st_size <= AutomationMCP.maxFileBytes else {
      return .failure(AutomationMCPArgumentError(
        "`\(shown)` is too large: at most \(AutomationMCP.maxFileBytes / 1_000_000) MB a file."))
    }
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while data.count <= AutomationMCP.maxFileBytes {
      let count = Darwin.read(descriptor, &chunk, chunk.count)
      if count < 0, errno == EINTR { continue }
      if count <= 0 { break }
      data.append(contentsOf: chunk[0..<count])
    }
    guard data.count <= AutomationMCP.maxFileBytes else {
      return .failure(AutomationMCPArgumentError(
        "`\(shown)` is too large: at most \(AutomationMCP.maxFileBytes / 1_000_000) MB a file."))
    }
    guard let text = String(data: data, encoding: .utf8) else {
      return .failure(AutomationMCPArgumentError("`\(shown)` isn't UTF-8 text; a package holds text files only."))
    }
    return .success(text)
  }
}
