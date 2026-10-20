import Foundation

/// The tabs Glance Studio had open when it last ran, saved so a relaunch (an update restarts the whole app) opens where
/// the user left off, as a browser does. Terminal tabs are brought back by AppKit's own window restoration (they only
/// name the terminal's first pane here, to put them in order); every other tab says what it showed.
public struct TabSnapshot: Codable, Equatable, Sendable {
  public struct Tab: Codable, Equatable, Sendable {
    /// `"terminal"`, or a Glance tab's kind (`GlanceTabController.tabKind`).
    public var kind: String
    /// What identifies the tab within its kind: an editor's folder, a pull request's `repository#number`.
    public var key: String?
    /// A Browser tab's page.
    public var url: String?
    /// A terminal tab's first pane (its surface ID, which restoration keeps).
    public var surface: String?

    public init(kind: String, key: String? = nil, url: String? = nil, surface: String? = nil) {
      self.kind = kind
      self.key = key
      self.url = url
      self.surface = surface
    }

    public static let terminal = "terminal"
    public var isTerminal: Bool { kind == Self.terminal }
  }

  /// One window's tabs, left to right.
  public struct Group: Codable, Equatable, Sendable {
    public var tabs: [Tab]
    /// The tab in front, as an index into `tabs`.
    public var selected: Int?

    public init(tabs: [Tab], selected: Int? = nil) {
      self.tabs = tabs
      self.selected = selected
    }

    /// `selected` when it names a tab.
    public var front: Int? { selected.flatMap { tabs.indices.contains($0) ? $0 : nil } }
  }

  public static let version = 1

  public var version = Self.version
  public var groups: [Group]
  /// The window the user was in, as an index into `groups`.
  public var frontGroup: Int?

  public init(groups: [Group], frontGroup: Int? = nil) {
    self.groups = groups
    self.frontGroup = frontGroup
  }

  public var isEmpty: Bool { groups.allSatisfy { $0.tabs.isEmpty } }

  public func encoded() -> Data? { try? JSONEncoder().encode(self) }

  /// The snapshot in `data`; nil for anything unreadable or from a version this one doesn't know.
  public static func decode(_ data: Data?) -> TabSnapshot? {
    guard let data, let snapshot = try? JSONDecoder().decode(TabSnapshot.self, from: data),
      snapshot.version == Self.version else { return nil }
    return snapshot
  }
}
