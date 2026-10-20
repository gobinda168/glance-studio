import Foundation
import Testing
@testable import GlanceCore

/// A site on no network: answers by path, records each request.
private actor FakeSite {
  private let answers: [String: (Int, String)]
  private let unreachable: Bool
  private(set) var requests: [URLRequest] = []

  init(_ answers: [String: (Int, String)] = [:], unreachable: Bool = false) {
    self.answers = answers
    self.unreachable = unreachable
  }

  func send(_ request: URLRequest) throws -> (Data, Int) {
    requests.append(request)
    if unreachable { throw URLError(.cannotConnectToHost) }
    guard let answer = answers[request.url?.path ?? ""] else { return (Data(), 404) }
    return (Data(answer.1.utf8), answer.0)
  }
}

private let cloud = AtlassianSite.cloud(base: URL(string: "https://acme.atlassian.net")!)
private let wikiOnly = AtlassianSite(id: "w", name: "Acme Wiki", flavor: .dataCenter, jiraURL: nil,
                                     confluenceURL: URL(string: "https://wiki.acme.com")!)
private let cloudUser = #"{"accountId":"5b10ac8d82e05b22cc7d4ef5","displayName":"Ada Lovelace","emailAddress":"ada@acme.com"}"#
private let dcUser = #"{"key":"JIRAUSER10100","name":"ada","displayName":"Ada Lovelace"}"#

@Test func requestsKeepTheSitesPathAndPort() {
  let request = AtlassianAPI.request(URL(string: "https://acme.com:8443/jira")!, "/rest/api/2/myself",
                                     credential: .session)
  #expect(request.url?.absoluteString == "https://acme.com:8443/jira/rest/api/2/myself")
  #expect(request.httpMethod == "GET")
  #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
  #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  #expect(request.value(forHTTPHeaderField: "X-Atlassian-Token") == nil)
  let wiki = AtlassianAPI.request(URL(string: "https://acme.atlassian.net/wiki/")!, "/rest/api/search",
                                  credential: .session)
  #expect(wiki.url?.absoluteString == "https://acme.atlassian.net/wiki/rest/api/search")
}

@Test func queryValuesAreEncodedLiterally() {
  let jql = #"summary ~ "a+b" AND x = 1 & y"#
  let request = AtlassianAPI.request(URL(string: "https://acme.atlassian.net")!, "/rest/api/2/search/jql",
                                     query: [("jql", jql), ("maxResults", "50")], credential: .session)
  let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
  #expect(components.percentEncodedQuery == "jql=summary%20~%20%22a%2Bb%22%20AND%20x%20%3D%201%20%26%20y&maxResults=50")
  #expect(components.queryItems?.first?.value == jql)
}

@Test func writesCarryTheNoCheckHeaderAndJSON() {
  let body = Data(#"{"transition":{"id":"31"}}"#.utf8)
  let request = AtlassianAPI.request(URL(string: "https://jira.acme.com")!, "/rest/api/2/issue/GL-1/transitions",
                                     method: "POST", body: body, credential: .session)
  #expect(request.httpMethod == "POST")
  #expect(request.value(forHTTPHeaderField: "X-Atlassian-Token") == "no-check")
  #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
  #expect(request.httpBody == body)
}

@Test func tokensBecomeAuthorizationHeaders() {
  let base = URL(string: "https://acme.atlassian.net")!
  let basic = AtlassianAPI.request(base, "/rest/api/2/myself",
                                   credential: .cloudToken(email: "ada@acme.com", token: "t0k"))
  #expect(basic.value(forHTTPHeaderField: "Authorization") == "Basic YWRhQGFjbWUuY29tOnQwaw==")
  let bearer = AtlassianAPI.request(base, "/rest/api/2/myself", credential: .personalToken("pat"))
  #expect(bearer.value(forHTTPHeaderField: "Authorization") == "Bearer pat")
}

@Test func aStoredTokenComesBackForItsFlavour() {
  let cloudToken = AtlassianAPI.Credential.cloudToken(email: "ada@acme.com", token: "t0k")
  #expect(cloudToken.stored == "ada@acme.com\tt0k")
  #expect(AtlassianAPI.Credential.fromStored("ada@acme.com\tt0k", flavor: .cloud) == cloudToken)
  #expect(AtlassianAPI.Credential.fromStored("pat ", flavor: .dataCenter) == .personalToken("pat"))
  #expect(AtlassianAPI.Credential.fromStored("no tab here", flavor: .cloud) == nil)
  #expect(AtlassianAPI.Credential.fromStored("  ", flavor: .dataCenter) == nil)
  #expect(AtlassianAPI.Credential.session.stored == nil)
  #expect(AtlassianAPI.Credential.keychainAccount(siteID: "abc") == "atlassian:abc")
}

@Test func theManifestNamesTheProduct() {
  #expect(AtlassianAPI.parseManifest(Data(#"{"typeId":"jira","name":"Acme Jira"}"#.utf8))
    == AtlassianAPI.Manifest(product: .jira, name: "Acme Jira"))
  #expect(AtlassianAPI.parseManifest(Data(#"{"typeId":"confluence","name":"Acme Wiki"}"#.utf8))?.product == .confluence)
  #expect(AtlassianAPI.parseManifest(Data(#"{"typeId":"jira","name":"  "}"#.utf8))?.name == nil)
  #expect(AtlassianAPI.parseManifest(Data(#"{"typeId":"bamboo"}"#.utf8)) == nil)
  #expect(AtlassianAPI.parseManifest(Data("<html>Sign in</html>".utf8)) == nil)
}

@Test func aCloudAddressIsACloudSiteWithoutAsking() async {
  let fake = FakeSite()
  let result = await AtlassianAPI.identify(URL(string: "https://acme.atlassian.net")!, send: { try await fake.send($0) })
  guard case .site(let site) = result else { Issue.record("not a site: \(result)"); return }
  #expect(site.flavor == .cloud)
  #expect(site.name == "acme")
  #expect(await fake.requests.isEmpty)
}

@Test func aDataCenterAddressIsWhatItsManifestSays() async {
  let jira = FakeSite(["/jira/rest/applinks/1.0/manifest": (200, #"{"typeId":"jira","name":"Acme Jira"}"#)])
  let result = await AtlassianAPI.identify(URL(string: "https://acme.com/jira")!, send: { try await jira.send($0) })
  guard case .site(let site) = result else { Issue.record("not a site: \(result)"); return }
  #expect(site.flavor == .dataCenter)
  #expect(site.name == "Acme Jira")
  #expect(site.titles == ["Acme Jira"])
  #expect(site.jiraURL?.absoluteString == "https://acme.com/jira")
  #expect(site.confluenceURL == nil)
  #expect(await jira.requests.first?.value(forHTTPHeaderField: "Accept") == "application/json")

  let wiki = FakeSite(["/rest/applinks/1.0/manifest": (200, #"{"typeId":"confluence"}"#)])
  let wikiResult = await AtlassianAPI.identify(URL(string: "https://wiki.acme.com")!, send: { try await wiki.send($0) })
  guard case .site(let wikiSite) = wikiResult else { Issue.record("not a site: \(wikiResult)"); return }
  #expect(wikiSite.confluenceURL?.absoluteString == "https://wiki.acme.com")
  #expect(wikiSite.jiraURL == nil)
  #expect(wikiSite.name == "wiki.acme.com")
}

@Test func anAddressThatIsntAtlassianOrCantBeReached() async {
  let missing = FakeSite()
  #expect(await AtlassianAPI.identify(URL(string: "https://jira.acme.com")!, send: { try await missing.send($0) })
    == .notAtlassian)
  let html = FakeSite(["/rest/applinks/1.0/manifest": (200, "<html>Okta</html>")])
  #expect(await AtlassianAPI.identify(URL(string: "https://jira.acme.com")!, send: { try await html.send($0) })
    == .notAtlassian)
  let offline = FakeSite(unreachable: true)
  #expect(await AtlassianAPI.identify(URL(string: "https://jira.acme.com")!, send: { try await offline.send($0) })
    == .unreachable)
}

@Test func aNamedProductMakesADataCenterSiteAtThatAddress() {
  let site = AtlassianAPI.site(URL(string: "https://jira.acme.com")!, product: .jira)
  #expect(site.flavor == .dataCenter)
  #expect(site.jiraURL?.absoluteString == "https://jira.acme.com")
  #expect(site.confluenceURL == nil)
  #expect(site.name == "jira.acme.com")
}

@Test func usersOnBothProductsAndFlavours() {
  #expect(AtlassianAPI.parseJiraUser(Data(cloudUser.utf8))
    == AtlassianUser(id: "5b10ac8d82e05b22cc7d4ef5", name: nil, displayName: "Ada Lovelace"))
  #expect(AtlassianAPI.parseJiraUser(Data(dcUser.utf8))
    == AtlassianUser(id: "JIRAUSER10100", name: "ada", displayName: "Ada Lovelace"))
  #expect(AtlassianAPI.parseConfluenceUser(Data(#"{"type":"anonymous","displayName":"Anonymous"}"#.utf8)) == nil)
  #expect(AtlassianAPI.parseConfluenceUser(Data(#"{"type":"known","accountId":"5b10","displayName":"Ada"}"#.utf8))
    == AtlassianUser(id: "5b10", name: nil, displayName: "Ada"))
  #expect(AtlassianAPI.parseConfluenceUser(
    Data(#"{"type":"known","username":"ada","userKey":"8a7f808a","displayName":"Ada"}"#.utf8))
    == AtlassianUser(id: "8a7f808a", name: "ada", displayName: "Ada"))
  #expect(AtlassianAPI.parseJiraUser(Data("<html></html>".utf8)) == nil)
}

@Test func everyKindOfNotSignedInAnswerIsSignedOut() async {
  let answers: [(Int, String)] = [
    (401, "Client must be authenticated to access this resource."),
    (401, #"{"message":"Client must be authenticated to access this resource.","status-code":401}"#),
    (200, "<html><body>Sign in with your company account</body></html>"),
    (403, ""),
  ]
  for answer in answers {
    let fake = FakeSite(["/rest/api/2/myself": answer])
    #expect(await AtlassianAPI.signIn(cloud, credential: .session, send: { try await fake.send($0) }) == .signedOut,
            "\(answer) wasn't signed out")
  }
  let anonymous = FakeSite(["/rest/api/user/current": (200, #"{"type":"anonymous","displayName":"Anonymous"}"#)])
  #expect(await AtlassianAPI.signIn(wikiOnly, credential: .session, send: { try await anonymous.send($0) })
    == .signedOut)
}

@Test func aSiteThatDoesntAnswerIsUnreachableNotSignedOut() async {
  let offline = FakeSite(unreachable: true)
  #expect(await AtlassianAPI.signIn(cloud, credential: .session, send: { try await offline.send($0) }) == .unreachable)
  let down = FakeSite(["/rest/api/2/myself": (503, "Service Unavailable")])
  #expect(await AtlassianAPI.signIn(cloud, credential: .session, send: { try await down.send($0) }) == .unreachable)
}

@Test func aSignedInSiteSaysWhoAndTheCheckUsesTheCredential() async {
  let fake = FakeSite(["/rest/api/2/myself": (200, cloudUser)])
  let state = await AtlassianAPI.signIn(cloud, credential: .personalToken("pat"), send: { try await fake.send($0) })
  #expect(state == .signedIn(AtlassianUser(id: "5b10ac8d82e05b22cc7d4ef5", name: nil, displayName: "Ada Lovelace")))
  #expect(await fake.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer pat")
  #expect(await fake.requests.first?.url?.absoluteString == "https://acme.atlassian.net/rest/api/2/myself")
}
