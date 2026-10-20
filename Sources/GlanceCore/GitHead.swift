import Foundation

/// The git branch of a folder, read straight from `.git/HEAD` (no git process).
public enum GitHead {
  /// The branch a HEAD file names, the first 7 characters of the commit when HEAD is detached, or nil.
  public static func branch(fromHead content: String) -> String? {
    let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("ref:") {
      let ref = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
      let heads = "refs/heads/"
      if ref.hasPrefix(heads) { return String(ref.dropFirst(heads.count)) }
      return ref.isEmpty ? nil : ref
    }
    return text.count >= 7 && text.allSatisfy(\.isHexDigit) ? String(text.prefix(7)) : nil
  }

  /// The branch of the repo that contains `folder`, or nil outside a repo or when HEAD can't be read. A worktree or
  /// submodule has a `.git` *file* saying `gitdir: <path>`; the path may be absolute or relative to the repo root.
  public static func branch(inFolder folder: String, home: String = NSHomeDirectory()) -> String? {
    let root = ProjectRoot.find(from: folder, home: home)
    let dotGit = root + "/.git"
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
    let headFile: String
    if isDirectory.boolValue {
      headFile = dotGit + "/HEAD"
    } else {
      guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
            let line = pointer.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
      let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
      headFile = (target.hasPrefix("/") ? target : root + "/" + target) + "/HEAD"
    }
    guard let content = try? String(contentsOfFile: headFile, encoding: .utf8) else { return nil }
    return branch(fromHead: content)
  }
}
