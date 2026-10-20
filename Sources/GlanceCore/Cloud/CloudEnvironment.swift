import Foundation

/// Where the Glance server runs (spec 2026-10-18-glance-server-core-design.md, "The Mac app"): in Docker on this Mac,
/// or production. A base URL of nil means this build has no such server: Settings says it isn't set up.
public struct CloudEnvironment: Equatable, Sendable {
  public enum Name: String, CaseIterable, Sendable {
    case local, production

    public var title: String {
      switch self {
      case .local: "Local"
      case .production: "Production"
      }
    }
  }

  public let name: Name
  public let baseURL: URL?

  public init(name: Name, baseURL: URL?) {
    self.name = name
    self.baseURL = baseURL
  }

  /// `docker compose --profile server up` in ~/Code/glance-server.
  public static let local = CloudEnvironment(name: .local, baseURL: URL(string: "http://localhost:8080"))

  /// The hosted server: its URL goes here once hosting is chosen.
  public static let production = CloudEnvironment(name: .production, baseURL: nil)

  public var isSetUp: Bool { baseURL != nil }

  /// The Keychain account holding this environment's session: each keeps its own.
  public var keychainAccount: String { "glance-server-\(name.rawValue)" }

  /// `path` ("/v1/me") on this server.
  public func url(_ path: String) -> URL? {
    guard let baseURL else { return nil }
    var base = baseURL.absoluteString
    while base.hasSuffix("/") { base.removeLast() }
    return URL(string: base + path)
  }

  /// Release builds always use production; development builds use what the Develop menu picked, else local.
  public static func current(development: Bool, saved: String?) -> CloudEnvironment {
    guard development else { return .production }
    return saved == Name.production.rawValue ? .production : .local
  }

  public static func named(_ name: Name) -> CloudEnvironment { name == .production ? .production : .local }
}
