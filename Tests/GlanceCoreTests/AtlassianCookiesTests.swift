import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = true,
                    expires: Date? = nil) -> HTTPCookie {
  var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v-\(name)", .domain: domain, .path: path]
  if secure { properties[.secure] = "TRUE" }
  if let expires { properties[.expires] = expires }
  return HTTPCookie(properties: properties)!
}

private func header(_ address: String, _ cookies: [HTTPCookie]) -> String? {
  AtlassianCookies.header(for: URL(string: address)!, cookies: cookies, now: now)
}

private func pairs(_ header: String?) -> Set<String> {
  Set(header?.components(separatedBy: "; ") ?? [])
}

@Test func aDomainCookieGoesToEverySiteUnderItAndAHostCookieOnlyToItsHost() {
  let cookies = [cookie("session", domain: ".atlassian.net"), cookie("acme", domain: "acme.atlassian.net"),
                 cookie("beta", domain: "beta.atlassian.net")]
  #expect(pairs(header("https://acme.atlassian.net/rest/api/2/myself", cookies)) == ["session=v-session", "acme=v-acme"])
  #expect(pairs(header("https://beta.atlassian.net/rest/api/2/myself", cookies)) == ["session=v-session", "beta=v-beta"])
}

@Test func nothingOfAtlassianNetGoesToADataCenterHost() {
  let cookies = [cookie("session", domain: ".atlassian.net"), cookie("acme", domain: "acme.atlassian.net")]
  #expect(header("https://jira.acme.com/rest/api/2/myself", cookies) == nil)
  #expect(header("https://atlassian.net.evil.com/", cookies) == nil)
}

@Test func aSecureCookieNeverGoesOverHTTP() {
  #expect(header("http://jira.acme.com/rest/api/2/myself", [cookie("j", domain: "jira.acme.com")]) == nil)
  #expect(header("http://jira.acme.com/rest/api/2/myself", [cookie("j", domain: "jira.acme.com", secure: false)])
    == "j=v-j")
}

@Test func expiredCookiesStayHome() {
  let cookies = [cookie("old", domain: "jira.acme.com", expires: now.addingTimeInterval(-60)),
                 cookie("fresh", domain: "jira.acme.com", expires: now.addingTimeInterval(60))]
  #expect(header("https://jira.acme.com/", cookies) == "fresh=v-fresh")
}

@Test func pathsMatchBySegmentAndTheLongerGoesFirst() {
  let cookies = [cookie("root", domain: "acme.com", path: "/"), cookie("jira", domain: "acme.com", path: "/jira"),
                 cookie("other", domain: "acme.com", path: "/jiraX")]
  #expect(header("https://acme.com/jira/rest/api/2/myself", cookies) == "jira=v-jira; root=v-root")
  #expect(header("https://acme.com/jira", cookies) == "jira=v-jira; root=v-root")
}

@Test func noMatchingCookieIsNoHeader() {
  #expect(header("https://acme.atlassian.net/", []) == nil)
}
