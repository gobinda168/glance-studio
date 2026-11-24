import Foundation
import GlanceCore
import Testing
@testable import GlanceKit

// The PR group of the Assets scan. The downloader and the body lookup are injected: nothing here touches the network or gh.

private final class Fixture: @unchecked Sendable {
  let root: URL
  let store: WorkStore
  let session = "11111111-2222-3333-4444-555555555555"
  let state = PRMediaState()
  private let lock = NSLock()
  private var downloaded: [(url: String, limit: Int64)] = []
  private var lookups = 0
  private var clock = Date(timeIntervalSince1970: 1_800_000_000)

  /// What the stand-in PR says: the texts and their updatedAt; what a download does for a URL.
  var texts: [String] = []
  var updatedAt = "2026-11-02T09:00:00Z"
  var lookupFails = false
  var failing: Set<String> = []

  init() {
    root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scanpr-" + UUID().uuidString, isDirectory: true)
    store = WorkStore(folder: root)
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  var prFolder: URL { store.cacheFolder(session: session).appendingPathComponent("pr", isDirectory: true) }
  var urlsDownloaded: [String] { lock.lock(); defer { lock.unlock() }; return downloaded.map(\.url) }
  var limitsSeen: [Int64] { lock.lock(); defer { lock.unlock() }; return downloaded.map(\.limit) }
  var bodyLookups: Int { lock.lock(); defer { lock.unlock() }; return lookups }
  var now: Date { lock.lock(); defer { lock.unlock() }; return clock }
  func advance(_ seconds: TimeInterval) { lock.lock(); clock = clock.addingTimeInterval(seconds); lock.unlock() }

  func info(updatedAt: String? = nil) -> ProofPR.Info {
    ProofPR.Info(number: 143, url: "https://github.com/o/r/pull/143", state: "OPEN", merged: false, checksFailing: false,
                 head: "feat/x", repository: "o/r", updatedAt: updatedAt ?? self.updatedAt)
  }

  func scan(session: String?? = nil, info: ProofPR.Info? = nil, timeLimit: TimeInterval = 60) async -> [AssetItem] {
    await AssetScanner.scanPR(info: info ?? self.info(), session: session ?? self.session, folder: nil, store: store, state: state,
                              now: { self.now }, timeLimit: timeLimit,
                              bodies: { _, _ in
                                self.lock.lock(); self.lookups += 1; self.lock.unlock()
                                return self.lookupFails ? .failure(ProofPR.Failure("gh failed")) : .success((self.texts, self.updatedAt))
                              },
                              download: { url, destination, limit in
                                self.lock.lock(); self.downloaded.append((url.absoluteString, limit)); self.lock.unlock()
                                if self.failing.contains(url.absoluteString) { return .failure(ProofPR.Failure("404")) }
                                let video = url.pathExtension == "mp4"
                                try? Data(repeating: 0x42, count: 10).write(to: destination)
                                return .success((contentType: video ? "video/mp4" : "image/png", bytes: 10))
                              })
  }
}

private func image(_ n: Int) -> String { "![shot \(n)](https://example.com/shots/\(n).png)" }

@Suite struct AssetScannerPRTests {
  @Test func noSessionGivesNoGroup() async {
    let f = Fixture()
    f.texts = [image(1)]
    #expect(await f.scan(session: .some(nil)).isEmpty)
    #expect(await f.scan(session: .some("../escape")).isEmpty)
    #expect(await f.scan(session: .some("")).isEmpty)
    #expect(f.bodyLookups == 0 && f.urlsDownloaded.isEmpty)
  }

  @Test func anImageInTheBodyAndInACommentComeDown() async {
    let f = Fixture()
    f.texts = ["Before:\n" + image(1), "Comment\n<video src=\"https://example.com/demo.mp4\"></video>"]
    let items = await f.scan()
    #expect(items.map(\.group) == [.pr, .pr])
    #expect(items.map(\.kind) == [.image, .video])
    #expect(items.allSatisfy { !$0.failed && $0.file != nil && $0.bytes == 10 && $0.sha256?.count == 64 })
    #expect(items[0].file?.deletingLastPathComponent().resolvingSymlinksInPath() == f.prFolder.resolvingSymlinksInPath())
    #expect(items[0].file?.pathExtension == "png" && items[1].file?.pathExtension == "mp4")
    #expect(Set(items.map(\.id)).count == 2)
  }

  @Test func onlyAllowedMediaIsEverDownloaded() async {
    let f = Fixture()
    f.texts = ["""
    ![ok](https://example.com/ok.png)
    ![plain http](http://example.com/http.png)
    ![private](https://10.0.0.5/a.png)
    ![local](https://localhost/a.png)
    ![creds](https://u:p@example.com/a.png)
    ![port](https://example.com:8443/a.png)
    ![pdf](https://example.com/a.pdf)
    ![files](https://github.com/user-attachments/files/9/a.png)
    [a link](https://example.com/link.png)

    ```
    ![fenced](https://example.com/fenced.png)
    ```
    `![inline](https://example.com/inline.png)`
    <!-- ![hidden](https://example.com/hidden.png) -->
    """]
    let items = await f.scan()
    #expect(f.urlsDownloaded == ["https://example.com/ok.png"])
    #expect(items.count == 1)
  }

  @Test func atMostTwentyAreDownloadedAndListed() async {
    let f = Fixture()
    f.texts = [(1...30).map(image).joined(separator: "\n\n")]
    let items = await f.scan()
    #expect(items.count == 20 && f.urlsDownloaded.count == 20)
    #expect(f.urlsDownloaded.first == "https://example.com/shots/1.png" && f.urlsDownloaded.last == "https://example.com/shots/20.png")
  }

  @Test func theSameImageInTwoPlacesIsOneItem() async {
    let f = Fixture()
    f.texts = [image(1), image(1) + "\n\n" + image(2)]
    #expect(await f.scan().count == 2)
    #expect(f.urlsDownloaded.count == 2)
  }

  @Test func aCacheHitDoesNotDownload() async {
    let f = Fixture()
    f.texts = [image(1)]
    let first = await f.scan()
    #expect(f.urlsDownloaded.count == 1)
    let again = await f.scan()
    #expect(f.urlsDownloaded.count == 1, "downloaded twice")
    #expect(again.map(\.id) == first.map(\.id) && again.first?.file == first.first?.file && again.first?.failed == false)
  }

  @Test func aFileAlreadyInTheCacheFolderIsUsed() async throws {
    let f = Fixture()
    let url = URL(string: "https://example.com/shots/1.png")!
    try FileManager.default.createDirectory(at: f.prFolder, withIntermediateDirectories: true)
    try Data("cached".utf8).write(to: f.prFolder.appendingPathComponent(PRMedia.cacheName(url) + ".png"))
    f.texts = [image(1)]
    let items = await f.scan()
    #expect(f.urlsDownloaded.isEmpty)
    #expect(items.first?.file != nil && items.first?.bytes == 6)
  }

  @Test func aFailureIsAPlaceholderAndIsNotRetriedForTenMinutes() async {
    let f = Fixture()
    f.texts = [image(1), image(2)]
    f.failing = ["https://example.com/shots/1.png"]
    let first = await f.scan()
    #expect(first.count == 2)
    #expect(first[0].failed && first[0].file == nil && first[0].group == .pr && first[0].kind == .image)
    #expect(!first[1].failed)
    #expect(f.urlsDownloaded.filter { $0.hasSuffix("/1.png") }.count == 1)

    f.advance(9 * 60)
    let during = await f.scan()
    #expect(during[0].failed)
    #expect(f.urlsDownloaded.filter { $0.hasSuffix("/1.png") }.count == 1, "retried inside the ten minutes")

    f.advance(2 * 60)
    f.failing = []
    let after = await f.scan()
    #expect(f.urlsDownloaded.filter { $0.hasSuffix("/1.png") }.count == 2, "never retried")
    #expect(!after[0].failed && after[0].file != nil)
  }

  @Test func aFailedVideoKeepsItsKindForThePlaceholder() async {
    let f = Fixture()
    f.texts = ["<video src=\"https://example.com/demo.mp4\"></video>"]
    f.failing = ["https://example.com/demo.mp4"]
    let items = await f.scan()
    #expect(items.first?.kind == .video && items.first?.failed == true)
  }

  @Test func anUnchangedUpdatedAtMakesNoBodyLookup() async {
    let f = Fixture()
    f.texts = [image(1)]
    f.updatedAt = "A" // the PR as GitHub has it: gh's answer carries the same updatedAt as the PR's own
    _ = await f.scan(info: f.info(updatedAt: "A"))
    #expect(f.bodyLookups == 1)
    f.texts = [image(1), image(2)] // the lookup would see this, if it were made
    let same = await f.scan(info: f.info(updatedAt: "A"))
    #expect(f.bodyLookups == 1)
    #expect(same.count == 1)
    f.updatedAt = "B"
    let changed = await f.scan(info: f.info(updatedAt: "B"))
    #expect(f.bodyLookups == 2 && changed.count == 2)
  }

  @Test func whenThePRsUpdatedAtIsUnknownTheBodiesAreAlwaysRead() async {
    let f = Fixture()
    f.texts = [image(1)]
    let unknown = f.info(updatedAt: "")
    _ = await f.scan(info: unknown)
    _ = await f.scan(info: unknown)
    #expect(f.bodyLookups == 2)
  }

  @Test func theLookupCacheIsPerSessionAndPR() async {
    let f = Fixture()
    f.texts = [image(1)]
    f.updatedAt = "A"
    _ = await f.scan(info: f.info(updatedAt: "A"))
    _ = await f.scan(session: .some("99999999-2222-3333-4444-555555555555"), info: f.info(updatedAt: "A"))
    #expect(f.bodyLookups == 2)
  }

  @Test func aFailedLookupGivesTheLastKnownMediaOrNothing() async {
    let f = Fixture()
    f.lookupFails = true
    #expect(await f.scan().isEmpty)
    f.lookupFails = false
    f.texts = [image(1)]
    f.updatedAt = "A"
    #expect(await f.scan(info: f.info(updatedAt: "A")).count == 1)
    f.lookupFails = true
    #expect(await f.scan(info: f.info(updatedAt: "B")).count == 1) // kept what it knew
  }

  @Test func outOfTimeLeavesPlaceholdersThatAreRetriedNextTime() async {
    let f = Fixture()
    f.texts = [image(1), image(2)]
    let none = await f.scan(timeLimit: 0)
    #expect(none.count == 2 && none.allSatisfy { $0.pending && !$0.failed && $0.file == nil } && f.urlsDownloaded.isEmpty,
            "not fetched yet is not failed")
    let later = await f.scan() // no ten-minute wait: running out of time is not a failure of the image
    #expect(later.count == 2 && later.allSatisfy { !$0.failed } && f.urlsDownloaded.count == 2)
  }

  @Test func theWholeCacheOfAPRIsCapped() async throws {
    let f = Fixture()
    try FileManager.default.createDirectory(at: f.prFolder, withIntermediateDirectories: true)
    let used = AssetScanner.maxPRCacheBytes - 1_000
    let filler = f.prFolder.appendingPathComponent("filler.png")
    FileManager.default.createFile(atPath: filler.path, contents: nil)
    let handle = try FileHandle(forWritingTo: filler)
    try handle.truncate(atOffset: UInt64(used)) // sparse
    try handle.close()
    f.texts = [image(1)]
    let items = await f.scan()
    #expect(f.limitsSeen == [1_000], "the download was allowed more than the folder has room for")
    #expect(items.count == 1)
  }

  @Test func noRoomLeftInTheCacheLeavesPendingNotFailedAndOnlyARealFailureIsFailed() async throws {
    let f = Fixture()
    try FileManager.default.createDirectory(at: f.prFolder, withIntermediateDirectories: true)
    let filler = f.prFolder.appendingPathComponent("filler.png")
    FileManager.default.createFile(atPath: filler.path, contents: nil)
    let handle = try FileHandle(forWritingTo: filler)
    try handle.truncate(atOffset: UInt64(AssetScanner.maxPRCacheBytes)) // sparse: the cache is full
    try handle.close()
    f.texts = [image(1), image(2)]
    f.failing = ["https://example.com/shots/2.png"]
    let items = await f.scan()
    #expect(items.count == 2 && f.urlsDownloaded.isEmpty)
    #expect(items.allSatisfy { $0.pending && !$0.failed && $0.file == nil }, "no room is not the image's fault")
    try FileManager.default.removeItem(at: filler)
    let later = await f.scan()
    #expect(later[0].file != nil && !later[0].pending)
    #expect(later[1].failed && !later[1].pending, "a download that really failed is failed, and stays so")
  }

  @Test func theLimitPassedToEachDownloadIs50MB() async {
    let f = Fixture()
    f.texts = [image(1)]
    _ = await f.scan()
    #expect(f.limitsSeen == [50 << 20])
  }

  @Test func leftoverPartialDownloadsAreSweptButFreshOnesStay() async throws {
    let f = Fixture()
    try FileManager.default.createDirectory(at: f.prFolder, withIntermediateDirectories: true)
    let old = f.prFolder.appendingPathComponent(".old.part")
    let fresh = f.prFolder.appendingPathComponent(".fresh.part")
    try Data("x".utf8).write(to: old); try Data("x".utf8).write(to: fresh)
    try FileManager.default.setAttributes([.modificationDate: f.now.addingTimeInterval(-3_600)], ofItemAtPath: old.path)
    try FileManager.default.setAttributes([.modificationDate: f.now], ofItemAtPath: fresh.path)
    f.texts = [image(1)]
    _ = await f.scan()
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
  }
}
