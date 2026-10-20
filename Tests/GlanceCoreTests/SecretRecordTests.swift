import Foundation
import Testing
@testable import GlanceCore

@Suite struct SecretRecordTests {
  static func record(name: String = "GITHUB_TOKEN", value: String = "ghp_abcdefghijklmnop",
                     hosts: [String] = ["api.github.com"], slot: SecretSlot = .bearer, folders: [String] = [],
                     approval: SecretApproval = .everyTime) -> SecretRecord {
    SecretRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: name, note: "GitHub",
                 value: value, hosts: hosts, slot: slot, folders: folders, approval: approval,
                 created: Date(timeIntervalSince1970: 0), updated: Date(timeIntervalSince1970: 0))
  }

  @Test func slotsRenderTheirOneHeader() {
    #expect(SecretSlot.bearer.header(value: "v1234567") == ("Authorization", "Bearer v1234567"))
    #expect(SecretSlot.header(name: "X-API-Key", prefix: "").header(value: "v1234567") == ("X-API-Key", "v1234567"))
    #expect(SecretSlot.header(name: "X-Token", prefix: "Token ").header(value: "v1234567") == ("X-Token", "Token v1234567"))
    #expect(SecretSlot.basic(username: "me").header(value: "v1234567")
      == ("Authorization", "Basic " + Data("me:v1234567".utf8).base64EncodedString()))
    #expect(SecretSlot.bearer.summary == "bearer")
    #expect(SecretSlot.header(name: "X-API-Key", prefix: "").summary == "header X-API-Key")
    #expect(SecretSlot.basic(username: "me").summary == "basic")
  }

  @Test func namesAreUpperSnakeCase() {
    #expect(SecretRecord.validName("GITHUB_TOKEN"))
    #expect(SecretRecord.validName("A"))
    #expect(SecretRecord.validName("STRIPE_KEY_2"))
    for bad in ["", "github_token", "1TOKEN", "_TOKEN", "MY-TOKEN", "MY TOKEN", String(repeating: "A", count: 65)] {
      #expect(!SecretRecord.validName(bad), "\(bad)")
    }
  }

  @Test func aGoodRecordHasNoProblems() {
    #expect(Self.record().problems(otherNames: []) == [])
  }

  @Test func problemsAreSentencesForTheSheet() {
    #expect(Self.record(name: "bad").problems(otherNames: [])
      == ["The name must be capital letters, digits and _, starting with a letter (like GITHUB_TOKEN)."])
    #expect(Self.record().problems(otherNames: ["GITHUB_TOKEN"]) == ["Another secret is already called GITHUB_TOKEN."])
    #expect(Self.record(value: "short").problems(otherNames: []) == ["The value must be at least 8 characters."])
    #expect(Self.record(hosts: []).problems(otherNames: []) == ["Add at least one host it may be sent to."])
    #expect(Self.record(hosts: ["localhost"]).problems(otherNames: [])
      == ["localhost: local and private addresses are never allowed."])
  }

  @Test func valuesAndSlotsThatWouldInjectAHeaderAreRefused() {
    #expect(Self.record(value: "abcdefgh\r\nX-Evil: 1").problems(otherNames: [])
      == ["The value can't contain line breaks."])
    #expect(Self.record(slot: .header(name: "X-Key", prefix: "a\nb")).problems(otherNames: [])
      == ["The header prefix can't contain line breaks."])
    for name in ["X Key", "X-Key:", "", "Host", "content-length", "Transfer-Encoding", "Connection"] {
      #expect(Self.record(slot: .header(name: name, prefix: "")).problems(otherNames: [])
        == ["\"\(name)\" can't be the header name."], "\(name)")
    }
    #expect(Self.record(slot: .basic(username: "a:b")).problems(otherNames: [])
      == ["The username can't contain : or line breaks."])
  }

  @Test func graphemeTricksDontSlipPastTheChecks() {
    // A combining mark glues onto ":" and "\r\n" is one Character; both must still be caught as scalars.
    #expect(Self.record(slot: .basic(username: "a:\u{301}b")).problems(otherNames: [])
      == ["The username can't contain : or line breaks."])
    #expect(Self.record(slot: .basic(username: "a\r\nb")).problems(otherNames: [])
      == ["The username can't contain : or line breaks."])
    #expect(Self.record(slot: .header(name: "X-Key", prefix: "a\r\nb")).problems(otherNames: [])
      == ["The header prefix can't contain line breaks."])
    #expect(Self.record(slot: .header(name: "X-Key\r\n", prefix: "")).problems(otherNames: []).count == 1)
    #expect(!SecretHostRule.allows(host: "api.github.com\u{301}", patterns: ["api.github.com"]))
  }

  @Test func everyControlScalarButTabIsRefusedInHeaderValues() {
    for bad in ["\u{0B}", "\u{0C}", "\u{01}", "\u{7F}", "\u{85}", "\u{2028}", "\u{2029}"] {
      #expect(Self.record(value: "abcdefgh\(bad)X").problems(otherNames: []) == ["The value can't contain line breaks."],
              "value \(bad.unicodeScalars.first!.value)")
      #expect(Self.record(slot: .header(name: "X-Key", prefix: "a\(bad)b")).problems(otherNames: [])
        == ["The header prefix can't contain line breaks."], "prefix \(bad.unicodeScalars.first!.value)")
    }
    #expect(Self.record(value: "abcd\tefgh").problems(otherNames: []) == [])
    #expect(Self.record(slot: .header(name: "X-Key", prefix: "a\tb")).problems(otherNames: []) == [])
  }

  @Test func nonASCIIHostsAreRefusedBeforeLowercasing() {
    // U+212A KELVIN SIGN lowercases to ASCII "k".
    #expect(SecretHostRule.normalize("\u{212A}ey.example.com") == nil)
    #expect(!SecretHostRule.allows(host: "\u{212A}ey.example.com", patterns: ["key.example.com"]))
    #expect(SecretHostRule.problem(pattern: "\u{212A}ey.example.com") != nil)
    #expect(Self.record(hosts: ["\u{212A}ey.example.com"]).problems(otherNames: []).count == 1)
  }

  @Test func foldersMustBeAbsolutePaths() {
    #expect(Self.record(folders: [""]).problems(otherNames: [])
      == ["\"\": a folder must be an absolute path, like /Users/me/Code/acme."])
    #expect(Self.record(folders: ["relative/path"]).problems(otherNames: [])
      == ["\"relative/path\": a folder must be an absolute path, like /Users/me/Code/acme."])
    #expect(Self.record(folders: ["/Users/me/Code/acme"]).problems(otherNames: []) == [])
    // Defensive: even if an unusable fence got stored, it never matches.
    #expect(!Self.record(folders: [""]).allows(folder: "/Users/me"))
    #expect(!Self.record(folders: ["relative"]).allows(folder: "relative/x"))
  }

  @Test func aSecretHasAtMostTwentyHostsAndTwentyFolders() {
    let hosts = (1...20).map { "h\($0).example.com" }
    let folders = (1...20).map { "/Users/me/Code/p\($0)" }
    #expect(Self.record(hosts: hosts, folders: folders).problems(otherNames: []) == [])
    #expect(Self.record(hosts: hosts + ["h21.example.com"]).problems(otherNames: [])
      == ["A secret can have at most 20 hosts."])
    #expect(Self.record(folders: folders + ["/Users/me/Code/p21"]).problems(otherNames: [])
      == ["A secret can have at most 20 folders."])
  }

  @Test func theDraftRefusesMoreThanTwentyHostsOrFolders() {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.value = "ghp_abcdefghijklmnop"
    // Repeats count once.
    draft.hosts = (1...20).map { "h\($0).example.com" }.joined(separator: ", ") + ", h1.example.com"
    draft.folders = (1...20).map { "/Users/me/Code/p\($0)" } + ["/Users/me/Code/p1"]
    let now = Date(timeIntervalSince1970: 0)
    guard case .success = draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil)
    else { Issue.record("20 unique hosts and folders should save"); return }
    draft.hosts += " h21.example.com"
    draft.folders.append("/Users/me/Code/p21")
    guard case .failure(let problems) = draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil)
    else { Issue.record("21 hosts and folders should be refused"); return }
    #expect(problems == ["A secret can have at most 20 hosts.", "A secret can have at most 20 folders."])
  }

  @Test func foldersFenceWhereItCanBeUsed() {
    let anywhere = Self.record(folders: [])
    #expect(anywhere.allows(folder: nil))
    #expect(anywhere.allows(folder: "/Users/me/Code/acme"))
    let fenced = Self.record(folders: ["/Users/me/Code/acme"])
    #expect(fenced.allows(folder: "/Users/me/Code/acme"))
    #expect(fenced.allows(folder: "/Users/me/Code/acme/web"))
    #expect(fenced.allows(folder: "/Users/me/Code/acme/"))
    #expect(!fenced.allows(folder: "/Users/me/Code/acme-evil"))
    #expect(!fenced.allows(folder: "/Users/me/Code"))
    #expect(!fenced.allows(folder: nil))
  }

  @Test func recordsRoundTripThroughJSON() throws {
    let record = Self.record(slot: .basic(username: "me"), approval: .oncePerSession)
    let data = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(SecretRecord.self, from: data) == record)
  }

  // MARK: Hosts

  @Test func hostsNormalizeToLowercaseWithoutTheTrailingDot() {
    #expect(SecretHostRule.normalize("API.GitHub.COM.") == "api.github.com")
    #expect(SecretHostRule.normalize("bücher.de") == nil)
    #expect(SecretHostRule.normalize("") == nil)
    #expect(SecretHostRule.normalize("a..b") == nil)
    #expect(SecretHostRule.normalize("exa mple.com") == nil)
  }

  @Test func patternsThatCantBeSaved() {
    #expect(SecretHostRule.problem(pattern: "api.github.com") == nil)
    #expect(SecretHostRule.problem(pattern: "*.example.com") == nil)
    #expect(SecretHostRule.problem(pattern: "*") == "*: a wildcard needs a domain after it, like *.example.com.")
    #expect(SecretHostRule.problem(pattern: "*.com") == "*.com: a wildcard needs a domain after it, like *.example.com.")
    #expect(SecretHostRule.problem(pattern: "api*.example.com") == "api*.example.com: * can only be the first label.")
    #expect(SecretHostRule.problem(pattern: "bücher.de") == "bücher.de: use the punycode form (xn--…).")
    for local in ["localhost", "app.localhost", "printer.local", "127.0.0.1", "10.0.0.5", "203.0.113.9", "[::1]", "::1",
                  "2130706433", "0x7f.0.0.1", "127.1"] {
      #expect(SecretHostRule.problem(pattern: local) == "\(local): local and private addresses are never allowed.",
              "\(local)")
    }
  }

  @Test func hostLookAlikesDontMatch() {
    #expect(SecretHostRule.matches(host: "api.github.com", pattern: "api.github.com"))
    #expect(SecretHostRule.matches(host: "API.GitHub.COM.", pattern: "api.github.com"))
    #expect(!SecretHostRule.matches(host: "api.github.com.evil.com", pattern: "api.github.com"))
    #expect(!SecretHostRule.matches(host: "evilapi.github.com", pattern: "api.github.com"))
    #expect(SecretHostRule.matches(host: "a.example.com", pattern: "*.example.com"))
    #expect(SecretHostRule.matches(host: "a.b.example.com", pattern: "*.example.com"))
    #expect(!SecretHostRule.matches(host: "example.com", pattern: "*.example.com"))
    #expect(!SecretHostRule.matches(host: "badexample.com", pattern: "*.example.com"))
    #expect(!SecretHostRule.allows(host: "localhost", patterns: ["localhost"]))
    #expect(!SecretHostRule.allows(host: "127.0.0.1", patterns: ["127.0.0.1"]))
    #expect(SecretHostRule.allows(host: "api.github.com", patterns: ["uploads.github.com", "api.github.com"]))
  }
}
