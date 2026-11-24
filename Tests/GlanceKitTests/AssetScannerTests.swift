import Foundation
import GlanceCore
import Testing
@testable import GlanceKit

// The Assets scan against real temporary repositories: nothing here touches the user's own folders.

private final class Repo {
  let root: URL
  let outside: URL

  init() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scan-" + UUID().uuidString)
    root = base.appendingPathComponent("repo")
    outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    git("init", "-q", "-b", "main")
    git("config", "user.email", "t@example.com")
    git("config", "user.name", "T")
    git("config", "core.quotepath", "true")
  }

  deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

  var path: String { root.path }

  @discardableResult
  func git(_ args: String...) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", root.path] + args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }

  func write(_ rel: String, _ text: String = "x", in folder: URL? = nil) {
    let url = (folder ?? root).appendingPathComponent(rel)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
  }

  func commit(_ message: String) {
    git("add", "-A")
    git("commit", "-q", "-m", message)
  }

  /// A base commit on main, then `feature` with whatever `change` adds.
  func branchOffMain(_ change: () -> Void) {
    write("README.md", "hello")
    commit("base")
    git("checkout", "-q", "-b", "feature")
    change()
    commit("feature work")
  }
}

private func paths(_ items: [AssetItem], _ group: AssetItem.Group) -> [String] {
  items.filter { $0.group == group }.map(\.path).sorted()
}

@Suite struct AssetScannerTests {
  @Test func branchMediaIsWhatTheBranchAddedOrChanged() async throws {
    let repo = try Repo()
    repo.write("docs/old.png")
    repo.branchOffMain {
      repo.write("docs/new.png"); repo.write("clip.mp4"); repo.write("notes.txt"); repo.write("src/app.swift")
    }
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: "main", patterns: [])
    #expect(paths(items, .branch) == ["clip.mp4", "docs/new.png"])
    let png = try #require(items.first { $0.path == "docs/new.png" })
    #expect(png.kind == .image && png.name == "new.png" && png.failed == false)
    #expect(png.file?.resolvingSymlinksInPath().path == repo.root.appendingPathComponent("docs/new.png").resolvingSymlinksInPath().path)
    #expect(png.bytes == 1 && png.sha256?.count == 64)
    #expect(items.first { $0.path == "clip.mp4" }?.kind == .video)
  }

  @Test func aNonAsciiPathComesBackWhole() async throws {
    let repo = try Repo()
    repo.branchOffMain { repo.write("docs/café ☕ screen.png") }
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: "main", patterns: [])
    #expect(paths(items, .branch) == ["docs/café ☕ screen.png"])
    #expect(items.first?.file.map { FileManager.default.fileExists(atPath: $0.path) } == true)
  }

  @Test func aDeletedFileIsNotListed() async throws {
    let repo = try Repo()
    repo.write("gone.png")
    repo.branchOffMain {
      try? FileManager.default.removeItem(at: repo.root.appendingPathComponent("gone.png")); repo.write("kept.png")
    }
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: "main", patterns: [])
    #expect(paths(items, .branch) == ["kept.png"])
  }

  @Test func theWorktreeRootDecidesNotTheFolderItWasAskedFrom() async throws {
    let repo = try Repo()
    repo.branchOffMain { repo.write("docs/new.png"); repo.write("apps/web/inner.png") }
    // `git diff --name-only` paths are relative to the worktree root, so a session in a sub-folder still finds them.
    let items = await AssetScanner.scanFolder(cwd: repo.root.appendingPathComponent("apps/web").path, base: "main", patterns: [])
    #expect(paths(items, .branch) == ["apps/web/inner.png", "docs/new.png"])
  }

  @Test func aMissingOrBrokenBaseHidesTheBranchGroupWithoutAnError() async throws {
    let repo = try Repo()
    repo.branchOffMain { repo.write("docs/new.png") }
    repo.write("test-results/run.png")
    for base in [nil, "no-such-branch", "", "--output=/tmp/x", "main ", "a b"] as [String?] {
      let items = await AssetScanner.scanFolder(cwd: repo.path, base: base, patterns: [])
      #expect(paths(items, .branch).isEmpty, "base \(String(describing: base))")
      #expect(paths(items, .testRun) == ["test-results/run.png"])
    }
  }

  @Test func testResultsAtTheRootAndInAMonorepoPackage() async throws {
    let repo = try Repo()
    repo.write("test-results/a/shot.png"); repo.write("test-results/a/video.webm"); repo.write("test-results/a/trace.zip")
    repo.write("apps/web/test-results/b.png")
    repo.write("apps/web/playwright-report/data/c.png")
    repo.write("packages/ui/deep/er/too/test-results/d.png") // deeper than the look goes
    repo.write("src/logo.png") // not test output, and not on a branch
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: [])
    #expect(paths(items, .testRun) == ["apps/web/playwright-report/data/c.png", "apps/web/test-results/b.png",
                                       "test-results/a/shot.png", "test-results/a/video.webm"])
    #expect(items.allSatisfy { $0.group == .testRun })
    #expect(items.first { $0.path.hasSuffix("video.webm") }?.kind == .video)
  }

  @Test func aPlaywrightOutputDirIsFound() async throws {
    let repo = try Repo()
    repo.write("playwright.config.ts", """
    import { defineConfig } from '@playwright/test';
    export default defineConfig({ outputDir: './e2e-artifacts' });
    """)
    repo.write("e2e-artifacts/run/screen.png")
    repo.write("elsewhere/screen.png")
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: [])
    #expect(paths(items, .testRun) == ["e2e-artifacts/run/screen.png"])
  }

  @Test func aPackagesConfigNamesFoldersBesideItself() async throws {
    let repo = try Repo()
    repo.write("apps/web/playwright.config.js", "module.exports = { outputDir: 'artifacts' }")
    repo.write("apps/web/artifacts/a.png")
    repo.write("artifacts/not-this-one.png")
    repo.write("apps/admin/cypress.config.ts", "export default { videosFolder: 'tmp/v', screenshotsFolder: 'tmp/s' }")
    repo.write("apps/admin/tmp/v/run.mp4"); repo.write("apps/admin/tmp/s/shot.png")
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: [])
    #expect(paths(items, .testRun) == ["apps/admin/tmp/s/shot.png", "apps/admin/tmp/v/run.mp4", "apps/web/artifacts/a.png"])
  }

  @Test func aConfigCannotPointOutOfTheRepository() async throws {
    let repo = try Repo()
    repo.write("secret.png", "s", in: repo.outside)
    repo.write("playwright.config.ts", "export default { outputDir: '../outside' }")
    repo.write("cypress.config.ts", "export default { videosFolder: '/etc', screenshotsFolder: '~/Pictures' }")
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: [])
    #expect(items.isEmpty)
  }

  @Test func setupAssetPatternsWalkTheWorktreeAndListUnderTheBranch() async throws {
    let repo = try Repo()
    repo.write("docs/screens/login.png"); repo.write("docs/screens/web/deep.jpg"); repo.write("docs/screens/readme.md")
    repo.write("docs/other/skip.png")
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: ["docs/screens/**"])
    #expect(paths(items, .branch) == ["docs/screens/login.png", "docs/screens/web/deep.jpg"])
    #expect(items.count == 2)
  }

  @Test func patternsWalkTheSessionsWorktreeNotAnotherCheckout() async throws {
    let main = try Repo()
    main.write("docs/screens/main-only.png")
    let linked = try Repo()
    linked.write("docs/screens/linked-only.png")
    let items = await AssetScanner.scanFolder(cwd: linked.path, base: nil, patterns: ["docs/screens/**"])
    #expect(paths(items, .branch) == ["docs/screens/linked-only.png"])
  }

  @Test func aPatternThatReachesOutIsRefused() async throws {
    let repo = try Repo()
    repo.write("a.png", "s", in: repo.outside)
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: ["../outside/**", "/etc/**", "~/x/**"])
    #expect(items.isEmpty)
  }

  @Test func aSymlinkOutOfTheRepositoryIsNotFollowed() async throws {
    let repo = try Repo()
    repo.write("secret.png", "s", in: repo.outside)
    try FileManager.default.createSymbolicLink(at: repo.root.appendingPathComponent("test-results"), withDestinationURL: repo.outside)
    try FileManager.default.createDirectory(at: repo.root.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: repo.root.appendingPathComponent("docs/link.png"),
                                               withDestinationURL: repo.outside.appendingPathComponent("secret.png"))
    try FileManager.default.createSymbolicLink(at: repo.root.appendingPathComponent("docs/dir"), withDestinationURL: repo.outside)
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: ["docs/**"])
    #expect(items.isEmpty)
  }

  @Test func aCommittedSymlinkIsNotListedFromTheDiff() async throws {
    let repo = try Repo()
    repo.write("secret.png", "s", in: repo.outside)
    repo.branchOffMain {
      try? FileManager.default.createSymbolicLink(at: repo.root.appendingPathComponent("link.png"),
                                                  withDestinationURL: repo.outside.appendingPathComponent("secret.png"))
      repo.write("real.png")
    }
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: "main", patterns: [])
    #expect(paths(items, .branch) == ["real.png"])
  }

  @Test func dependenciesGitAndHiddenFoldersAreSkipped() async throws {
    let repo = try Repo()
    repo.write("node_modules/pkg/test-results/a.png"); repo.write("node_modules/logo.png")
    repo.write(".hidden/test-results/b.png"); repo.write(".cache/c.png")
    repo.write("web/node_modules/d.png"); repo.write("test-results/.partial/e.png")
    repo.write("test-results/ok.png")
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: ["**"])
    #expect(items.map(\.path).sorted() == ["test-results/ok.png"])
  }

  @Test func eachGroupStopsAt200ItemsNewestFirst() async throws {
    let repo = try Repo()
    for i in 0..<230 { repo.write("test-results/shot-\(String(format: "%03d", i)).png") }
    let old = Date(timeIntervalSince1970: 1_000_000)
    for i in 0..<30 {
      try FileManager.default.setAttributes([.modificationDate: old],
                                            ofItemAtPath: repo.root.appendingPathComponent("test-results/shot-\(String(format: "%03d", i)).png").path)
    }
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: [])
    #expect(items.count == 200)
    #expect(!items.contains { $0.at == old })
  }

  @Test func theWalkLooksAtMostAtFiveThousandEntries() async throws {
    let repo = try Repo()
    for i in 0..<5_600 { repo.write("bulk/f\(String(format: "%04d", i)).png") }
    repo.write("zzz/late.png")
    let started = Date()
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: ["**"])
    #expect(Date().timeIntervalSince(started) < 20)
    #expect(items.count == 200)
    // The newest file is the last one written; the walk ended before it, in the folder it never reached.
    #expect(!items.contains { $0.path == "zzz/late.png" })
  }

  @Test func anOutOfTimeScanAnswersWithWhatItHas() async throws {
    let repo = try Repo()
    repo.write("test-results/a.png")
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: [], timeLimit: 0)
    #expect(items.count <= 1)
  }

  @Test func aFolderThatIsNotARepositoryHasNothing() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("plain-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("test-results"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: folder.appendingPathComponent("test-results/a.png"))
    defer { try? FileManager.default.removeItem(at: folder) }
    let items = await AssetScanner.scanFolder(cwd: folder.path, base: "main", patterns: ["**"])
    #expect(items.isEmpty)
  }

  @Test func theSameFileIsListedOnceUnderTheFirstGroupThatClaimsIt() async throws {
    let repo = try Repo()
    repo.branchOffMain { repo.write("test-results/committed.png"); repo.write("docs/shot.png") }
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: "main", patterns: ["docs/**", "*.png"])
    #expect(items.map(\.path).sorted() == ["docs/shot.png", "test-results/committed.png"])
    #expect(items.allSatisfy { $0.group == .branch })
  }
}

// MARK: - Fix round 1

/// A hasher that counts the reads it is asked for.
private final class CountingHasher: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [String] = []
  private let delay: TimeInterval
  init(delay: TimeInterval = 0) { self.delay = delay }
  var reads: [String] { lock.lock(); defer { lock.unlock() }; return seen }
  var cache: HashCache {
    HashCache(limit: 100) { url in
      self.lock.lock(); self.seen.append(url.lastPathComponent); self.lock.unlock()
      if self.delay > 0 { Thread.sleep(forTimeInterval: self.delay) }
      return WorkStore.sha256(of: url)
    }
  }
}

@Suite struct AssetScannerFixRoundTests {
  @Test func testOutputIsFoundWhenMoreThanFiveThousandEarlierEntriesUseUpTheGeneralWalk() async throws {
    let repo = try Repo()
    for i in 0..<5_600 { repo.write("aaa/f\(String(format: "%04d", i)).txt") }
    for i in 0..<5_600 { repo.write("apps/aaa/f\(String(format: "%04d", i)).txt") }
    repo.write("apps/web/test-results/deep.png")
    repo.write("test-results/root.png")
    for patterns in [[], ["**"]] as [[String]] {
      let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: patterns)
      #expect(paths(items, .testRun) == ["apps/web/test-results/deep.png", "test-results/root.png"], "patterns \(patterns)")
    }
  }

  @Test func aBigOutputFolderDoesNotStarveAnother() async throws {
    let repo = try Repo()
    for i in 0..<5_600 { repo.write("test-results/f\(String(format: "%04d", i)).png") }
    repo.write("apps/web/test-results/other.png")
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: [])
    #expect(items.contains { $0.path == "apps/web/test-results/other.png" })
    #expect(items.count == 200)
  }

  @Test func aConfigNamedFolderBehindAHugeTreeIsStillRead() async throws {
    let repo = try Repo()
    for i in 0..<5_600 { repo.write("a-big/f\(String(format: "%04d", i)).txt") }
    repo.write("playwright.config.ts", "export default { outputDir: 'x/y/z/w/artifacts' }")
    repo.write("x/y/z/w/artifacts/shot.png")
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: nil, patterns: [])
    #expect(paths(items, .testRun) == ["x/y/z/w/artifacts/shot.png"])
  }

  @Test func anUnchangedFileIsNotReadAgainAndAChangedOneIs() async throws {
    let repo = try Repo()
    repo.write("test-results/a.png", "first"); repo.write("test-results/b.png", "second")
    let hasher = CountingHasher()
    let cache = hasher.cache
    let one = await AssetScanner.run(cwd: repo.path, base: nil, patterns: [], hashes: cache)
    #expect(hasher.reads.sorted() == ["a.png", "b.png"])
    let two = await AssetScanner.run(cwd: repo.path, base: nil, patterns: [], hashes: cache)
    #expect(hasher.reads.count == 2, "a second scan reads nothing that hasn't changed")
    #expect(one.map(\.sha256) == two.map(\.sha256) && one.allSatisfy { $0.sha256?.count == 64 })
    repo.write("test-results/a.png", "first, now longer")
    let three = await AssetScanner.run(cwd: repo.path, base: nil, patterns: [], hashes: cache)
    #expect(hasher.reads.sorted() == ["a.png", "a.png", "b.png"])
    #expect(three.first { $0.name == "a.png" }?.sha256 != one.first { $0.name == "a.png" }?.sha256)
  }

  @Test func theHashCacheIsBounded() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hc-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let hasher = CountingHasher()
    let cache = HashCache(limit: 3) { url in hasher.cache.hash(of: url, modified: nil, bytes: nil) }
    let when = Date(timeIntervalSince1970: 1_000)
    for i in 0..<10 {
      let url = folder.appendingPathComponent("f\(i).png")
      try Data("x\(i)".utf8).write(to: url)
      _ = cache.hash(of: url, modified: when, bytes: 2)
    }
    #expect(cache.count <= 3)
  }

  @Test func theDiffListIsCappedAfterFilteringToMedia() async throws {
    let repo = try Repo()
    repo.branchOffMain {
      for i in 0..<5_100 { repo.write("a/f\(String(format: "%04d", i)).txt") }
      repo.write("z-screens/late.png")
    }
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: "main", patterns: [])
    #expect(paths(items, .branch) == ["z-screens/late.png"])
  }

  @Test func aDiffOverTheOutputLimitKeepsWhatItFoundAndNoPartialPath() async throws {
    let repo = try Repo()
    let names = (0..<100).map { "docs/screens/shot-\(String(format: "%03d", $0))-padding-padding-padding.png" }
    repo.branchOffMain { names.forEach { repo.write($0) } }
    let items = await AssetScanner.run(cwd: repo.path, base: "main", patterns: [], diffLimit: 2_000)
    let found = items.map(\.path).sorted()
    #expect(found.count > 5 && found.count < 100)
    #expect(found == Array(names.prefix(found.count)))
  }

  @Test func aDiffPathThroughASymlinkedParentThatLeavesTheWorktreeIsSkipped() async throws {
    let repo = try Repo()
    repo.write("x.png", "outside", in: repo.outside)
    repo.branchOffMain { repo.write("docs/x.png"); repo.write("keep/y.png") }
    try FileManager.default.removeItem(at: repo.root.appendingPathComponent("docs"))
    try FileManager.default.createSymbolicLink(at: repo.root.appendingPathComponent("docs"), withDestinationURL: repo.outside)
    let items = await AssetScanner.scanFolder(cwd: repo.path, base: "main", patterns: [])
    #expect(paths(items, .branch) == ["keep/y.png"])
  }

  @Test func aCancelledScanReturnsNothing() async throws {
    let repo = try Repo()
    repo.write("test-results/a.png")
    let path = repo.path
    let task = Task { () -> [AssetItem] in
      while !Task.isCancelled { await Task.yield() }
      return await AssetScanner.scanFolder(cwd: path, base: nil, patterns: [])
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()
    #expect(await task.value.isEmpty)
  }

  /// A clock the test moves by hand: nothing here depends on how fast the machine is.
  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 2_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
  }

  @Test func hashingStopsAtTheDeadlineButTheItemsStayListed() throws {
    let repo = try Repo()
    for i in 0..<12 { repo.write("test-results/f\(String(format: "%02d", i)).png", "n\(i)") }
    let clock = Clock()
    var reads = 0
    let lock = NSLock()
    // Each file read costs one second of the scan's own clock, and nothing else moves it.
    let cache = HashCache(limit: 100) { url in
      lock.lock(); reads += 1; lock.unlock()
      clock.advance(1)
      return WorkStore.sha256(of: url)
    }
    let budget = AssetScanner.Budget(limit: 3, now: { clock.now })
    let items = AssetScanner.scan(cwd: repo.path, base: nil, patterns: [], budget: budget, hashes: cache, diffLimit: 8 << 20)
    #expect(items.count == 12, "the items stay listed")
    #expect(reads == 3, "hashing stops when the deadline is reached")
    #expect(items.filter { $0.sha256 != nil }.count == 3 && items.filter { $0.sha256 == nil }.count == 9)
  }

  @Test func theClockCoversFindingTheWorktreeToo() throws {
    let repo = try Repo()
    repo.write("test-results/a.png")
    let clock = Clock()
    // With time left the worktree is found; with none it is not looked for, so no git is waited on.
    #expect(AssetScanner.worktreeRoot(cwd: repo.path, budget: .init(limit: 60, now: { clock.now })) != nil)
    #expect(AssetScanner.worktreeRoot(cwd: repo.path, budget: .init(limit: 0, now: { clock.now })) == nil)
    let spent = AssetScanner.Budget(limit: 5, now: { clock.now })
    clock.advance(6)
    #expect(AssetScanner.worktreeRoot(cwd: repo.path, budget: spent) == nil, "a clock already spent covers finding the worktree")
    #expect(AssetScanner.scan(cwd: repo.path, base: nil, patterns: [], budget: spent, hashes: HashCache(), diffLimit: 8 << 20).isEmpty)
  }

  @Test func aScanThatNeverGetsAThreadStillReturns() async throws {
    let repo = try Repo()
    repo.write("test-results/a.png")
    // A queue that never runs what it is given: the starved pool, as far as the scan can tell.
    let stuck = DispatchQueue(label: "dev.glance.tests.stuck")
    stuck.suspend()
    defer { stuck.resume() }
    let started = Date()
    let items = await AssetScanner.run(cwd: repo.path, base: nil, patterns: [], timeLimit: 0.2, queue: stuck, startGrace: 0.2)
    #expect(items.isEmpty)
    #expect(Date().timeIntervalSince(started) < 30, "the wait for a thread is bounded by the time limit plus the grace")
  }

  @Test func aRecordingOverSixtyFourMegabytesIsListedButNotHashed() async throws {
    let repo = try Repo()
    repo.write("test-results/small.png", "s")
    let big = repo.root.appendingPathComponent("test-results/big.mp4")
    FileManager.default.createFile(atPath: big.path, contents: nil)
    let handle = try FileHandle(forWritingTo: big)
    try handle.truncate(atOffset: 65 << 20) // sparse: costs no disk
    try handle.close()
    let hasher = CountingHasher()
    let items = await AssetScanner.run(cwd: repo.path, base: nil, patterns: [], hashes: hasher.cache)
    let video = try #require(items.first { $0.name == "big.mp4" })
    #expect(video.bytes == 65 << 20 && video.sha256 == nil && video.kind == .video)
    #expect(hasher.reads == ["small.png"])
  }
}
