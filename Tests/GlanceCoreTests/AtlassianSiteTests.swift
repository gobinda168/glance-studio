import Foundation
import Testing
@testable import GlanceCore

private let acme = AtlassianSite.cloud(base: URL(string: "https://acme.atlassian.net")!)
private let beta = AtlassianSite(id: "beta", name: "Beta Jira", flavor: .dataCenter,
                                 jiraURL: URL(string: "https://jira.beta.com")!, confluenceURL: nil, titles: ["Beta Jira"])
private let ada = AtlassianUser(id: "5b10ac8d82e05b22cc7d4ef5", name: nil, displayName: "Ada Lovelace")

@Test func aCloudSiteHasBothProductsAndItsSubdomainForAName() {
  #expect(acme.name == "acme")
  #expect(acme.flavor == .cloud)
  #expect(acme.jiraURL?.absoluteString == "https://acme.atlassian.net")
  #expect(acme.confluenceURL?.absoluteString == "https://acme.atlassian.net/wiki")
  #expect(acme.has(.jira) && acme.has(.confluence))
  #expect(acme.displayAddress == "acme.atlassian.net")
  #expect(!acme.id.isEmpty)
}

@Test func aDataCenterSiteHasOnlyTheAddressesItWasGiven() {
  #expect(beta.has(.jira))
  #expect(!beta.has(.confluence))
  #expect(beta.url(.confluence) == nil)
  #expect(beta.displayAddress == "jira.beta.com")
}

@Test func theDisplayAddressKeepsAPortAndAPath() {
  let site = AtlassianSite(name: "Acme", flavor: .dataCenter, jiraURL: URL(string: "https://acme.com:8443/jira")!,
                           confluenceURL: nil)
  #expect(site.displayAddress == "acme.com:8443/jira")
}

@Test func theOtherProductIsTheOneThatIsntThis() {
  #expect(AtlassianProduct.jira.other == .confluence)
  #expect(AtlassianProduct.confluence.other == .jira)
  #expect(AtlassianProduct.jira.title == "Jira")
  #expect(AtlassianProduct.confluence.title == "Confluence")
}

@Test func sameAddressIgnoresCaseATrailingSlashAndTheDefaultPort() {
  #expect(AtlassianSite.sameAddress(URL(string: "https://ACME.atlassian.net/"), URL(string: "https://acme.atlassian.net")))
  #expect(AtlassianSite.sameAddress(URL(string: "https://jira.beta.com:443"), URL(string: "https://jira.beta.com")))
  #expect(!AtlassianSite.sameAddress(URL(string: "https://jira.beta.com:8443"), URL(string: "https://jira.beta.com")))
  #expect(!AtlassianSite.sameAddress(URL(string: "https://acme.com/jira"), URL(string: "https://acme.com/wiki")))
  #expect(!AtlassianSite.sameAddress(nil, URL(string: "https://acme.com")))
}

@Test func sitesKeepTheOrderTheyWereAdded() {
  var store = AtlassianSiteStore()
  let first = store.add(beta)
  let second = store.add(acme)
  #expect(first.added && second.added)
  #expect(store.sites.map(\.id) == ["beta", acme.id])
}

@Test func addingASiteWithASavedAddressGivesBackTheSavedOne() {
  var store = AtlassianSiteStore(sites: [acme, beta])
  let again = store.add(AtlassianSite.cloud(base: URL(string: "https://ACME.atlassian.net/")!))
  #expect(!again.added)
  #expect(again.site.id == acme.id)
  let betaAgain = store.add(AtlassianSite(name: "Other name", flavor: .dataCenter,
                                          jiraURL: URL(string: "https://jira.beta.com:443/")!, confluenceURL: nil))
  #expect(!betaAgain.added)
  #expect(betaAgain.site.id == "beta")
  #expect(store.sites.count == 2)
}

@Test func renameTrimsAndIgnoresABlankName() {
  var store = AtlassianSiteStore(sites: [beta])
  store.rename(id: "beta", to: "  Beta Labs  ")
  #expect(store.site(id: "beta")?.name == "Beta Labs")
  store.rename(id: "beta", to: "   ")
  #expect(store.site(id: "beta")?.name == "Beta Labs")
}

@Test func theUserAndAnAddressCanChange() {
  var store = AtlassianSiteStore(sites: [beta])
  store.setUser(id: "beta", ada)
  #expect(store.site(id: "beta")?.user == ada)
  store.setAddress(id: "beta", .confluence, URL(string: "https://wiki.beta.com")!, titles: ["Beta Wiki", "Beta Jira"])
  #expect(store.site(id: "beta")?.confluenceURL?.absoluteString == "https://wiki.beta.com")
  #expect(store.site(id: "beta")?.titles == ["Beta Jira", "Beta Wiki"])
  store.setAddress(id: "beta", .confluence, nil)
  #expect(store.site(id: "beta")?.has(.confluence) == false)
  // The last address can't go: a site always has one.
  store.setAddress(id: "beta", .jira, nil)
  #expect(store.site(id: "beta")?.has(.jira) == true)
}

@Test func removeForgetsTheSite() {
  var store = AtlassianSiteStore(sites: [acme, beta])
  store.remove(id: acme.id)
  #expect(store.sites == [beta])
}

@Test func theSiteListRoundTripsThroughItsData() {
  var withUser = beta
  withUser.user = ada
  let store = AtlassianSiteStore(sites: [acme, withUser])
  #expect(AtlassianSiteStore(data: store.encoded()) == store)
}

@Test func damagedDataIsDroppedEntryByEntry() {
  #expect(AtlassianSiteStore(data: nil).sites.isEmpty)
  #expect(AtlassianSiteStore(data: Data("not json".utf8)).sites.isEmpty)
  let mixed = #"""
  [{"id":"a","name":"acme","flavor":"cloud","jiraURL":"https://acme.atlassian.net","confluenceURL":"https://acme.atlassian.net/wiki"},
   {"id":"b","name":"No address","flavor":"dataCenter"},
   {"id":"","name":"No id","flavor":"cloud","jiraURL":"https://x.atlassian.net"},
   {"id":"c","name":"No flavour","jiraURL":"https://jira.c.com"}]
  """#
  let store = AtlassianSiteStore(data: Data(mixed.utf8))
  #expect(store.sites.map(\.id) == ["a"])
  // Saved before sites had titles: still loads, with none.
  #expect(store.sites.first?.titles == [])
}
