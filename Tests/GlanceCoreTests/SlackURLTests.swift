import Foundation
import Testing
@testable import GlanceCore

private func url(_ s: String) -> URL { URL(string: s)! }

@Test func slacksOwnPagesStay() {
  for address in ["https://app.slack.com/client/T0ACME/C0GEN", "https://slack.com/signin", "https://acme.slack.com/",
                  "https://acme.enterprise.slack.com/sso", "https://a.slack-edge.com/x.js", "about:blank"] {
    #expect(SlackURL.route(url(address), signingIn: false) == .stay, "\(address)")
  }
}

@Test func aSignedInWorkspaceSendsOtherSitesToTheBrowser() {
  #expect(SlackURL.route(url("https://github.com/acme/app/pull/12"), signingIn: false) == .browser)
  #expect(SlackURL.route(url("https://slack.com.evil.example/"), signingIn: false) == .browser)
  #expect(SlackURL.route(url("mailto:someone@example.com"), signingIn: false) == .browser)
  #expect(SlackURL.route(url("slack://channel?team=T0ACME&id=C0GEN"), signingIn: false) == .browser)
}

@Test func signingInKeepsIdentityProvidersInTheView() {
  #expect(SlackURL.route(url("https://accounts.google.com/o/oauth2/auth?x=1"), signingIn: true) == .stay)
  #expect(SlackURL.route(url("https://acme.okta.com/app/slack/sso/saml"), signingIn: true) == .stay)
  #expect(SlackURL.route(url("mailto:help@slack.com"), signingIn: true) == .browser)
}

@Test func fileDownloadsDownload() {
  #expect(SlackURL.route(url("https://files.slack.com/files-pri/T0ACME-F0FILE/download/report.pdf?origin_team=T0ACME"),
                         signingIn: false) == .download)
  #expect(SlackURL.route(url("https://files.slack.com/files-pri/T0ACME-F0FILE/report.pdf"), signingIn: false) == .stay)
}

@Test func theTeamComesFromAClientAddress() {
  #expect(SlackURL.teamID(url("https://app.slack.com/client/T0ACME")) == "T0ACME")
  #expect(SlackURL.teamID(url("https://app.slack.com/client/T0ACME/C0GEN/thread/C0GEN-1700000000.000100")) == "T0ACME")
  #expect(SlackURL.teamID(url("https://app.slack.com/client/E0GRID/C0GEN")) == "E0GRID")
  #expect(SlackURL.teamID(url("https://app.slack.com/client/")) == nil)
  #expect(SlackURL.teamID(url("https://app.slack.com/ssb/redirect")) == nil)
  #expect(SlackURL.teamID(url("https://example.com/client/T0ACME")) == nil)
}

@Test func signInPagesAreRecognised() {
  #expect(SlackURL.isSignIn(url("https://slack.com/signin")))
  #expect(SlackURL.isSignIn(url("https://slack.com/signin#/signin")))
  #expect(SlackURL.isSignIn(url("https://acme.slack.com/sign_in_with_password")))
  #expect(SlackURL.isSignIn(url("https://slack.com/get-started")))
  #expect(SlackURL.isSignIn(url("https://acme.slack.com/sso/saml/start")))
  #expect(!SlackURL.isSignIn(url("https://app.slack.com/client/T0ACME/C0GEN")))
  #expect(SlackURL.signInURL.absoluteString == "https://slack.com/signin")
}

@Test func slackHostsAreSlackAndItsSubdomainsOnly() {
  #expect(SlackURL.isSlackHost("slack.com"))
  #expect(SlackURL.isSlackHost("app.slack.com"))
  #expect(SlackURL.isSlackHost("a.slack-edge.com"))
  #expect(!SlackURL.isSlackHost("notslack.com"))
  #expect(!SlackURL.isSlackHost("slack.com.evil.example"))
  #expect(!SlackURL.isSlackHost(nil))
}

@Test func aNewWindowForASlackPageOpensInTheSameView() {
  // Slack's workspace picker opens the chosen workspace with window.open (seen in the probe).
  let launch = url("https://app.slack.com/t/engagehub-talk/login/z-app-716?entry_point=redirect_flow")
  #expect(SlackURL.newWindow(launch, signingIn: true) == .sameView)
  #expect(SlackURL.newWindow(url("https://acme.slack.com/archives/C0GEN"), signingIn: false) == .sameView)
}

@Test func aNewWindowForAnIdentityProviderIsAPopUpWhileSigningIn() {
  #expect(SlackURL.newWindow(url("https://acme.okta.com/app/slack/sso/saml"), signingIn: true) == .popUp)
  #expect(SlackURL.newWindow(url("about:blank"), signingIn: false) == .popUp)
}

@Test func aNewWindowForAnotherSiteGoesToTheBrowser() {
  #expect(SlackURL.newWindow(url("https://github.com/acme/app/pull/12"), signingIn: false) == .browser)
  #expect(SlackURL.newWindow(url("mailto:someone@example.com"), signingIn: true) == .browser)
}
