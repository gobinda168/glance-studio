import Foundation
import Testing
@testable import GlanceCore

private func base(_ typed: String) -> String? { AtlassianAddress.base(typed)?.absoluteString }

@Test func aBareNameIsACloudSite() {
  #expect(base("acme") == "https://acme.atlassian.net")
  #expect(base("  Acme-Corp ") == "https://acme-corp.atlassian.net")
}

@Test func aCloudLinkIsItsSite() {
  #expect(base("acme.atlassian.net") == "https://acme.atlassian.net")
  #expect(base("https://acme.atlassian.net/jira/your-work") == "https://acme.atlassian.net")
  #expect(base("https://acme.atlassian.net/wiki/spaces/ENG/pages/1/Home?focus=1#top") == "https://acme.atlassian.net")
  #expect(base("HTTPS://ACME.atlassian.net/browse/GL-1") == "https://acme.atlassian.net")
}

@Test func aDataCenterLinkKeepsItsContextPath() {
  #expect(base("https://jira.acme.com/secure/Dashboard.jspa") == "https://jira.acme.com")
  #expect(base("https://acme.com/jira/browse/GL-1?filter=1#comment") == "https://acme.com/jira")
  #expect(base("https://acme.com/jira/") == "https://acme.com/jira")
  #expect(base("wiki.acme.com/display/ENG/Home") == "https://wiki.acme.com")
  #expect(base("https://acme.com/confluence/spaces/ENG/pages/1/Home") == "https://acme.com/confluence")
  #expect(base("https://acme.com:8443/jira/login.jsp") == "https://acme.com:8443/jira")
  #expect(base("http://jira.lab.acme.com:8080") == "http://jira.lab.acme.com:8080")
  #expect(base("jira.acme.com:8080/issues/?jql=x") == "https://jira.acme.com:8080")
}

@Test func anythingElseIsNotAnAddress() {
  for typed in ["", "   ", "acme corp", "acme!", "ftp://jira.acme.com", "https://", "mailto:ada@acme.com",
                "ada@acme.com", "https://localhost:8080"] {
    #expect(base(typed) == nil, "\(typed) read as an address")
  }
}

@Test func cloudIsTheAtlassianNetDomain() {
  #expect(AtlassianAddress.isCloud(URL(string: "https://acme.atlassian.net")!))
  #expect(!AtlassianAddress.isCloud(URL(string: "https://jira.acme.com")!))
  #expect(!AtlassianAddress.isCloud(URL(string: "https://atlassian.net.evil.com")!))
}
