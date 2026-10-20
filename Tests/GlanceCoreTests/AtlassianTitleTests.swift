import Foundation
import Testing
@testable import GlanceCore

private let cloud = AtlassianSite.cloud(base: URL(string: "https://acme.atlassian.net")!)
private let dc = AtlassianSite(id: "dc", name: "Acme Jira", flavor: .dataCenter,
                               jiraURL: URL(string: "https://acme.com/jira")!,
                               confluenceURL: URL(string: "https://wiki.acme.com")!, titles: ["Acme Jira", "Acme Wiki"])

@Test func anIssueTitleLosesItsSuffixAndItsKeysBrackets() {
  #expect(AtlassianTitle.clean("[GL-142] Checkout fails on 3DS - Jira", product: .jira, site: cloud)
    == "GL-142 Checkout fails on 3DS")
  #expect(AtlassianTitle.clean("[GL-142] Fix login - part 2 - Jira", product: .jira, site: cloud)
    == "GL-142 Fix login - part 2")
  #expect(AtlassianTitle.clean("[GL-1] Summary - Acme Jira", product: .jira, site: dc) == "GL-1 Summary")
  #expect(AtlassianTitle.clean("System Dashboard - Acme Jira", product: .jira, site: dc) == "System Dashboard")
}

@Test func aPageTitleKeepsItsSpace() {
  #expect(AtlassianTitle.clean("Home - Engineering - Confluence", product: .confluence, site: cloud)
    == "Home - Engineering")
  #expect(AtlassianTitle.clean("Add Jira Events | Confluence Data Center 10.2 | Acme Wiki", product: .confluence,
                               site: dc) == "Add Jira Events | Confluence Data Center 10.2")
}

@Test func anEmptyOrLoadingTitleIsTheProduct() {
  #expect(AtlassianTitle.clean("Loading...", product: .jira, site: cloud) == "Jira")
  #expect(AtlassianTitle.clean("  ", product: .confluence, site: cloud) == "Confluence")
  #expect(AtlassianTitle.clean("Jira", product: .jira, site: cloud) == "Jira")
}

@Test func onlyARealKeyLosesItsBrackets() {
  #expect(AtlassianTitle.clean("[not a key] x - Jira", product: .jira, site: cloud) == "[not a key] x")
  #expect(AtlassianTitle.isIssueKey("GL-142"))
  #expect(AtlassianTitle.isIssueKey("A1_B-7"))
  #expect(!AtlassianTitle.isIssueKey("gl-142"))
  #expect(!AtlassianTitle.isIssueKey("GL-"))
  #expect(!AtlassianTitle.isIssueKey("1GL-2"))
}
