import Foundation
import Testing
@testable import GlanceCore

@Suite struct SettingsLogicTests {
  @Test func normalizesPastedKeys() {
    #expect(APIKey.normalized("  sk_abc123\n") == "sk_abc123")
    #expect(APIKey.normalized("sk_abc\t123 ") == "sk_abc123")
    #expect(APIKey.normalized(" \n ") == "")
  }

  @Test func masksAllButTheLastFour() {
    #expect(APIKey.masked("sk_0123456789abcd") == "••••abcd")
    #expect(APIKey.masked("short") == "••••")
  }

  @Test func checkRequestCarriesTheKey() {
    let request = ElevenLabsKeyCheck.request(key: "sk_test")
    #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/user")
    #expect(request.value(forHTTPHeaderField: "xi-api-key") == "sk_test")
    #expect(request.httpMethod == "GET")
  }

  @Test func mapsCheckResponses() {
    let invalid = Data(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#.utf8)
    let restricted = Data(#"{"detail":{"status":"missing_permissions","message":"missing user_read"}}"#.utf8)
    #expect(ElevenLabsKeyCheck.result(status: 200, body: Data()) == .connected)
    #expect(ElevenLabsKeyCheck.result(status: 401, body: invalid) == .invalidKey)
    #expect(ElevenLabsKeyCheck.result(status: 401, body: Data()) == .invalidKey)
    // A key limited to Speech to Text can't read /v1/user, but it is a working key.
    #expect(ElevenLabsKeyCheck.result(status: 401, body: restricted) == .connected)
    #expect(ElevenLabsKeyCheck.result(status: 403, body: restricted) == .connected)
    #expect(ElevenLabsKeyCheck.result(status: 429, body: Data()) == .failed("ElevenLabs is rate limiting. Try again in a moment."))
    #expect(ElevenLabsKeyCheck.result(status: 503, body: Data()) == .failed("ElevenLabs is having trouble (HTTP 503)."))
    #expect(ElevenLabsKeyCheck.result(status: 418, body: Data()) == .failed("Unexpected response from ElevenLabs (HTTP 418)."))
  }

  @Test func mapsTransportErrors() {
    let error = URLError(.notConnectedToInternet)
    guard case .failed(let message) = ElevenLabsKeyCheck.result(error: error) else { Issue.record("not failed"); return }
    #expect(message.hasPrefix("Couldn't reach ElevenLabs: "))
  }

  @Test func readsFnUsage() {
    #expect(FnUsage(rawValue: 0) == .doNothing)
    #expect(FnUsage(rawValue: 1) == .changeInputSource)
    #expect(FnUsage(rawValue: 2) == .emojiAndSymbols)
    #expect(FnUsage(rawValue: 3) == .dictation)
    #expect(FnUsage(rawValue: nil) == .unknown)
    #expect(FnUsage(rawValue: 9) == .unknown)
    #expect(!FnUsage.doNothing.conflictsWithDictation)
    #expect(FnUsage.doNothing.advice == nil)
    #expect(FnUsage.emojiAndSymbols.conflictsWithDictation)
    #expect(FnUsage.emojiAndSymbols.advice?.contains("Show Emoji & Symbols") == true)
    #expect(FnUsage.unknown.advice?.contains("Do Nothing") == true)
  }
}
