import Foundation

/// Which files Glance opens in its editor and which it shows in Quick Look over the window (pictures, PDFs, office
/// documents, media): what a file link in a reply, or a pasted image's caption, opens.
public enum FilePreview {
  /// What Quick Look shows better than an editor: pictures, PDFs, office documents and media. By extension, not by
  /// UTType: `.ts` is an MPEG stream to UTType and TypeScript here, and an unknown extension is no type at all.
  public static let quickLookExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "icns", "svg",
    "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "rtf", "epub",
    "mov", "mp4", "m4v", "mp3", "wav", "m4a", "aiff", "usdz",
  ]

  /// True for everything but `quickLookExtensions`: text, source code, and names with no known extension.
  public static func opensInEditor(_ path: String) -> Bool {
    !quickLookExtensions.contains((path as NSString).pathExtension.lowercased())
  }

  /// The path a `POST /preview` body names (`{"path": "/abs/file.png"}`), when it is an existing regular file.
  public static func requestedPath(_ body: Data, fileManager: FileManager = .default) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let path = object["path"] as? String, path.hasPrefix("/") else { return nil }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
    return path
  }
}
