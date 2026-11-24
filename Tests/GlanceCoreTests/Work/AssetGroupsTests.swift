import Foundation
import Testing
@testable import GlanceCore

@Suite struct AssetGroupsTests {
  let t0 = Date(timeIntervalSince1970: 1_000)

  func capture(_ id: String, kind: ProofCapture.Kind = .screenshot, file: String? = nil, purpose: ProofCapture.Purpose = .test,
               sha: String? = nil, env: String? = nil, source: ProofSource = .glance) -> ProofCapture {
    var c = ProofCapture(id: id, kind: kind, file: file ?? "\(id).png", environment: env, caption: "Caption \(id)",
                         purpose: purpose, at: t0, source: source)
    c.sha256 = sha
    return c
  }

  func item(_ id: String, _ group: AssetItem.Group, kind: AssetItem.Kind = .image, path: String? = nil, sha: String? = nil,
            bytes: Int64? = nil) -> AssetItem {
    AssetItem(id: id, group: group, kind: kind, name: id, path: path ?? id, file: nil, environment: nil, at: nil, failed: false,
              bytes: bytes, sha256: sha)
  }

  func present(_ c: ProofCapture) -> URL? { URL(fileURLWithPath: "/media/" + c.file) }

  @Test func theMediaExtensions() {
    #expect(AssetGroups.mediaExtensions == ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "mp4", "mov", "webm", "m4v"])
  }

  @Test func groupsComeInTheDesignedOrder() {
    #expect(AssetItem.Group.allCases == [.outcome, .pr, .testing, .branch, .testRun])
    let merged = AssetGroups.merge(
      captures: [capture("t1"), capture("o1", purpose: .outcome)], media: present,
      found: [item("r1", .testRun), item("b1", .branch), item("p1", .pr)])
    #expect(merged.map(\.group) == [.outcome, .pr, .testing, .branch, .testRun])
    #expect(merged.map(\.id) == ["o1", "p1", "t1", "b1", "r1"])
  }

  @Test func theOrderInsideAGroupIsTheOrderGiven() {
    let merged = AssetGroups.merge(captures: [capture("a"), capture("b"), capture("c")], media: present, found: [])
    #expect(merged.map(\.id) == ["a", "b", "c"])
  }

  @Test func aCaptureCarriesItsFields() throws {
    let c = capture("a", env: "Local")
    let merged = AssetGroups.merge(captures: [c], media: present, found: [])
    let a = try #require(merged.first)
    #expect(a.group == .testing && a.kind == .image && a.name == "Caption a" && a.environment == "Local" && a.at == t0)
    #expect(a.file == URL(fileURLWithPath: "/media/a.png") && !a.failed)
    #expect(a.path == "a.png")
  }

  @Test func aClipIsAVideo() throws {
    let merged = AssetGroups.merge(captures: [capture("c", kind: .clip, file: "c.mp4")], media: present, found: [])
    #expect(try #require(merged.first).kind == .video)
  }

  @Test func aFileCaptureTakesItsKindFromItsExtension() {
    let merged = AssetGroups.merge(
      captures: [capture("f1", kind: .file, file: "f1.mp4"), capture("f2", kind: .file, file: "f2.webp"),
                 capture("f3", kind: .file, file: "f3.txt"), capture("f4", kind: .file, file: "f4")],
      media: present, found: [])
    #expect(merged.map(\.kind) == [.video, .image, .file, .file])
  }

  @Test func aFinishedExplainerIsListedUnderOutcome() throws {
    // Its purpose is the default (.test): the kind puts it under Outcome.
    let merged = AssetGroups.merge(captures: [capture("e", kind: .explainer, file: "e.mp4", source: .claude), capture("t")],
                                   media: present, found: [])
    #expect(merged.map(\.id) == ["e", "t"])
    let e = try #require(merged.first)
    #expect(e.group == .outcome && e.kind == .video)
  }

  @Test func theSameHashUnderTestingAndOutcomeAppearsOnceAsOutcome() {
    // The common flow: a browser screenshot (test), then proof_capture(purpose: outcome) of the same image.
    let shot = capture("toolu_09", sha: "abc")
    let marked = capture("11111111-uuid", purpose: .outcome, sha: "abc", source: .claude)
    for captures in [[shot, marked], [marked, shot]] {
      let merged = AssetGroups.merge(captures: captures, media: present, found: [])
      #expect(merged.map(\.id) == ["11111111-uuid"])
      #expect(merged.first?.group == .outcome)
    }
  }

  @Test func theSameHashWithinOneGroupAppearsOnce() {
    let merged = AssetGroups.merge(captures: [capture("a", sha: "abc"), capture("b", sha: "abc")], media: present, found: [])
    #expect(merged.map(\.id) == ["a"])
  }

  @Test func twoCapturesWithUnknownHashesAreNotTheSameFile() {
    // A big hook screenshot has no hash; an outcome capture with none either must not absorb it.
    let merged = AssetGroups.merge(captures: [capture("shot"), capture("marked", purpose: .outcome)], media: present,
                                   found: [item("branch.png", .branch)])
    #expect(merged.map(\.id) == ["marked", "shot", "branch.png"])
    let empty = AssetGroups.merge(captures: [capture("a", sha: ""), capture("b", sha: "")], media: present, found: [])
    #expect(empty.map(\.id) == ["a", "b"])
    #expect(AssetGroups.timelineTag(rowID: "shot", captures: [capture("shot"), capture("marked", purpose: .outcome)]) == .testing)
  }

  @Test func differentHashesAndMissingHashesAreNotMerged() {
    let merged = AssetGroups.merge(captures: [capture("a", sha: "1"), capture("b", sha: "2"), capture("c"), capture("d")],
                                   media: present, found: [])
    #expect(merged.map(\.id) == ["a", "b", "c", "d"])
  }

  @Test func aBranchFileWithACapturesHashAppearsOnceUnderTheCapturesGroup() {
    let outcome = AssetGroups.merge(captures: [capture("o", purpose: .outcome, sha: "abc")], media: present,
                                    found: [item("docs/hero.png", .branch, sha: "abc")])
    #expect(outcome.map(\.id) == ["o"] && outcome.first?.group == .outcome)
    let testing = AssetGroups.merge(captures: [capture("t", sha: "abc")], media: present,
                                    found: [item("test-results/x.png", .testRun, sha: "abc"), item("p", .pr, sha: "abc")])
    #expect(testing.map(\.id) == ["t"] && testing.first?.group == .testing)
  }

  @Test func foundFilesWithOtherHashesStay() {
    let merged = AssetGroups.merge(captures: [capture("t", sha: "abc")], media: present,
                                   found: [item("b1", .branch, sha: "other"), item("b2", .branch)])
    #expect(merged.map(\.id) == ["t", "b1", "b2"])
  }

  @Test func aMissingMediaFileKeepsTheItemAsFailed() throws {
    let merged = AssetGroups.merge(captures: [capture("a"), capture("gone")],
                                   media: { $0.id == "gone" ? nil : URL(fileURLWithPath: "/media/" + $0.file) }, found: [])
    #expect(merged.map(\.id) == ["a", "gone"])
    let gone = try #require(merged.last)
    #expect(gone.failed && gone.file == nil && gone.group == .testing && gone.name == "Caption gone")
    #expect(merged.first?.failed == false)
  }

  @Test func foundItemsKeepTheirOwnFields() throws {
    let found = AssetItem(id: "pr:1", group: .pr, kind: .video, name: "demo", path: "#12 · demo.mp4",
                          file: URL(fileURLWithPath: "/cache/1.mp4"), environment: nil, at: t0, failed: true, bytes: 42, sha256: nil)
    let merged = AssetGroups.merge(captures: [], media: present, found: [found])
    #expect(merged == [found])
  }

  @Test func theSameIDTwiceListsOnce() {
    let merged = AssetGroups.merge(captures: [capture("a")], media: present, found: [item("a", .branch), item("b", .branch)])
    #expect(merged.map(\.id) == ["a", "b"])
  }

  @Test func nothingMergesToNothing() {
    #expect(AssetGroups.merge(captures: [], media: present, found: []).isEmpty)
  }

  // MARK: timelineTag

  @Test func aTimelineRowWhoseCaptureIsAnOutcomeIsTaggedOutcome() {
    #expect(AssetGroups.timelineTag(rowID: "o", captures: [capture("o", purpose: .outcome)]) == .outcome)
  }

  @Test func theBrowserShotLaterMarkedAsOutcomeIsTaggedOutcome() {
    let captures = [capture("toolu_09", sha: "abc"), capture("uuid", purpose: .outcome, sha: "abc", source: .claude)]
    #expect(AssetGroups.timelineTag(rowID: "toolu_09", captures: captures) == .outcome)
  }

  @Test func otherwiseTesting() {
    let captures = [capture("a", sha: "1"), capture("b", purpose: .outcome, sha: "2"), capture("c")]
    #expect(AssetGroups.timelineTag(rowID: "a", captures: captures) == .testing)
    #expect(AssetGroups.timelineTag(rowID: "c", captures: captures) == .testing)
  }

  @Test func aRowWithNoCaptureHasNoTag() {
    #expect(AssetGroups.timelineTag(rowID: "toolu_x", captures: [capture("a")]) == nil)
    #expect(AssetGroups.timelineTag(rowID: "a", captures: []) == nil)
  }

  @Test func anExplainerRowIsTaggedOutcome() {
    #expect(AssetGroups.timelineTag(rowID: "e", captures: [capture("e", kind: .explainer, file: "e.mp4")]) == .outcome)
  }

  // MARK: What Proof counts (a finished explainer is not in Proof)

  @Test func proofCountsLeaveAFinishedExplainerOut() {
    let explainer = capture("x", kind: .explainer, file: "x.mp4", purpose: .outcome)
    let counts = AssetGroups.proofCounts(captures: [explainer, capture("t1"), capture("o1", purpose: .outcome)])
    #expect(counts.outcome == 1 && counts.testing == 1)
    #expect(AssetGroups.proofCounts(captures: [explainer]) == (0, 0))
  }

  @Test func proofCountsCountTwoCapturesOfOneImageOnce() {
    let shot = capture("shot", sha: "abc")
    let marked = capture("marked", purpose: .outcome, sha: "abc")
    let counts = AssetGroups.proofCounts(captures: [shot, marked, capture("other", sha: "def")])
    #expect(counts.outcome == 1 && counts.testing == 1, "the same image is one asset, as Outcome")
  }

  @Test func proofCountsMatchWhatAssetsListsForTheSameCaptures() {
    let captures = [capture("a"), capture("b", kind: .clip, file: "b.mp4"), capture("c", purpose: .outcome), capture("d", kind: .file, file: "d.txt")]
    let listed = AssetGroups.merge(captures: captures, media: present, found: [])
    let counts = AssetGroups.proofCounts(captures: captures)
    #expect(counts.outcome == listed.filter { $0.group == .outcome }.count && counts.testing == listed.filter { $0.group == .testing }.count)
    #expect(counts.outcome == 1 && counts.testing == 3)
  }

  @Test func anItemNotFetchedYetIsPendingNotFailed() {
    let waiting = AssetItem(id: "p", group: .pr, kind: .image, name: "p", path: "#1", pending: true)
    #expect(waiting.pending && !waiting.failed)
    #expect(!item("q", .pr).pending)
  }
}
