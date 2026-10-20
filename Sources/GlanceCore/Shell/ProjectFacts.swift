import Foundation

/// What the correction rules need to know about a folder's project: its package.json scripts and its git branches,
/// read from the files (no npm or git process).
public enum ProjectFacts {
  /// The script names of the nearest package.json at or above `folder` (up to the git root or home).
  public static func scripts(inFolder folder: String, home: String = NSHomeDirectory()) -> [String] {
    var current = folder
    while true {
      let file = (current as NSString).appendingPathComponent("package.json")
      if let data = FileManager.default.contents(atPath: file),
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return ((json["scripts"] as? [String: Any]) ?? [:]).keys.sorted()
      }
      if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) || current == home
        || current == "/" { return [] }
      current = (current as NSString).deletingLastPathComponent
    }
  }

  /// The local branches of the repository holding `folder`: loose refs under refs/heads and packed-refs.
  public static func branches(inFolder folder: String, home: String = NSHomeDirectory()) -> [String] {
    let root = ProjectRoot.find(from: folder, home: home)
    var gitDir = (root as NSString).appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: gitDir, isDirectory: &isDirectory) else { return [] }
    if !isDirectory.boolValue {
      // A worktree or submodule: `.git` names the real git folder.
      guard let pointer = try? String(contentsOfFile: gitDir, encoding: .utf8),
            let line = pointer.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return [] }
      let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
      gitDir = target.hasPrefix("/") ? target : (root as NSString).appendingPathComponent(target)
      // A worktree's branches live in the common git folder.
      if let common = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8) {
        let path = common.trimmingCharacters(in: .whitespacesAndNewlines)
        gitDir = path.hasPrefix("/") ? path : ((gitDir as NSString).appendingPathComponent(path) as NSString).standardizingPath
      }
    }
    var names = Set<String>()
    let heads = (gitDir as NSString).appendingPathComponent("refs/heads")
    if let walker = FileManager.default.enumerator(atPath: heads) {
      for case let path as String in walker {
        var folder: ObjCBool = false
        if FileManager.default.fileExists(atPath: (heads as NSString).appendingPathComponent(path), isDirectory: &folder),
           !folder.boolValue { names.insert(path) }
      }
    }
    if let packed = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("packed-refs"), encoding: .utf8) {
      for line in packed.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("^") {
        let parts = line.split(separator: " ")
        if parts.count == 2, parts[1].hasPrefix("refs/heads/") { names.insert(String(parts[1].dropFirst("refs/heads/".count))) }
      }
    }
    return names.sorted()
  }
}
