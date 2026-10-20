import Foundation
import GlanceCore

/// Tickets on disk: `~/Library/Application Support/Glance Studio/tickets.json`. A file that doesn't decode is moved
/// aside to `tickets.json.bak` and Tickets starts empty. Prefs live in UserDefaults (`ticketPrefs`).
enum TicketStore {
  static var url: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance Studio", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("tickets.json")
  }

  static func load(from url: URL = url) -> TicketBook {
    guard let data = try? Data(contentsOf: url) else { return TicketBook() }
    if let book = TicketBook.decode(data) { return book }
    let backup = url.appendingPathExtension("bak")
    try? FileManager.default.removeItem(at: backup)
    try? FileManager.default.moveItem(at: url, to: backup)
    return TicketBook()
  }

  static func save(_ book: TicketBook, to url: URL = url) {
    let data = book.encoded()
    DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
  }

  private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard

  static func loadPrefs() -> TicketPrefs {
    guard let data = defaults.data(forKey: "ticketPrefs"),
          let prefs = try? JSONDecoder().decode(TicketPrefs.self, from: data) else { return TicketPrefs() }
    return prefs
  }

  static func savePrefs(_ prefs: TicketPrefs) {
    defaults.set(try? JSONEncoder().encode(prefs), forKey: "ticketPrefs")
  }
}
