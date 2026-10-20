import Foundation

/// The URLs the editor's Markdown and HTML preview loads project files through: `glance-file://project/<path>`, the
/// path relative to the project root and percent-encoded per segment. The web view serves them from `FileService`, so
/// nothing outside the root is reachable.
public enum PreviewFiles {
  public static let scheme = "glance-file"
  public static let host = "project"

  /// The project-relative path a preview URL names; nil for any other URL.
  public static func path(from url: URL) -> String? {
    guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
    let path = url.path.drop { $0 == "/" }
    return path.isEmpty ? nil : String(path)
  }

  private static let types: [String: String] = [
    "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
    "json": "application/json", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "gif": "image/gif", "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon", "bmp": "image/bmp",
    "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "mp4": "video/mp4",
    "webm": "video/webm", "mp3": "audio/mpeg", "wav": "audio/wav", "md": "text/plain", "txt": "text/plain",
    "pdf": "application/pdf", "xml": "application/xml", "wasm": "application/wasm",
  ]

  public static func mimeType(forPath path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    return types[ext] ?? "application/octet-stream"
  }
}
