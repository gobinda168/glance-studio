import Foundation

/// A row under the Browser's address field.
public struct AddressSuggestion: Equatable, Sendable, Identifiable {
  public enum Kind: Equatable, Sendable {
    /// Return opens the typed address.
    case address
    /// Return (or this row) searches the typed words.
    case search
    /// A saved app, by id.
    case app(String)
    /// An open tab, by tab key.
    case tab(String)
    case history
  }

  public let kind: Kind
  public let title: String
  public let detail: String
  public let url: URL

  public var id: String { "\(kind)|\(url.absoluteString)" }
}

/// The address field's suggestions (spec 2026-10-10-browser-design.md, "Address field").
public enum AddressSuggestions {
  public struct OpenTab: Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: URL

    public init(id: String, title: String, url: URL) {
      self.id = id
      self.title = title
      self.url = url
    }
  }

  /// At most `limit` rows for `text`: first what Return does (open the address, or search), then saved apps, open
  /// tabs and history that match, each address once; when Return opens an address, the search is the last row.
  public static func make(_ text: String, apps: [SavedApp], tabs: [OpenTab], history: [HistoryEntry],
                          engine: SearchEngine, limit: Int = 8) -> [AddressSuggestion] {
    let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !typed.isEmpty, limit > 0, let primary = BrowserURL.resolve(typed, engine: engine) else { return [] }
    let isAddress = BrowserURL.isAddress(typed)
    let search = AddressSuggestion(kind: .search, title: typed, detail: "Search \(engine.title)",
                                   url: engine.url(for: typed))
    var rows = [isAddress ? AddressSuggestion(kind: .address, title: primary.absoluteString, detail: "Open",
                                              url: primary) : search]
    var seen: Set<String> = [key(primary)]
    func add(_ row: AddressSuggestion) {
      guard seen.insert(key(row.url)).inserted else { return }
      rows.append(row)
    }
    let needle = typed.lowercased()
    for app in apps where matches(needle, name: app.name, url: app.url) {
      add(AddressSuggestion(kind: .app(app.id), title: app.name, detail: BrowserURL.displayHost(app.url), url: app.url))
    }
    for tab in tabs where matches(needle, name: tab.title, url: tab.url) {
      let title = tab.title.isEmpty ? BrowserURL.displayHost(tab.url) : tab.title
      add(AddressSuggestion(kind: .tab(tab.id), title: title, detail: "Switch to tab", url: tab.url))
    }
    for entry in history {
      let title = entry.title.isEmpty ? BrowserURL.displayHost(entry.url) : entry.title
      add(AddressSuggestion(kind: .history, title: title, detail: BrowserHistory.bare(entry.url), url: entry.url))
    }
    guard isAddress else { return Array(rows.prefix(limit)) }
    return Array(rows.prefix(max(limit - 1, 1))) + (limit > 1 ? [search] : [])
  }

  /// A name holding the typed text, or an address starting with it (scheme and "www." ignored).
  static func matches(_ needle: String, name: String, url: URL) -> Bool {
    name.lowercased().contains(needle) || BrowserHistory.bare(url).hasPrefix(BrowserHistory.bare(needle))
  }

  /// Two addresses are the same row when they differ only by scheme, "www." or a trailing slash.
  static func key(_ url: URL) -> String {
    var bare = BrowserHistory.bare(url)
    while bare.hasSuffix("/") { bare.removeLast() }
    return bare
  }
}
