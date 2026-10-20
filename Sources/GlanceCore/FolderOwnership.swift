/// Decides whose Claude session a hook event belongs to. Studio's own terminals feed Studio's pane by watching
/// transcripts; the overlay hears the same session through the hooks, so it ignores folders a Studio terminal is in.
public enum FolderOwnership {
  /// `cwd` and one of `folders` are the same folder, or one holds the other.
  public static func isOwned(_ cwd: String, by folders: [String]) -> Bool {
    let cwd = trimmed(cwd)
    guard !cwd.isEmpty else { return false }
    return folders.contains { folder in
      let folder = trimmed(folder)
      return !folder.isEmpty && (cwd == folder || cwd.hasPrefix(folder + "/") || folder.hasPrefix(cwd + "/"))
    }
  }

  private static func trimmed(_ path: String) -> String {
    var path = path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return path
  }
}
