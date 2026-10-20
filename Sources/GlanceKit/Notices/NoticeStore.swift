import Foundation
import GlanceCore

/// The inbox on disk: `~/Library/Application Support/Glance Studio/notifications.json`. A file that doesn't decode
/// is moved aside to `notifications.json.bak` and the inbox starts empty.
enum NoticeStore {
  static var url: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance Studio", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("notifications.json")
  }

  static func load(from url: URL = url) -> NoticeBook {
    guard let data = try? Data(contentsOf: url) else { return NoticeBook() }
    if let book = NoticeBook.decode(data) { return book }
    let backup = url.appendingPathExtension("bak")
    try? FileManager.default.removeItem(at: backup)
    try? FileManager.default.moveItem(at: url, to: backup)
    return NoticeBook()
  }

  static func save(_ book: NoticeBook, to url: URL = url) {
    let data = book.encoded()
    DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
  }
}
