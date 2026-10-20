import Foundation
import Testing
@testable import GlanceCore

private let cloud = AtlassianSite.cloud(base: URL(string: "https://acme.atlassian.net")!)
private let dc = AtlassianSite(id: "dc", name: "Acme Jira", flavor: .dataCenter,
                               jiraURL: URL(string: "https://acme.com/jira")!,
                               confluenceURL: URL(string: "https://wiki.acme.com")!, titles: ["Acme Jira", "Acme Wiki"])

private func route(_ address: String, from product: AtlassianProduct = .jira, site: AtlassianSite = cloud,
                   signingIn: Bool = false) -> AtlassianURL.Route {
  AtlassianURL.route(URL(string: address)!, from: product, site: site, signingIn: signingIn)
}

@Test func aCloudSitesOwnPagesStayAndTheOtherProductsGoToItsTab() {
  #expect(route("https://acme.atlassian.net/browse/GL-1") == .stay)
  #expect(route("https://acme.atlassian.net/jira/software/projects/GL/boards/1?selectedIssue=GL-2") == .stay)
  #expect(route("https://acme.atlassian.net/wiki/spaces/ENG/pages/1/Home") == .other(.confluence))
  #expect(route("https://acme.atlassian.net/wiki/spaces/ENG/pages/1/Home", from: .confluence) == .stay)
  #expect(route("https://acme.atlassian.net/browse/GL-1", from: .confluence) == .other(.jira))
}

@Test func atlassiansSignInAndMediaStayAndEverythingElseOpensInTheBrowser() {
  #expect(route("https://id.atlassian.com/login?continue=x") == .stay)
  #expect(route("https://api.media.atlassian.com/file/abc/binary?dl=1") == .stay)
  #expect(route("https://github.com/acme/app/pull/1") == .browser)
  #expect(route("https://beta.atlassian.net/browse/X-1") == .browser)
  #expect(route("mailto:ada@acme.com") == .browser)
  #expect(route("about:blank") == .stay)
}

@Test func whileSigningInEveryWebPageStays() {
  #expect(route("https://accounts.google.com/o/oauth2/auth", signingIn: true) == .stay)
  #expect(route("https://accounts.google.com/o/oauth2/auth", signingIn: false) == .browser)
  // Even the other product's page: the sign-in tab must finish where it is.
  #expect(route("https://acme.atlassian.net/wiki/home", signingIn: true) == .stay)
}

@Test func aDataCenterSiteUnderAPathKeepsOnlyItsOwnAddresses() {
  #expect(route("https://acme.com/jira/browse/GL-1", site: dc) == .stay)
  #expect(route("https://acme.com:443/jira/browse/GL-1", site: dc) == .stay)
  #expect(route("https://acme.com/jiraX/browse/GL-1", site: dc) == .browser)
  #expect(route("https://acme.com/other/app", site: dc) == .browser)
  #expect(route("http://acme.com/jira/browse/GL-1", site: dc) == .browser)
  #expect(route("https://wiki.acme.com/display/ENG/Home", site: dc) == .other(.confluence))
  #expect(route("https://id.atlassian.com/login", site: dc) == .browser)
}

@Test func onOneHostTheLongerBaseWins() {
  let shared = AtlassianSite(name: "Acme", flavor: .dataCenter, jiraURL: URL(string: "https://acme.com")!,
                             confluenceURL: URL(string: "https://acme.com/wiki")!)
  #expect(AtlassianURL.product(of: URL(string: "https://acme.com/wiki/spaces/X/pages/1")!, site: shared) == .confluence)
  #expect(AtlassianURL.product(of: URL(string: "https://acme.com/browse/X-1")!, site: shared) == .jira)
  #expect(AtlassianURL.product(of: URL(string: "https://other.com/browse/X-1")!, site: shared) == nil)
}

@Test func signInPagesOnBothFlavours() {
  func signIn(_ address: String, _ site: AtlassianSite) -> Bool { AtlassianURL.isSignIn(URL(string: address)!, site: site) }
  #expect(signIn("https://id.atlassian.com/login?continue=https%3A%2F%2Facme.atlassian.net", cloud))
  #expect(signIn("https://auth.atlassian.com/authorize?x=1", cloud))
  #expect(!signIn("https://id.atlassian.com/manage-profile/security/api-tokens", cloud))
  #expect(!signIn("https://acme.atlassian.net/browse/GL-1", cloud))
  #expect(signIn("https://acme.com/jira/login.jsp?os_destination=%2Fbrowse%2FGL-1", dc))
  #expect(signIn("https://wiki.acme.com/login.action?os_destination=x", dc))
  #expect(signIn("https://acme.com/jira/plugins/servlet/samlsso?redirectTo=x", dc))
  #expect(!signIn("https://acme.com/jira/secure/Dashboard.jspa", dc))
  #expect(!signIn("https://accounts.google.com/signin", dc))
}
