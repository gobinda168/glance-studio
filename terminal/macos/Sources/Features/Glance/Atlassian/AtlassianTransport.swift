import Foundation
import GlanceCore
import WebKit

/// Sends Atlassian REST calls as the user (spec 2026-10-09-jira-confluence-design.md, "Sessions and requests"). A
/// call with no Authorization header (no personal token) carries the cookies the Atlassian tabs signed in with, read
/// from their data store; cookies the server sets go back into that store, so the tabs and the side bars share one
/// session.
final class AtlassianTransport: @unchecked Sendable {
    /// Touched on the main actor only (`cookies()`, `keep(_:)`).
    private let dataStore: WKWebsiteDataStore
    private let session: URLSession

    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    /// `AtlassianAPI.Send`: the answer's body and status; throws when the site can't be reached.
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        var request = request
        if request.value(forHTTPHeaderField: "Authorization") == nil, let url = request.url,
           let header = AtlassianCookies.header(for: url, cookies: await cookies()) {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if let http, let url = http.url ?? request.url, let fields = http.allHeaderFields as? [String: String] {
            let set = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            if !set.isEmpty { await keep(set) }
        }
        return (data, http?.statusCode ?? 0)
    }

    @MainActor private func cookies() async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies()
    }

    @MainActor private func keep(_ cookies: [HTTPCookie]) async {
        for cookie in cookies { await dataStore.httpCookieStore.setCookie(cookie) }
    }
}
