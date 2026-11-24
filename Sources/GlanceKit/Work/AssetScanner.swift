import Foundation
import GlanceCore

/// Finds the media a session's worktree holds for the Assets section (spec §2.5): what the branch added or changed
/// ("On the branch"), what test runs left behind ("Test runs"), and what the project's setup names (`assets`).
///
/// "Found, not configured": test output is found by looking, never by a list the user keeps. The look is bounded because
/// it runs in Studio on a repository of any size, and it never runs from a hook: it never follows a symlink, never enters
/// `node_modules`, `.git` or a hidden folder, lists at most `maxItems` per group (newest first), and gives up after one
/// overall time limit, or when the calling task is cancelled.
///
/// Test output is never starved by a big tree. It is looked for first, in its own small walk (folders up to three deep
/// named `test-results` / `playwright-report`, plus what `playwright.config.*` and `cypress.config.*` name), and each
/// folder found is read with its own `maxEntries` budget. Only the search for files a setup glob names shares the
/// general budget, and a glob match in a huge tree can be missed; test output cannot.
public struct AssetScanner {
  public static let maxItems = 200
  public static let maxEntries = 5_000
  public static let defaultTimeLimit: TimeInterval = 10

  /// Test-output folders found by name, this many folders deep (`apps/web/test-results` is three).
  private static let outputFolderNames: Set<String> = ["test-results", "playwright-report"]
  private static let outputFolderDepth = 3
  /// The look for output folders and configs reads at most this many folders.
  private static let maxLocatorFolders = 2_000
  private static let maxOutputFolders = 50
  private static let skippedFolders: Set<String> = ["node_modules"]
  private static let maxDepth = 12
  private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v"]
  /// Hashing reads the whole file (to tell a found file from a capture of it), so a recording this large isn't hashed.
  private static let maxHashedBytes: Int64 = 64 << 20

  /// The media in `cwd`'s worktree, `branch` group first, then `testRun`; a file is listed once, under the first group
  /// that claims it. Nothing when `cwd` isn't in a git worktree, or when the scan is cancelled. A nil base, or one git
  /// can't diff against, hides the branch group's diff part and is not an error.
  ///
  /// `timeLimit` is the whole scan's, including finding the worktree: what is not done by then is left out.
  ///
  /// - Parameters:
  ///   - base: the branch the work is compared with (`RepoBase.find`).
  ///   - patterns: the project setup's `assets` globs, matched against paths relative to the worktree root. The files
  ///     they match are "On the branch".
  public static func scanFolder(cwd: String, base: String?, patterns: [String],
                                timeLimit: TimeInterval = defaultTimeLimit) async -> [AssetItem] {
    await run(cwd: cwd, base: base, patterns: patterns, timeLimit: timeLimit)
  }

  /// Where scans run: threads of the scanner's own. A utility-QoS global queue is not served while the cooperative pool
  /// is blocked (av-hang-report.md), and a scan that never starts would never answer.
  static let scanQueue = DispatchQueue(label: "dev.glance.assets.scan", qos: .userInitiated, attributes: .concurrent)
  /// How long past its time limit a scan may take to get a thread before it is given up on.
  static let startGrace: TimeInterval = 5

  /// `scanFolder` with the hash cache, the diff-output limit, the queue and the start grace as parameters (tests use
  /// their own).
  ///
  /// The wait is bounded: the time limit covers the scan once it runs, and `startGrace` more covers getting a thread. A
  /// scan that has not started by then answers with nothing, and the one still queued finds itself cancelled.
  static func run(cwd: String, base: String?, patterns: [String], timeLimit: TimeInterval = defaultTimeLimit,
                  hashes: HashCache = .shared, diffLimit: Int = 8 << 20, queue: DispatchQueue = scanQueue,
                  startGrace: TimeInterval = startGrace) async -> [AssetItem] {
    let budget = Budget(limit: timeLimit) // the clock starts here, before any git
    // On a dispatch thread of its own: the scan waits on git and on the disk, and must not hold a thread of Swift's
    // cooperative pool while it does.
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let answer = Once { continuation.resume(returning: $0) }
        queue.async {
          guard answer.start() else { return } // given up on while queued: it does not run late
          answer.send(scan(cwd: cwd, base: base, patterns: patterns, budget: budget, hashes: hashes, diffLimit: diffLimit))
        }
        timeouts.asyncAfter(deadline: .now() + max(0, timeLimit) + startGrace) { answer.giveUpIfNotStarted() }
      }
    } onCancel: {
      budget.cancel()
    }
  }

  /// Answers once. A scan that has begun is left to finish (its own limits bound it, and two must never overlap); one that
  /// has not begun when the time is up answers with nothing and never runs.
  final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var sent = false
    private let deliver: ([AssetItem]) -> Void
    init(_ deliver: @escaping ([AssetItem]) -> Void) { self.deliver = deliver }

    /// False when the time ran out before this thread came: do not run.
    func start() -> Bool { lock.lock(); defer { lock.unlock() }; if sent { return false }; started = true; return true }

    func send(_ items: [AssetItem]) {
      lock.lock(); let first = !sent; sent = true; lock.unlock()
      if first { deliver(items) }
    }

    func giveUpIfNotStarted() {
      lock.lock(); let give = !started && !sent; if give { sent = true }; lock.unlock()
      if give { deliver([]) }
    }
  }

  static let timeouts = DispatchQueue(label: "dev.glance.assets.timeouts")

  /// The scan's deadline and its cancellation, shared with the git processes so either can stop them.
  final class Budget: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: Date
    private let now: @Sendable () -> Date
    private var cancelled = false
    private var stop: (() -> Void)?

    /// `now` is the clock the deadline is read against; tests move their own.
    init(limit: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
      self.now = now
      deadline = now().addingTimeInterval(limit)
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var remaining: TimeInterval { deadline.timeIntervalSince(now()) }
    var expired: Bool { isCancelled || remaining <= 0 }

    func cancel() {
      lock.lock(); cancelled = true; let stop = stop; lock.unlock()
      stop?()
    }

    /// What to call to stop the git process now running; false when the scan is already cancelled.
    func running(_ stop: (() -> Void)?) -> Bool {
      lock.lock(); defer { lock.unlock() }
      self.stop = stop
      return !cancelled
    }
  }

  // MARK: - The scan

  private struct Found {
    let rel: String
    let url: URL
    let modified: Date?
    let bytes: Int64?
  }

  static func scan(cwd: String, base: String?, patterns: [String], budget: Budget, hashes: HashCache, diffLimit: Int) -> [AssetItem] {
    guard let root = worktreeRoot(cwd: cwd, budget: budget) else { return [] }
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)

    var claimed = Set<String>()
    var branch: [Found] = []
    for found in changedMedia(root: rootURL, base: base, budget: budget, limit: diffLimit) where claimed.insert(found.rel).inserted {
      branch.append(found)
    }

    // Test output first, each folder with its own budget.
    let located = locate(root: rootURL, budget: budget)
    var named = located.named
    for config in located.configs { named.formUnion(configuredFolders(config, root: rootURL)) }
    let outputFolders = outermost(named.filter { realFolder($0, root: rootURL) }).prefix(maxOutputFolders)
    var testRuns: [Found] = []
    for folder in outputFolders where !budget.expired {
      walk(root: rootURL, from: folder, entryLimit: maxEntries, folderLimit: .max, maxDepth: maxDepth, budget: budget,
           folder: { _, _, _ in true },
           file: { rel, name, url, values in
             if isMedia(name), claimed.insert(rel).inserted { testRuns.append(found(rel, url, values)) }
           })
    }

    // Files a setup glob names share what is left of the general walk.
    if !patterns.isEmpty {
      let skipped = Set(outputFolders)
      walk(root: rootURL, from: "", entryLimit: maxEntries, folderLimit: .max, maxDepth: maxDepth, budget: budget,
           folder: { rel, _, _ in !skipped.contains(rel) },
           file: { rel, name, url, values in
             if isMedia(name), patterns.contains(where: { AssetGlob.matches($0, path: rel) }), claimed.insert(rel).inserted {
               branch.append(found(rel, url, values))
             }
           })
    }

    if budget.isCancelled { return [] }
    return items(from: newest(branch), group: .branch, budget: budget, hashes: hashes)
      + items(from: newest(testRuns), group: .testRun, budget: budget, hashes: hashes)
  }

  private static func found(_ rel: String, _ url: URL, _ values: URLResourceValues) -> Found {
    Found(rel: rel, url: url, modified: values.contentModificationDate, bytes: values.fileSize.map(Int64.init))
  }

  /// The worktree's top folder, from git, inside the scan's time.
  static func worktreeRoot(cwd: String, budget: Budget) -> String? {
    guard let out = git(cwd, ["rev-parse", "--show-toplevel"], timeout: 10, budget: budget) else { return nil }
    let top = String(decoding: out.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return top.isEmpty ? nil : top
  }

  // MARK: - On the branch

  /// Media the branch added or changed since `base`. Paths come relative to the worktree root, whichever folder git ran in.
  /// The cap applies to media paths, not to every path the diff names; output over `limit` bytes keeps what came before it.
  private static func changedMedia(root: URL, base: String?, budget: Budget, limit: Int) -> [Found] {
    guard let base, usable(base), !budget.expired,
          git(root.path, ["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], timeout: 10, budget: budget) != nil,
          let out = git(root.path, ["diff", "--name-only", "-z", "--diff-filter=d", "--no-ext-diff", "--no-textconv",
                                    "\(base)...HEAD", "--"], timeout: 15, budget: budget, limit: limit) else { return [] }
    var names = out.data.split(separator: 0, omittingEmptySubsequences: true)
    // Cut off at the limit: the last name may be half of one.
    if out.truncated, out.data.last != 0 { names = Array(names.dropLast()) }
    let resolvedRoot = root.resolvingSymlinksInPath().path
    var found: [Found] = []
    for raw in names {
      if budget.expired || found.count >= maxEntries { break }
      let rel = String(decoding: raw, as: UTF8.self)
      guard isMedia(rel), safe(rel) else { continue }
      let url = root.appendingPathComponent(rel)
      guard let file = regularFile(url, rel: rel),
            url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot + "/") else { continue } // a symlinked parent can lead out
      found.append(file)
    }
    return found
  }

  /// A name git could take for an option, or something that isn't a branch, is not a base.
  private static func usable(_ base: String) -> Bool {
    !base.isEmpty && !base.hasPrefix("-") && !base.contains(where: { $0.isWhitespace || $0.isNewline })
  }

  // MARK: - Finding test output

  private struct Located {
    var named: Set<String> = []
    var configs: [String] = []
  }

  /// The shallow look: folders named like test output and test configs, up to three folders deep.
  private static func locate(root: URL, budget: Budget) -> Located {
    var result = Located()
    walk(root: root, from: "", entryLimit: .max, folderLimit: maxLocatorFolders, maxDepth: outputFolderDepth, budget: budget,
         folder: { rel, name, depth in
           if outputFolderNames.contains(name), depth <= outputFolderDepth { result.named.insert(rel); return false }
           return true
         },
         file: { rel, name, _, _ in
           if isTestConfig(name) { result.configs.append(rel) }
         })
    return result
  }

  private static func isTestConfig(_ name: String) -> Bool {
    for prefix in ["playwright.config.", "cypress.config."] where name.hasPrefix(prefix) {
      return ["ts", "js", "mjs", "cjs", "mts", "cts"].contains(String(name.dropFirst(prefix.count)))
    }
    return false
  }

  /// The folders a test config names, as paths relative to the worktree root. A config's folders sit beside it; one that
  /// points out of the worktree (`..`, an absolute path, `~`) names nothing. Cypress writes to `cypress/videos` and
  /// `cypress/screenshots` unless told otherwise (a setting naming only one of them leaves the other's default, so both
  /// defaults are always looked in).
  private static func configuredFolders(_ configRel: String, root: URL) -> Set<String> {
    guard let handle = try? FileHandle(forReadingFrom: root.appendingPathComponent(configRel)) else { return [] }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: TestOutputConfig.readLimit)) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    let parts = configRel.split(separator: "/").map(String.init)
    let beside = Array(parts.dropLast())
    var named = TestOutputConfig.folders(inConfig: text)
    if parts.last?.hasPrefix("cypress.") == true { named += ["cypress/videos", "cypress/screenshots"] }
    var folders = Set<String>()
    for value in named {
      guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("\0"), !value.contains("\\") else { continue }
      let inner = value.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
      guard !inner.isEmpty, !inner.contains("..") else { continue }
      folders.insert((beside + inner).joined(separator: "/"))
    }
    return folders
  }

  /// A folder that exists, with no symlink, hidden or dependency folder anywhere on its path (a config can name any path).
  private static func realFolder(_ rel: String, root: URL) -> Bool {
    var url = root
    for part in rel.split(separator: "/") {
      if part.hasPrefix(".") || skippedFolders.contains(String(part)) { return false }
      url.appendPathComponent(String(part), isDirectory: true)
      guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
            values.isSymbolicLink != true, values.isDirectory == true else { return false }
    }
    return true
  }

  /// Without the folders inside another in the set (their files are read with the outer one), in a stable order.
  private static func outermost(_ folders: Set<String>) -> [String] {
    folders.sorted().filter { folder in !folders.contains { $0 != folder && folder.hasPrefix($0 + "/") } }
  }

  // MARK: - Walking

  /// Breadth first from `start` (a folder relative to `root`; "" is the root), shallow folders before deep ones. Stops at
  /// `entryLimit` entries seen (every name counts, the skipped ones too), `folderLimit` folders listed, `maxDepth`, or
  /// the budget. Symlinks, hidden names and `node_modules` are never reported. `folder` answers whether to go into a
  /// folder (given its path, name and depth); `file` sees each regular file.
  private static func walk(root: URL, from start: String, entryLimit: Int, folderLimit: Int, maxDepth: Int, budget: Budget,
                           folder: (String, String, Int) -> Bool, file: (String, String, URL, URLResourceValues) -> Void) {
    let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
    var queue: [(rel: String, depth: Int)] = [(start, 0)]
    var next = 0, entries = 0
    while next < queue.count, next < folderLimit, !budget.expired {
      let (rel, depth) = queue[next]
      next += 1
      let url = rel.isEmpty ? root : root.appendingPathComponent(rel, isDirectory: true)
      guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else { continue }
      for child in children {
        entries += 1
        if entries > entryLimit || budget.expired { return }
        let name = child.lastPathComponent
        if name.hasPrefix(".") || skippedFolders.contains(name) { continue }
        guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
        let childRel = rel.isEmpty ? name : rel + "/" + name
        if values.isDirectory == true {
          if depth + 1 <= maxDepth, folder(childRel, name, depth + 1) { queue.append((childRel, depth + 1)) }
        } else if values.isRegularFile == true {
          file(childRel, name, child, values)
        }
      }
    }
  }

  // MARK: - Items

  /// Newest first, the name settling ties, at most `maxItems`.
  private static func newest(_ files: [Found]) -> [Found] {
    let sorted = files.sorted {
      let a = $0.modified ?? .distantPast, b = $1.modified ?? .distantPast
      return a == b ? $0.rel < $1.rel : a > b
    }
    return Array(sorted.prefix(maxItems))
  }

  private static func items(from files: [Found], group: AssetItem.Group, budget: Budget, hashes: HashCache) -> [AssetItem] {
    files.map { file in
      let ext = (file.rel as NSString).pathExtension.lowercased()
      let hashable = (file.bytes ?? 0) <= maxHashedBytes && !budget.expired
      return AssetItem(id: "found:\(group.rawValue):\(file.rel)", group: group,
                       kind: videoExtensions.contains(ext) ? .video : .image,
                       name: (file.rel as NSString).lastPathComponent, path: file.rel, file: file.url,
                       at: file.modified, bytes: file.bytes,
                       sha256: hashable ? hashes.hash(of: file.url, modified: file.modified, bytes: file.bytes) : nil)
    }
  }

  private static func isMedia(_ name: String) -> Bool {
    AssetGroups.mediaExtensions.contains((name as NSString).pathExtension.lowercased())
  }

  /// Not absolute, no `..`: a path git printed is inside the tree, and this holds if that were ever not so.
  private static func safe(_ rel: String) -> Bool {
    !rel.hasPrefix("/") && !rel.contains("\0") && !rel.split(separator: "/").contains("..")
  }

  /// The file when it is a regular file (a symlink, committed or not, could point anywhere); nil when it is gone.
  private static func regularFile(_ url: URL, rel: String) -> Found? {
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
    guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true, values.isRegularFile == true else { return nil }
    return found(rel, url, values)
  }

  // MARK: - git

  private struct GitOutput {
    let data: Data
    /// Output stopped at the limit: what is here is a true beginning of it.
    let truncated: Bool
  }

  /// `/usr/bin/git -C folder …`: its output, nil when git fails, runs out of time, or the scan is cancelled (git is
  /// terminated then). Output over `limit` bytes is cut there, not failed. (GlanceCore's own runner isn't public.) Waiting
  /// uses a semaphore, so no run loop is needed on this background thread.
  private static func git(_ folder: String, _ arguments: [String], timeout: TimeInterval, budget: Budget, limit: Int = 1 << 20) -> GitOutput? {
    let allowed = min(timeout, budget.remaining)
    guard allowed > 0, !budget.isCancelled else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", folder] + arguments
    process.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0", "GIT_LITERAL_PATHSPECS": "1"]) { _, ours in ours }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    let stopped = Flag()
    let terminate = { if process.isRunning { stopped.set(); process.terminate() } }
    guard budget.running(terminate) else { return nil }
    defer { _ = budget.running(nil) }
    do { try process.run() } catch { return nil }
    let killer = DispatchWorkItem(block: terminate)
    DispatchQueue.global().asyncAfter(deadline: .now() + allowed, execute: killer)
    var data = Data()
    var cut = false
    while let chunk = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
      data.append(chunk)
      if data.count > limit { data = data.prefix(limit); cut = true; process.terminate(); break }
    }
    exited.wait()
    killer.cancel()
    if cut { return GitOutput(data: data, truncated: true) }
    return process.terminationStatus == 0 && !stopped.value ? GitOutput(data: data, truncated: false) : nil
  }

  private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
  }
}

/// SHA-256 of found files, remembered by (path, modified time, size) so a rescan reads only what changed. Kept in memory
/// and bounded: past `limit` entries it starts over rather than grow.
final class HashCache: @unchecked Sendable {
  static let shared = HashCache()

  private struct Key: Hashable {
    let path: String
    let modified: Double
    let bytes: Int64
  }

  private let lock = NSLock()
  private var known: [Key: String] = [:]
  private let limit: Int
  private let hasher: @Sendable (URL) -> String?

  init(limit: Int = 2_000, hasher: @escaping @Sendable (URL) -> String? = { WorkStore.sha256(of: $0) }) {
    self.limit = max(1, limit)
    self.hasher = hasher
  }

  var count: Int { lock.lock(); defer { lock.unlock() }; return known.count }

  /// The hash of `file`; nil when it can't be read. Without a modified time and size there is nothing to key on, and the
  /// file is read every time.
  func hash(of file: URL, modified: Date?, bytes: Int64?) -> String? {
    guard let modified, let bytes else { return hasher(file) }
    let key = Key(path: file.path, modified: modified.timeIntervalSinceReferenceDate, bytes: bytes)
    lock.lock(); let cached = known[key]; lock.unlock()
    if let cached { return cached }
    guard let digest = hasher(file) else { return nil }
    lock.lock()
    if known.count >= limit { known.removeAll() }
    known[key] = digest
    lock.unlock()
    return digest
  }
}
