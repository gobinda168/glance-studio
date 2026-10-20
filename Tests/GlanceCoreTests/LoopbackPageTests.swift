import Testing
@testable import GlanceCore

@Test func theCallbackPageEscapesWhatItShows() {
  let html = LoopbackPage.html(title: "Sign-in didn't finish", line: "Bad <script>&\"")
  #expect(html.contains("Sign-in didn&#39;t finish"))
  #expect(html.contains("Bad &lt;script&gt;&amp;&quot;"))
  #expect(!html.contains("<script>"))
}

@Test func pkceMovedOutOfGoogleAuthUnchanged() {
  #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  #expect(GoogleAuth.challenge(for: "abc") == PKCE.challenge(for: "abc"))
  #expect(PKCE.randomToken().count == 43)
}
