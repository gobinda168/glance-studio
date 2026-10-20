import AppKit
import GlanceCore
import Observation

/// A provider's API key: typed, saved to Keychain, tested, removed. Settings' Voice page shows one per provider.
@MainActor
@Observable
public final class KeyFieldModel {
  public enum CheckState: Equatable { case idle, checking, done(KeyCheckResult) }

  public let provider: ProviderID
  public var keyInput = ""
  public var revealKey = false
  /// A key is saved (known without reading it, so Settings never asks for the Keychain password on its own).
  public private(set) var hasSavedKey = false
  /// The saved key's mask, once this run has read or saved the key; nil until then.
  public private(set) var savedKeyMask: String?
  public private(set) var check = CheckState.idle
  /// The saved key changed (saved or removed).
  @ObservationIgnored var onChange: (() -> Void)?
  @ObservationIgnored private let store: KeychainStore

  init(provider: ProviderID) {
    self.provider = provider
    store = KeychainStore.provider(provider)
  }

  public func refresh() {
    hasSavedKey = store.exists()
    savedKeyMask = hasSavedKey ? store.cachedValue().map(APIKey.masked) : nil
  }

  public func save() {
    let key = APIKey.normalized(keyInput)
    guard !key.isEmpty else { return }
    guard store.save(key) else {
      check = .done(.failed("Couldn't save the key to Keychain."))
      return
    }
    keyInput = ""
    revealKey = false
    refresh()
    test()
    onChange?()
  }

  public func remove() {
    store.delete()
    keyInput = ""
    check = .idle
    refresh()
    onChange?()
  }

  /// Tests the typed key if there is one, otherwise the saved key.
  public func test() {
    let typed = APIKey.normalized(keyInput)
    guard let key = typed.isEmpty ? store.read() : typed else {
      check = .done(.failed("Paste a key first."))
      return
    }
    if typed.isEmpty { savedKeyMask = APIKey.masked(key) }
    check = .checking
    let provider = self.provider
    Task { check = .done(await Self.check(provider, key: key)) }
  }

  private static func check(_ provider: ProviderID, key: String) async -> KeyCheckResult {
    switch provider {
    case .elevenLabs:
      do {
        let (data, response) = try await URLSession.shared.data(for: ElevenLabsKeyCheck.request(key: key))
        return ElevenLabsKeyCheck.result(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
      } catch {
        return ElevenLabsKeyCheck.result(error: error)
      }
    case .miniMax:
      do {
        _ = try await MiniMaxProvider(key: key).voices()
        return .connected
      } catch TTSFailure.invalidKey {
        return .failed("Invalid key. MiniMax rejected it.")
      } catch {
        return .failed((error as? TTSFailure)?.message(provider: "MiniMax") ?? error.localizedDescription)
      }
    }
  }
}
