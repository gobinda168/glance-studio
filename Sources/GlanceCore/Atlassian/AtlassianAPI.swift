import Foundation

/// The REST calls Studio makes to Jira and Confluence (spec 2026-10-09-jira-confluence-design.md, "Sessions and
/// requests"): built and read here, sent by the app's transport (the `Send` closure), so they're tested without a
/// network. Jira through API v2 on both flavours, so fields read the same way.
public enum AtlassianAPI {
  /// Sends a request and answers its body and HTTP status; throws only when the site can't be reached.
  public typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)

  /// How a request says who's asking: the tabs' signed-in session (its cookies, added by the transport), or a
  /// personal token from Settings.
  public enum Credential: Equatable, Sendable {
    case session
    /// Cloud: the account's email and an API token, as HTTP Basic.
    case cloudToken(email: String, token: String)
    /// Data Center: a personal access token, as a Bearer token.
    case personalToken(String)

    /// The Keychain item's text: Cloud's "email<tab>token", Data Center's token; nil for the session.
    public var stored: String? {
      switch self {
      case .session: nil
      case .cloudToken(let email, let token): email + "\t" + token
      case .personalToken(let token): token
      }
    }

    public static func fromStored(_ text: String, flavor: AtlassianSite.Flavor) -> Credential? {
      switch flavor {
      case .cloud:
        let parts = text.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return .cloudToken(email: parts[0], token: parts[1])
      case .dataCenter:
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : .personalToken(token)
      }
    }

    /// The Keychain account of a site's token (service `dev.glance.Glance`).
    public static func keychainAccount(siteID: String) -> String { "atlassian:" + siteID }
  }

  /// A call under `base` (a site's Jira or Confluence address, path prefix kept): JSON in and out, a write marked
  /// for Atlassian's XSRF check, and the credential's Authorization header.
  public static func request(_ base: URL, _ path: String, query: [(String, String)] = [], method: String = "GET",
                             body: Data? = nil, credential: Credential) -> URLRequest {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
    var prefix = components.path
    while prefix.hasSuffix("/") { prefix.removeLast() }
    components.path = prefix + path
    if !query.isEmpty {
      components.percentEncodedQuery = query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
    var request = URLRequest(url: components.url ?? base)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if method != "GET" { request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token") }
    switch credential {
    case .session:
      break
    case .cloudToken(let email, let token):
      let basic = Data("\(email):\(token)".utf8).base64EncodedString()
      request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
    case .personalToken(let token):
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  /// A query value as the server must read it: `+`, `&` and `=` encoded too.
  static func encode(_ text: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=?#")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
  }

  // MARK: Identifying an address

  /// What `/rest/applinks/1.0/manifest` says: the product and the site's title.
  public struct Manifest: Equatable, Sendable {
    public let product: AtlassianProduct
    public let name: String?
  }

  public static func parseManifest(_ data: Data) -> Manifest? {
    guard let object = json(data), let type = object["typeId"] as? String,
          let product = AtlassianProduct(rawValue: type) else { return nil }
    let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return Manifest(product: product, name: name?.isEmpty == false ? name : nil)
  }

  /// What answered at an address (Add a site…).
  public enum Identified: Equatable, Sendable {
    case site(AtlassianSite)
    /// Nothing there says it's Jira or Confluence (or a company sign-in hides it).
    case notAtlassian
    /// The address couldn't be reached: offline, off the VPN, a wrong host.
    case unreachable
  }

  /// A Cloud address is a Cloud site with both products, without asking. Anything else asks the applinks manifest
  /// (anonymous on both flavours) which product it is and what the site is called.
  public static func identify(_ base: URL, send: Send) async -> Identified {
    if AtlassianAddress.isCloud(base) { return .site(.cloud(base: base)) }
    let answer: (Data, Int)
    do {
      answer = try await send(request(base, "/rest/applinks/1.0/manifest", credential: .session))
    } catch {
      return .unreachable
    }
    guard answer.1 == 200, let manifest = parseManifest(answer.0) else { return .notAtlassian }
    var site = Self.site(base, product: manifest.product)
    if let name = manifest.name {
      site.name = name
      site.titles = [name]
    }
    return .site(site)
  }

  /// A Data Center site with only `product`, at `base`, named after its host: when the user says which product an
  /// address is because its manifest is hidden behind a company sign-in.
  public static func site(_ base: URL, product: AtlassianProduct) -> AtlassianSite {
    var site = AtlassianSite(name: base.host ?? base.absoluteString, flavor: .dataCenter, jiraURL: nil,
                             confluenceURL: nil)
    site.set(product, base)
    return site
  }

  // MARK: Who's signed in

  /// A site's sign-in, as the side bars and Settings show it.
  public enum SignIn: Equatable, Sendable {
    case unknown
    case signedIn(AtlassianUser)
    case signedOut
    case unreachable
  }

  /// Asks Jira's `/myself` (else Confluence's `/user/current` for a site without Jira). A user is signed in; 401,
  /// 403, an anonymous user or anything that isn't a user (an SSO page answering for the API) is signed out; no
  /// answer or any other status is unreachable.
  public static func signIn(_ site: AtlassianSite, credential: Credential, send: Send) async -> SignIn {
    let product: AtlassianProduct = site.has(.jira) ? .jira : .confluence
    guard let base = site.url(product) else { return .signedOut }
    let path = product == .jira ? "/rest/api/2/myself" : "/rest/api/user/current"
    let answer: (Data, Int)
    do {
      answer = try await send(request(base, path, credential: credential))
    } catch {
      return .unreachable
    }
    switch answer.1 {
    case 200:
      let user = product == .jira ? parseJiraUser(answer.0) : parseConfluenceUser(answer.0)
      return user.map(SignIn.signedIn) ?? .signedOut
    case 401, 403:
      return .signedOut
    default:
      return .unreachable
    }
  }

  /// Jira's `/myself`: Cloud's `accountId`, else Data Center's `key` (or `name`) and `name`.
  public static func parseJiraUser(_ data: Data) -> AtlassianUser? {
    guard let object = json(data), let display = object["displayName"] as? String else { return nil }
    if let account = object["accountId"] as? String, !account.isEmpty {
      return AtlassianUser(id: account, name: nil, displayName: display)
    }
    guard let key = (object["key"] as? String) ?? (object["name"] as? String) else { return nil }
    return AtlassianUser(id: key, name: object["name"] as? String, displayName: display)
  }

  /// Confluence's `/user/current`: nil for the anonymous user; Cloud's `accountId`, else Data Center's `userKey`
  /// (or `username`) and `username`.
  public static func parseConfluenceUser(_ data: Data) -> AtlassianUser? {
    guard let object = json(data), object["type"] as? String != "anonymous",
          let display = object["displayName"] as? String else { return nil }
    if let account = object["accountId"] as? String, !account.isEmpty {
      return AtlassianUser(id: account, name: nil, displayName: display)
    }
    guard let key = (object["userKey"] as? String) ?? (object["username"] as? String) else { return nil }
    return AtlassianUser(id: key, name: object["username"] as? String, displayName: display)
  }

  static func json(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
