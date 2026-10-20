import Foundation

/// A saved app in the Browser's side bar (spec 2026-10-10-browser-design.md, "Saved apps"): a site with a tile and
/// one main tab. An add-on app is a Slack workspace or an Atlassian site's Jira or Confluence; its name and address
/// come from that store (`SavedAppStore.sync`).
public struct SavedApp: Codable, Equatable, Sendable, Identifiable {
  public enum AddOn: Codable, Equatable, Hashable, Sendable {
    case none
    case slack(teamID: String)
    case atlassian(siteID: String, product: AtlassianProduct)
  }

  public let id: String
  public var name: String
  public var url: URL
  public var addOn: AddOn

  public init(id: String = UUID().uuidString, name: String, url: URL, addOn: AddOn = .none) {
    self.id = id
    self.name = name
    self.url = url
    self.addOn = addOn
  }

  /// The tile's letter when there's no icon.
  public var initial: String {
    name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
  }
}

/// The saved apps in the side bar's order. Studio keeps it in Application Support (Browser/apps.json).
public struct SavedAppStore: Equatable, Sendable {
  public private(set) var apps: [SavedApp]

  public init(apps: [SavedApp] = []) {
    self.apps = apps
  }

  /// The saved file. An entry that doesn't decode is dropped and the rest kept; unreadable data is no apps.
  public init(data: Data?) {
    let entries = data.flatMap { try? JSONDecoder().decode([Lossy].self, from: $0) } ?? []
    self.init(apps: entries.compactMap(\.app))
  }

  private struct Lossy: Decodable {
    let app: SavedApp?
    init(from decoder: Decoder) throws { app = try? SavedApp(from: decoder) }
  }

  public func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? encoder.encode(apps)) ?? Data("[]".utf8)
  }

  public func app(id: String) -> SavedApp? { apps.first { $0.id == id } }

  public func app(addOn: SavedApp.AddOn) -> SavedApp? {
    addOn == .none ? nil : apps.first { $0.addOn == addOn }
  }

  /// The plain app saved for the site `url` is on (same host), for the top bar's star.
  public func plainApp(for url: URL) -> SavedApp? {
    guard let host = url.host?.lowercased() else { return nil }
    return apps.first { $0.addOn == .none && $0.url.host?.lowercased() == host }
  }

  /// Adds `app` at the end and returns it; a plain app at the same address, or the add-on's existing tile, comes back
  /// instead.
  @discardableResult
  public mutating func add(_ app: SavedApp) -> SavedApp {
    let existing = app.addOn == .none
      ? apps.first { $0.addOn == .none && $0.url == app.url }
      : self.app(addOn: app.addOn)
    if let existing { return existing }
    apps.append(app)
    return app
  }

  /// A new name, trimmed; a blank one is ignored.
  public mutating func rename(id: String, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let index = apps.firstIndex(where: { $0.id == id }) else { return }
    apps[index].name = trimmed
  }

  public mutating func setURL(id: String, _ url: URL) {
    guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
    apps[index].url = url
  }

  /// Moves the app to `index`, clamped to the list.
  public mutating func move(id: String, to index: Int) {
    guard let from = apps.firstIndex(where: { $0.id == id }) else { return }
    let app = apps.remove(at: from)
    apps.insert(app, at: min(max(index, 0), apps.count))
  }

  public mutating func remove(id: String) {
    apps.removeAll { $0.id == id }
  }

  /// Brings the add-on tiles in line with Slack's workspaces and Atlassian's sites: a tile for each workspace and for
  /// each product a site has (Jira's, then Confluence's), named after them ("Jira", or "Jira · <site>" when two sites
  /// have Jira); tiles whose workspace or site is gone are dropped. Plain apps are untouched. True when anything
  /// changed.
  @discardableResult
  public mutating func sync(slack: [ChatWorkspace], atlassian: [AtlassianSite]) -> Bool {
    let before = apps
    var wanted: [SavedApp.AddOn: (name: String, url: URL)] = [:]
    var order: [SavedApp.AddOn] = []
    for workspace in slack {
      let key = SavedApp.AddOn.slack(teamID: workspace.teamID)
      wanted[key] = (workspace.name, workspace.clientURL)
      order.append(key)
    }
    for product in AtlassianProduct.allCases {
      let sites = atlassian.filter { $0.has(product) }
      for site in sites {
        guard let url = site.url(product) else { continue }
        let key = SavedApp.AddOn.atlassian(siteID: site.id, product: product)
        wanted[key] = (sites.count == 1 ? product.title : "\(product.title) · \(site.name)", url)
        order.append(key)
      }
    }
    apps.removeAll { $0.addOn != .none && wanted[$0.addOn] == nil }
    for index in apps.indices {
      guard let entry = wanted[apps[index].addOn] else { continue }
      apps[index].name = entry.name
      apps[index].url = entry.url
    }
    for key in order where app(addOn: key) == nil {
      if let entry = wanted[key] { apps.append(SavedApp(name: entry.name, url: entry.url, addOn: key)) }
    }
    return apps != before
  }
}

/// A page title's count, for a plain app's tile: "(3) Inbox" → 3, "(99+) Inbox" → 99; nothing else is a count.
public enum TitleBadge {
  public static func count(_ title: String) -> Int? {
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("("), let close = trimmed.firstIndex(of: ")") else { return nil }
    var inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
    if inner.hasSuffix("+") { inner = inner.dropLast() }
    guard let count = Int(inner), count > 0 else { return nil }
    return count
  }
}
