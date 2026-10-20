import Foundation

/// Which Claude Code session belongs to a terminal: the one whose working directory is the terminal's, exactly.
/// A parent or child folder doesn't count, so two projects never share a panel.
public enum SessionMatch {
  /// `~` expanded, `.`, `..` and trailing slashes resolved, and macOS's `/private` prefix on /tmp, /var and /etc
  /// dropped, so the shell's and Claude Code's spellings of one folder compare equal.
  public static func normalize(_ path: String, home: String) -> String {
    var path = path
    if path == "~" {
      path = home
    } else if path.hasPrefix("~/") {
      path = home + path.dropFirst(1)
    }
    path = URL(fileURLWithPath: path).standardizedFileURL.path
    for root in ["/tmp", "/var", "/etc"] where path == "/private" + root || path.hasPrefix("/private" + root + "/") {
      path.removeFirst("/private".count)
    }
    return path
  }

  /// True when both folders are known and are the same folder.
  public static func matches(sessionCwd: String?, surfacePwd: String?, home: String = NSHomeDirectory()) -> Bool {
    guard let sessionCwd, let surfacePwd, !sessionCwd.isEmpty, !surfacePwd.isEmpty else { return false }
    return normalize(sessionCwd, home: home) == normalize(surfacePwd, home: home)
  }
}
