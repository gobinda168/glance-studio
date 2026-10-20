import Foundation
import Testing
@testable import GlanceCore

private func resolved(_ text: String) -> String? {
  BrowserURL.resolve(text, engine: .duckDuckGo)?.absoluteString
}

@Test func anAddressAsTypedOpensAsIs() {
  #expect(resolved("https://github.com/apple/swift") == "https://github.com/apple/swift")
  #expect(resolved("http://example.com") == "http://example.com")
  #expect(resolved("  HTTPS://Example.com/A  ") == "HTTPS://Example.com/A")
  #expect(resolved("about:blank") == "about:blank")
  #expect(resolved("mailto:a@b.co") == "mailto:a@b.co")
}

@Test func aNameWithADotOpensOnHTTPS() {
  #expect(resolved("github.com") == "https://github.com")
  #expect(resolved("docs.rs/serde") == "https://docs.rs/serde")
  #expect(resolved("example.com:8443/x") == "https://example.com:8443/x")
  #expect(resolved("mail.google.com/mail/u/0/#inbox") == "https://mail.google.com/mail/u/0/#inbox")
}

@Test func typedLocalAddressesOpenOnHTTP() {
  #expect(resolved("localhost") == "http://localhost")
  #expect(resolved("localhost:3000") == "http://localhost:3000")
  #expect(resolved(":5173/app") == "http://localhost:5173/app")
  #expect(resolved("127.0.0.1:8080") == "http://127.0.0.1:8080")
  #expect(resolved("192.168.1.4") == "http://192.168.1.4")
  #expect(resolved("[::1]:3000") == "http://[::1]:3000")
  #expect(resolved("app.localhost:5173") == "http://app.localhost:5173")
}

@Test func numbersAndSentencesSearch() {
  for text in ["1.5", "foo bar", "readme.md file", "swift", "what is 2+2?", "file.", "http://"] {
    let url = BrowserURL.resolve(text, engine: .duckDuckGo)
    #expect(url?.host == "duckduckgo.com", "\(text) should search")
    #expect(!BrowserURL.isAddress(text), "\(text) isn't an address")
  }
  #expect(BrowserURL.resolve("   ", engine: .google) == nil)
  #expect(BrowserURL.isAddress("localhost:3000"))
}

@Test func eachEngineSearchesWithTheWordsEncoded() {
  #expect(SearchEngine.duckDuckGo.url(for: "a b&c").absoluteString == "https://duckduckgo.com/?q=a%20b%26c")
  #expect(SearchEngine.google.url(for: "swift").absoluteString == "https://www.google.com/search?q=swift")
  #expect(SearchEngine.bing.url(for: "swift").absoluteString == "https://www.bing.com/search?q=swift")
  #expect(SearchEngine.kagi.url(for: "swift").absoluteString == "https://kagi.com/search?q=swift")
  #expect(SearchEngine(saved: "google") == .google)
  #expect(SearchEngine(saved: nil) == .duckDuckGo)
  #expect(SearchEngine(saved: "altavista") == .duckDuckGo)
  #expect(SearchEngine.allCases.map(\.title) == ["DuckDuckGo", "Google", "Bing", "Kagi"])
}

@Test func webAddressesStayInTabsAndOtherSchemesGoToMacOS() {
  for text in ["https://a.com", "http://a.com", "about:blank", "data:text/plain,hi", "blob:https://a.com/1"] {
    #expect(BrowserURL.destination(URL(string: text)!) == .tab, "\(text)")
  }
  for text in ["mailto:a@b.co", "tel:123", "zoommtg://zoom.us/join?confno=1", "slack://open", "file:///tmp/x"] {
    #expect(BrowserURL.destination(URL(string: text)!) == .system, "\(text)")
  }
}

@Test func theAddressFieldAtRestShowsTheHost() {
  #expect(BrowserURL.displayHost(URL(string: "https://www.github.com/apple")!) == "github.com")
  #expect(BrowserURL.displayHost(URL(string: "http://localhost:3000/x")!) == "localhost:3000")
  #expect(BrowserURL.displayHost(URL(string: "http://[::1]:3000/")!) == "[::1]:3000")
  #expect(BrowserURL.displayHost(URL(string: "about:blank")!) == "about:blank")
}

@Test func localMeansThisMac() {
  for text in ["http://localhost:3000", "http://app.localhost", "http://127.0.0.1", "http://[::1]:5173"] {
    #expect(BrowserURL.isLocal(URL(string: text)!), "\(text)")
  }
  #expect(!BrowserURL.isLocal(URL(string: "https://localhost.example.com")!))
  #expect(!BrowserURL.isLocal(URL(string: "https://192.168.1.4")!))
}

@Test func iconsAreKeptPerHostAndConfluenceCloudKeepsItsOwn() {
  #expect(BrowserURL.iconKey(URL(string: "https://Acme.atlassian.net/browse/X-1")!) == "acme.atlassian.net")
  #expect(BrowserURL.iconKey(URL(string: "https://acme.atlassian.net/wiki/spaces")!) == "acme.atlassian.net-wiki")
  #expect(BrowserURL.iconKey(URL(string: "http://[::1]:3000")!) == "__1")
  #expect(BrowserURL.iconKey(URL(string: "about:blank")!) == nil)
}
