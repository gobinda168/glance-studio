import Foundation

/// The project folder an editor tab works on: the git root above a terminal's folder, else the folder itself.
public enum ProjectRoot {
  public static func find(
    from directory: String,
    home: String = NSHomeDirectory(),
    hasGit: (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/.git") }
  ) -> String {
    let start = SessionMatch.normalize(directory, home: home)
    let home = SessionMatch.normalize(home, home: home)
    var current = start
    while true {
      if hasGit(current) { return current }
      if current == "/" || current == home { return start }
      current = URL(fileURLWithPath: current).deletingLastPathComponent().path
    }
  }
}
