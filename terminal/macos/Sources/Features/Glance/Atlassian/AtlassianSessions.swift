import AppKit
import Combine
import GlanceCore
import WebKit

/// Every Atlassian site in Studio (spec 2026-10-09-jira-confluence-design.md, "Sites", "Sessions and requests"): the
/// saved sites, each one's sign-in, the data store every Atlassian tab shares, and the transport the side bars use.
@MainActor
final class AtlassianSessions: ObservableObject {
    static let shared = AtlassianSessions()
    /// Every Atlassian tab's persistent data store; the S0 probe used the same one, so its sign-in carries over.
    static let dataStoreID = UUID(uuidString: "A71A55A1-2E0C-4F5B-9C1D-6A7B5D0C0A11")!

    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard
    private static let storeKey = "atlassianSites"

    @Published private(set) var store: AtlassianSiteStore
    /// Each site's sign-in, by id; a site not checked yet is `.unknown`.
    @Published private(set) var signIns: [String: AtlassianAPI.SignIn] = [:]
    let dataStore = WKWebsiteDataStore(forIdentifier: dataStoreID)
    private(set) lazy var transport = AtlassianTransport(dataStore: dataStore)
    private var checking: Set<String> = []
    private var started = false

    private init() {
        store = AtlassianSiteStore(data: Self.defaults.data(forKey: Self.storeKey))
    }

    /// At launch, and when the Develop menu switches Jira & Confluence on: each site's sign-in is checked.
    func start() {
        guard !started else { return }
        started = true
        store.sites.forEach { refresh($0.id) }
    }

    func signIn(_ id: String) -> AtlassianAPI.SignIn { signIns[id] ?? .unknown }

    /// `AtlassianAPI`'s way to the network: the transport.
    var send: AtlassianAPI.Send {
        let transport = transport
        return { try await transport.send($0) }
    }

    /// Asks the site who's signed in (its token, else the tabs' session) and keeps the answer, and the user on the
    /// site. A check already running for the site isn't started again.
    func refresh(_ id: String) {
        guard let site = store.site(id: id), !checking.contains(id) else { return }
        checking.insert(id)
        let credential = credential(for: site)
        let send = send
        Task { [weak self] in
            let state = await AtlassianAPI.signIn(site, credential: credential, send: send)
            self?.apply(state, to: id)
        }
    }

    private func apply(_ state: AtlassianAPI.SignIn, to id: String) {
        checking.remove(id)
        guard store.site(id: id) != nil else { return }
        signIns[id] = state
        if case .signedIn(let user) = state, store.site(id: id)?.user != user {
            store.setUser(id: id, user)
            save()
        }
    }

    /// A tab landed on a sign-in page: signed out until a check finds otherwise.
    func signedOut(_ id: String) {
        if signIns[id] != .signedOut { signIns[id] = .signedOut }
    }

    /// Adds `site`, or finds the saved site with one of its addresses; the saved one comes back.
    @discardableResult
    func add(_ site: AtlassianSite) -> AtlassianSite {
        let (saved, added) = store.add(site)
        if added {
            save()
            refresh(saved.id)
        }
        return saved
    }

    func rename(_ id: String, to name: String) {
        store.rename(id: id, to: name)
        save()
    }

    /// A Data Center site's other product: its address and the titles its pages end with; then a new check.
    func setAddress(_ id: String, _ product: AtlassianProduct, _ url: URL?, titles: [String] = []) {
        store.setAddress(id: id, product, url, titles: titles)
        save()
        refresh(id)
    }

    /// Forgets the site: its tabs close and its token goes; the sign-in cookies stay in the data store.
    func remove(_ id: String) {
        BrowserTabController.closeTabs(atlassianSite: id)
        Self.keychain(id).delete()
        store.remove(id: id)
        signIns[id] = nil
        save()
    }

    // MARK: Personal tokens

    func hasToken(_ id: String) -> Bool { Self.keychain(id).exists() }

    /// Settings' personal token for a site, kept in the Keychain (nil removes it); the sign-in is checked again.
    func setToken(_ credential: AtlassianAPI.Credential?, for id: String) {
        if let text = credential?.stored {
            Self.keychain(id).save(text)
        } else {
            Self.keychain(id).delete()
        }
        objectWillChange.send()
        refresh(id)
    }

    /// How calls to `site` say who's asking: its saved token, else the tabs' session.
    func credential(for site: AtlassianSite) -> AtlassianAPI.Credential {
        Self.keychain(site.id).read().flatMap { AtlassianAPI.Credential.fromStored($0, flavor: site.flavor) }
            ?? .session
    }

    private static func keychain(_ id: String) -> KeychainStore {
        KeychainStore(service: "dev.glance.Glance", account: AtlassianAPI.Credential.keychainAccount(siteID: id))
    }

    // MARK: Pages

    /// A new tab's configuration: the shared data store, and Safari's user agent so Atlassian serves its full app.
    func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = StudioWebView.safariApplicationName
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    private func save() {
        Self.defaults.set(store.encoded(), forKey: Self.storeKey)
    }
}
