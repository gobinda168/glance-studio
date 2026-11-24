import Foundation

/// Local images and videos a reply or command output mentions, so the Glance view can show them inline.
public enum MediaLinks {
  public enum Kind: Equatable, Sendable { case image, video }

  private static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
  private static let videos: Set<String> = ["mp4", "mov", "webm", "m4v"]

  public static func kind(of path: String) -> Kind? {
    let ext = (path as NSString).pathExtension.lowercased()
    return images.contains(ext) ? .image : videos.contains(ext) ? .video : nil
  }

  /// Absolute paths, in order of mention, without duplicates. URLs are not paths.
  public static func find(in text: String, root: String?, home: String) -> [String] {
    let pattern = #"(?<![\w/:.~])((?:~|\.{1,2})?/?[\w@.\-]+(?:/[\w@.\-]+)*\.(?:png|jpe?g|gif|webp|heic|mp4|mov|webm|m4v))\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    var out: [String] = []
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let range = Range(match.range(at: 1), in: text) else { continue }
      var path = String(text[range])
      if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
      else if path.hasPrefix("./") { guard let root else { continue }; path = root + path.dropFirst(1) }
      else if !path.hasPrefix("/") { guard let root else { continue }; path = root + "/" + path }
      if !out.contains(path) { out.append(path) }
    }
    return out
  }
}
