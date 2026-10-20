import Foundation

/// Jira or Confluence (spec 2026-10-09-jira-confluence-design.md).
public enum AtlassianProduct: String, Codable, CaseIterable, Sendable {
  case jira, confluence

  public var title: String {
    switch self {
    case .jira: "Jira"
    case .confluence: "Confluence"
    }
  }

  public var other: AtlassianProduct { self == .jira ? .confluence : .jira }
}

/// Who a site is signed in as: Cloud's account id, or Data Center's user key with its user name (Data Center's
/// assignee bodies take the name).
public struct AtlassianUser: Codable, Equatable, Sendable {
  public let id: String
  public let name: String?
  public let displayName: String

  public init(id: String, name: String?, displayName: String) {
    self.id = id
    self.name = name
    self.displayName = displayName
  }
}

/// One company's Atlassian (spec, "Sites"). Cloud has one address, Jira at its root and Confluence under /wiki; Data
/// Center has a Jira address, a Confluence address, or both. `titles` are the names its pages may end their title
/// with (Data Center's site titles), for tab titles.
public struct AtlassianSite: Codable, Equatable, Sendable, Identifiable {
  public enum Flavor: String, Codable, Sendable { case cloud, dataCenter }

  public let id: String
  public var name: String
  public let flavor: Flavor
  public var jiraURL: URL?
  public var confluenceURL: URL?
  public var user: AtlassianUser?
  public var titles: [String]

  public init(id: String = UUID().uuidString, name: String, flavor: Flavor, jiraURL: URL?, confluenceURL: URL?,
              user: AtlassianUser? = nil, titles: [String] = []) {
    self.id = id
    self.name = name
    self.flavor = flavor
    self.jiraURL = jiraURL
    self.confluenceURL = confluenceURL
    self.user = user
    self.titles = titles
  }

  enum CodingKeys: String, CodingKey { case id, name, flavor, jiraURL, confluenceURL, user, titles }

  /// A saved site; one saved before a field existed gets that field's default.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    flavor = try container.decode(Flavor.self, forKey: .flavor)
    jiraURL = try container.decodeIfPresent(URL.self, forKey: .jiraURL)
    confluenceURL = try container.decodeIfPresent(URL.self, forKey: .confluenceURL)
    user = try container.decodeIfPresent(AtlassianUser.self, forKey: .user)
    titles = try container.decodeIfPresent([String].self, forKey: .titles) ?? []
  }

  /// A Cloud site at `base` (`https://<name>.atlassian.net`): both products, named after its subdomain.
  public static func cloud(base: URL) -> AtlassianSite {
    let host = base.host ?? base.absoluteString
    let name = host.split(separator: ".").first.map(String.init) ?? host
    return AtlassianSite(name: name, flavor: .cloud, jiraURL: base, confluenceURL: base.appendingPathComponent("wiki"))
  }

  public func url(_ product: AtlassianProduct) -> URL? {
    switch product {
    case .jira: jiraURL
    case .confluence: confluenceURL
    }
  }

  public func has(_ product: AtlassianProduct) -> Bool { url(product) != nil }

  public mutating func set(_ product: AtlassianProduct, _ url: URL?) {
    switch product {
    case .jira: jiraURL = url
    case .confluence: confluenceURL = url
    }
  }

  /// How people know the site: the Jira address (else Confluence's) without its scheme, with a port and a path.
  public var displayAddress: String {
    guard let url = jiraURL ?? confluenceURL, let host = url.host else { return name }
    let port = url.port.map { ":\($0)" } ?? ""
    let path = url.path == "/" ? "" : url.path
    return host + port + path
  }

  /// The same address, ignoring case, a trailing slash and the scheme's default port.
  public static func sameAddress(_ a: URL?, _ b: URL?) -> Bool {
    guard let a, let b else { return false }
    return key(a) == key(b)
  }

  static func key(_ url: URL) -> String {
    let scheme = url.scheme?.lowercased() ?? "https"
    let host = url.host?.lowercased() ?? ""
    let isDefault = (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
    let port = url.port.map { isDefault ? "" : ":\($0)" } ?? ""
    var path = url.path.lowercased()
    while path.hasSuffix("/") { path.removeLast() }
    return "\(scheme)://\(host)\(port)\(path)"
  }
}

/// The sites in Studio, in the order they were added. The app keeps it in its preferences (`encoded()`,
/// `init(data:)`, under `atlassianSites`).
public struct AtlassianSiteStore: Equatable, Sendable {
  public private(set) var sites: [AtlassianSite]

  public init(sites: [AtlassianSite] = []) {
    self.sites = sites
  }

  /// The stored list. A damaged entry (no id, no address, an unreadable field) is dropped; the rest stay.
  public init(data: Data?) {
    let decoded = data.flatMap { try? JSONDecoder().decode([Lossy].self, from: $0) } ?? []
    self.init(sites: decoded.compactMap(\.site).filter { !$0.id.isEmpty && ($0.jiraURL != nil || $0.confluenceURL != nil) })
  }

  private struct Lossy: Decodable {
    let site: AtlassianSite?
    init(from decoder: Decoder) throws { site = try? AtlassianSite(from: decoder) }
  }

  public func encoded() -> Data {
    (try? JSONEncoder().encode(sites)) ?? Data("[]".utf8)
  }

  public func site(id: String) -> AtlassianSite? {
    sites.first { $0.id == id }
  }

  /// The saved site sharing a Jira or a Confluence address with `site`.
  public func matching(_ site: AtlassianSite) -> AtlassianSite? {
    sites.first { saved in
      AtlassianProduct.allCases.contains { AtlassianSite.sameAddress(saved.url($0), site.url($0)) }
    }
  }

  /// Adds `site` at the end, unless a saved site shares one of its addresses: that one comes back, unchanged.
  @discardableResult
  public mutating func add(_ site: AtlassianSite) -> (site: AtlassianSite, added: Bool) {
    if let saved = matching(site) { return (saved, false) }
    sites.append(site)
    return (site, true)
  }

  /// A new name, trimmed; a blank one is ignored.
  public mutating func rename(id: String, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let index = sites.firstIndex(where: { $0.id == id }) else { return }
    sites[index].name = trimmed
  }

  public mutating func setUser(id: String, _ user: AtlassianUser?) {
    guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
    sites[index].user = user
  }

  /// One product's address (nil removes it, unless it's the site's last) and the titles its pages end with.
  public mutating func setAddress(id: String, _ product: AtlassianProduct, _ url: URL?, titles: [String] = []) {
    guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
    guard url != nil || sites[index].has(product.other) else { return }
    sites[index].set(product, url)
    for title in titles where !sites[index].titles.contains(title) { sites[index].titles.append(title) }
  }

  public mutating func remove(id: String) {
    sites.removeAll { $0.id == id }
  }
}
