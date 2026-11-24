import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ImageIntake {
  public static func isImage(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true
  }

  /// The path as the terminal wants it typed (spaces escaped), so Claude Code reads it as one image path.
  public static func token(for path: String) -> String {
    path.replacingOccurrences(of: " ", with: "\\ ")
  }

  public static func thumbnail(_ url: URL) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceThumbnailMaxPixelSize: 64,
                                    kCGImageSourceCreateThumbnailWithTransform: true]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
      .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
  }

  private static func imageFiles(_ pasteboard: NSPasteboard) -> [URL] {
    pasteboard.readObjects(forClasses: [NSURL.self], options: [
      .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL] ?? []
  }

  /// Image files on a pasteboard, else pasted image data written to a temp file; nil when there is neither.
  public static func urls(from pasteboard: NSPasteboard) -> [URL]? {
    let files = imageFiles(pasteboard)
    if !files.isEmpty { return files }
    guard let data = imageData(pasteboard) else { return nil }
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("glance-paste-\(UUID().uuidString).png")
    guard (try? data.write(to: url)) != nil else { return nil }
    return [url]
  }

  /// Cheap check for drag-over: would `urls(from:)` find an image?
  public static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
    !imageFiles(pasteboard).isEmpty
      || (pasteboard.types?.contains { $0 == .png || $0 == .tiff } == true && !hasRealText(pasteboard))
  }

  /// Text on the pasteboard that should paste as text. An image copied from a browser carries its address as text
  /// too; that one is still an image.
  private static func hasRealText(_ pasteboard: NSPasteboard) -> Bool {
    guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return false }
    let isAddress = !text.contains(where: \.isWhitespace)
      && (text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("file://") || text.hasPrefix("data:image/"))
    return !isAddress
  }

  private static func imageData(_ pasteboard: NSPasteboard) -> Data? {
    guard !hasRealText(pasteboard) else { return nil }
    if let png = pasteboard.data(forType: .png) { return png }
    guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }
}
