import Foundation

/// What a worktree's recap shows of its assets (spec §5): the first few tiles under the commits, and which folder the
/// Assets section may look at. The section itself is `AssetsModel`; these are the two rules the recap adds.
public enum RecapAssets {
  /// The tiles the recap card holds; the panel's Assets section has the rest.
  public static let tiles = 4

  /// The tiles to show and how many more there are. A file that is there comes before one that is gone, not yet fetched or
  /// failed: the records of a removed worktree can name files since cleared, and four dead tiles shouldn't hide a live one.
  /// The order is kept inside each kind, so the section's order (Outcome first) still decides among the live ones.
  public static func strip(_ items: [AssetItem]) -> (shown: [AssetItem], more: Int) {
    let live = items.filter(isAvailable), dead = items.filter { !isAvailable($0) }
    let shown = Array((live + dead).prefix(tiles))
    return (shown, items.count - shown.count)
  }

  private static func isAvailable(_ item: AssetItem) -> Bool { item.file != nil && !item.failed && !item.pending }

  /// The folder to scan for media. A removed worktree has none: its recap sits in the main checkout, whose branch and test
  /// output are not this worktree's, so it shows only what the records hold.
  public static func scanFolder(cwd: String?, worktreeGone: Bool) -> String? {
    worktreeGone ? nil : cwd
  }
}
