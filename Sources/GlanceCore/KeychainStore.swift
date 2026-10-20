import Foundation
import Security

/// One generic-password item in the login keychain.
///
/// macOS can ask the user to approve every Keychain read by an app it doesn't trust yet (and an ad-hoc signed build is
/// new to it after every rebuild), so the first answer is kept in memory for the rest of the process: the value, or
/// that there is none (missing, or the prompt was denied). `save` and `delete` keep that copy current; a change made
/// outside Glance is seen after a relaunch.
public struct KeychainStore: Sendable {
  public let service: String
  public let account: String

  /// The ElevenLabs API key. `security add-generic-password -s dev.glance.Glance -a elevenlabs` writes the same item.
  public static let elevenLabs = KeychainStore(service: "dev.glance.Glance", account: "elevenlabs")

  /// A cloud voice provider's key. `provider(.elevenLabs)` is the same item as `elevenLabs`.
  public static func provider(_ id: ProviderID) -> KeychainStore {
    KeychainStore(service: "dev.glance.Glance", account: id.keychainAccount)
  }

  public init(service: String, account: String) {
    self.service = service
    self.account = account
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }

  public func read() -> String? {
    if let cached = Self.cache.value(for: cacheKey) { return cached }
    let value = keychainRead()
    Self.cache.set(value, for: cacheKey)
    return value
  }

  /// Whether the item is there, without its value: reading only an item's attributes never asks for the Keychain
  /// password, so a "has a key?" check can run at launch. Read the value only when it's about to be used.
  public func exists() -> Bool {
    if case .some(let value) = Self.cache.value(for: cacheKey), value != nil { return true }
    var query = query
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
  }

  /// The value when this run already read or saved it, else nil without asking the Keychain.
  public func cachedValue() -> String? {
    Self.cache.value(for: cacheKey) ?? nil
  }

  private func keychainRead() -> String? {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  /// Replaces the stored value, creating the item the first time.
  @discardableResult
  public func save(_ value: String) -> Bool {
    let data = Data(value.utf8)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    let saved: Bool
    if status == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      saved = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    } else {
      saved = status == errSecSuccess
    }
    if saved { Self.cache.set(value, for: cacheKey) }
    return saved
  }

  /// True when the item is gone afterwards, including when there was none.
  @discardableResult
  public func delete() -> Bool {
    let status = SecItemDelete(query as CFDictionary)
    let deleted = status == errSecSuccess || status == errSecItemNotFound
    if deleted { Self.cache.set(nil, for: cacheKey) }
    return deleted
  }

  private var cacheKey: String { service + "\u{1F}" + account }
  private static let cache = Cache()

  /// What each item held when last read or written this run, shared by every `KeychainStore` for the same item.
  /// `.some(nil)` means "known to be absent"; a missing entry means "not asked yet".
  private final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String?] = [:]

    func value(for key: String) -> String?? {
      lock.lock()
      defer { lock.unlock() }
      return values[key]
    }

    func set(_ value: String?, for key: String) {
      lock.lock()
      values.updateValue(value, forKey: key)
      lock.unlock()
    }
  }
}
