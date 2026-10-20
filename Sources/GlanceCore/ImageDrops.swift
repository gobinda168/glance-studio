import Foundation

/// The image files last dropped on a Glance Studio terminal. Claude Code turns a dropped image path into
/// `[Image #N]` and tells a mod nothing, so glance-replies reads this to preview the right picture (and not whatever
/// image is on the clipboard). One small JSON file in Studio's Caches folder: `{"at": <seconds since 1970>,
/// "paths": [...]}`.
public enum ImageDrops {
  public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]

  /// `~/Library/Caches/Glance Studio/image-drops.json`, which glance-replies reads.
  public static func file(caches: URL) -> URL {
    caches.appendingPathComponent("Glance Studio/image-drops.json")
  }

  /// The dropped paths that name images, in order.
  public static func images(in paths: [String]) -> [String] {
    paths.filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
  }

  /// The record for a drop at `date`; nil when nothing dropped is an image.
  public static func record(paths: [String], at date: Date) -> Data? {
    let images = images(in: paths)
    guard !images.isEmpty else { return nil }
    let record: [String: Any] = ["at": date.timeIntervalSince1970, "paths": images]
    return try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
  }

  /// Writes the record for this drop (when it holds an image) where glance-replies looks.
  public static func save(paths: [String], caches: URL, now: Date = Date()) {
    guard let data = record(paths: paths, at: now) else { return }
    let url = file(caches: caches)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }
}
