import Foundation

/// The short folder name on a sidebar row.
public enum FolderLabel {
  public static func name(forPath path: String?, home: String = NSHomeDirectory()) -> String {
    guard let path, !path.isEmpty else { return "" }
    let normalized = SessionMatch.normalize(path, home: home)
    if normalized == SessionMatch.normalize(home, home: home) { return "~" }
    if normalized == "/" { return "/" }
    return URL(fileURLWithPath: normalized).lastPathComponent
  }
}
