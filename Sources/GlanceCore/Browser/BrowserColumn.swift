import Foundation

/// How wide the browser column is (spec 2026-11-24-browser-column-design.md §1). `space` is what the column shares
/// with the terminal: the tab's width without the tab side bar and the Glance side pane.
public enum BrowserColumnLayout {
  public static let minWidth: Double = 320
  public static let minTerminalWidth: Double = 300
  public static let defaultFraction = 0.42

  /// The saved width, or 42% of the space, clamped so the terminal keeps its minimum; never under the column's own.
  public static func width(saved: Double?, space: Double) -> Double {
    let wanted = saved ?? (space * defaultFraction).rounded()
    let most = max(minWidth, space - minTerminalWidth)
    return min(max(wanted, minWidth), most)
  }

  /// Too narrow for both side by side: the column covers the right of the tab.
  public static func overlays(space: Double) -> Bool { space < minWidth + minTerminalWidth }
}

/// The column's tabs in order and which one is in front. The last tab never closes: closing the column is the way.
public struct BrowserColumnTabs<ID: Hashable>: Equatable {
  public private(set) var ids: [ID]
  public private(set) var selected: ID

  public init(first: ID) {
    ids = [first]
    selected = first
  }

  /// nil without tabs; a selection that isn't one of them becomes the first tab.
  public init?(ids: [ID], selected: ID?) {
    guard let first = ids.first else { return nil }
    self.ids = ids
    self.selected = selected.flatMap { ids.contains($0) ? $0 : nil } ?? first
  }

  /// A new tab right after the selected one, now selected.
  public mutating func add(_ id: ID) {
    let at = (ids.firstIndex(of: selected) ?? ids.count - 1) + 1
    ids.insert(id, at: at)
    selected = id
  }

  public mutating func select(_ id: ID) {
    if ids.contains(id) { selected = id }
  }

  /// Closes a tab: the selected one hands the selection to its right neighbour, else its left. False when it isn't
  /// there or is the last one.
  @discardableResult
  public mutating func close(_ id: ID) -> Bool {
    guard ids.count > 1, let index = ids.firstIndex(of: id) else { return false }
    ids.remove(at: index)
    if selected == id { selected = ids[min(index, ids.count - 1)] }
    return true
  }
}

/// What a terminal tab's column keeps across relaunches (TerminalRestorableState): open or not, width, each tab's
/// address (nil for a New Tab) and the selected tab.
public struct BrowserColumnSaved: Codable, Equatable, Sendable {
  public static let maxTabs = 20

  public var open: Bool
  public var width: Double?
  public var urls: [String?]
  public var selected: Int

  /// Only http(s) addresses are kept (anything else comes back as a New Tab), at most 20 tabs, the selection in range.
  /// nil when a closed column has nothing worth bringing back.
  public static func make(open: Bool, width: Double?, urls: [URL?], selected: Int) -> BrowserColumnSaved? {
    let kept = urls.prefix(maxTabs).map { url -> String? in
      guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
      return url.absoluteString
    }
    guard open || kept.contains(where: { $0 != nil }) else { return nil }
    let list = kept.isEmpty ? [nil] : Array(kept)
    return BrowserColumnSaved(open: open, width: width, urls: list, selected: min(max(selected, 0), list.count - 1))
  }

  /// Each tab's address as restored: a value that isn't an http(s) URL becomes a New Tab.
  public var restoredURLs: [URL?] {
    let list = urls.isEmpty ? [nil] : urls
    return list.prefix(Self.maxTabs).map { text in
      guard let text, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host != nil else { return nil }
      return url
    }
  }

  /// The selected tab's index among `restoredURLs`, in range.
  public var restoredSelection: Int { min(max(selected, 0), restoredURLs.count - 1) }
}
