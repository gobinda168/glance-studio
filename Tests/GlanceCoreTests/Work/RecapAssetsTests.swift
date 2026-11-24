import Foundation
import Testing
@testable import GlanceCore

@Suite struct RecapAssetsTests {
  func item(_ id: String, _ group: AssetItem.Group = .testing, file: Bool = true, pending: Bool = false, failed: Bool = false) -> AssetItem {
    AssetItem(id: id, group: group, kind: .image, name: id, path: id, file: file ? URL(fileURLWithPath: "/media/\(id).png") : nil,
              failed: failed, pending: pending)
  }

  // MARK: What the recap shows

  @Test func theFirstFourShowInTheOrderTheSectionHasThem() {
    let items = ["a", "b", "c", "d", "e", "f"].map { item($0) }
    let strip = RecapAssets.strip(items)
    #expect(strip.shown.map(\.id) == ["a", "b", "c", "d"])
    #expect(strip.more == 2)
  }

  @Test func fewerThanFourAreAllShownWithNothingMore() {
    let strip = RecapAssets.strip([item("a"), item("b")])
    #expect(strip.shown.map(\.id) == ["a", "b"])
    #expect(strip.more == 0)
  }

  @Test func nothingMeansNothingToShow() {
    let strip = RecapAssets.strip([])
    #expect(strip.shown.isEmpty)
    #expect(strip.more == 0)
  }

  @Test func aFileThatIsThereComesBeforeOneThatIsGone() {
    // Records of a removed worktree can name files since cleared: four dead tiles must not hide a live one.
    let items = [item("gone1", .outcome, file: false), item("gone2", .outcome, file: false, failed: true),
                 item("wait", .pr, file: false, pending: true), item("here1", .testing), item("here2", .branch), item("here3", .testRun)]
    let strip = RecapAssets.strip(items)
    #expect(strip.shown.map(\.id) == ["here1", "here2", "here3", "gone1"])
    #expect(strip.more == 2)
  }

  @Test func theOrderInsideEachKindIsKept() {
    let items = [item("x1", file: false), item("a1"), item("x2", file: false), item("a2")]
    #expect(RecapAssets.strip(items).shown.map(\.id) == ["a1", "a2", "x1", "x2"])
  }

  // MARK: Which folder is looked at

  @Test func aFolderThatIsThereIsLookedAt() {
    #expect(RecapAssets.scanFolder(cwd: "/work/feat", worktreeGone: false) == "/work/feat")
  }

  @Test func aRemovedWorktreeHasNoFolderToLookAt() {
    // Its recap sits in the main checkout (or wherever the tab is), and that is not this worktree's branch.
    #expect(RecapAssets.scanFolder(cwd: "/repo", worktreeGone: true) == nil)
  }

  @Test func noFolderStaysNone() {
    #expect(RecapAssets.scanFolder(cwd: nil, worktreeGone: false) == nil)
  }
}
