import Foundation

/// The Open in Editor palette's list (New Editor Tab asks which folder): THIS TAB and RECENT, or one list of matches
/// while filtering; and the checks on a new folder's name.
public enum EditorFolderPicker {
  public enum Section: Equatable, Sendable {
    case thisTab, recent
    /// The filter's matches, in one list.
    case matches
  }

  public struct Group: Equatable, Sendable {
    public let section: Section
    public let folders: [String]
  }

  /// RECENT shows this many.
  public static let recentLimit = 8

  /// The groups to show, empty ones left out. `thisTab` is the tab's project, `recent` Home's recent projects (newest
  /// first); this tab's project isn't listed again under RECENT. With a filter: one list of the folders whose path, as
  /// shown with `~`, contains the text (ignoring case), names starting with it first.
  public static func groups(thisTab: String?, recent: [String], filter: String, home: String) -> [Group] {
    let others = recent.filter { $0 != thisTab }
    let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
    guard query.isEmpty else {
      let matching = ([thisTab].compactMap { $0 } + others).filter { shown($0, home: home).lowercased().contains(query) }
      let starting = matching.filter { name($0).lowercased().hasPrefix(query) }
      let rest = matching.filter { !name($0).lowercased().hasPrefix(query) }
      return [Group(section: .matches, folders: starting + rest)].filter { !$0.folders.isEmpty }
    }
    return [
      Group(section: .thisTab, folders: [thisTab].compactMap { $0 }),
      Group(section: .recent, folders: Array(others.prefix(recentLimit))),
    ].filter { !$0.folders.isEmpty }
  }

  /// The folder's name, its last path component.
  public static func name(_ folder: String) -> String {
    (folder as NSString).lastPathComponent
  }

  /// The path as the palette shows it: `~` for the home folder.
  public static func shown(_ folder: String, home: String) -> String {
    if folder == home { return "~" }
    return folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
  }

  /// What New Folder… makes of a name.
  public enum NewFolder: Equatable, Sendable {
    /// Nothing typed yet.
    case empty
    /// Not a name the palette makes, and why.
    case invalid(String)
    /// The folder is there already: the palette offers to open it instead.
    case exists(String)
    /// Make this folder.
    case create(String)
  }

  /// A new folder `name` (trimmed) in `parent`: a plain name, not hidden, not already there.
  public static func newFolder(named name: String, in parent: String, exists: (String) -> Bool) -> NewFolder {
    let name = name.trimmingCharacters(in: .whitespaces)
    if name.isEmpty { return .empty }
    if name.contains("/") || name.contains(":") { return .invalid("A folder name can't contain / or :.") }
    if name.hasPrefix(".") { return .invalid("A folder name can't start with a dot.") }
    if name.utf8.count > 255 { return .invalid("That name is too long.") }
    let path = (parent as NSString).appendingPathComponent(name)
    return exists(path) ? .exists(path) : .create(path)
  }
}
