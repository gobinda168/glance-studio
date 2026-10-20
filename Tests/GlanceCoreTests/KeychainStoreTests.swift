import Foundation
import Security
import Testing
@testable import GlanceCore

/// Uses a throwaway service name so the real Glance key is never touched.
@Suite struct KeychainStoreTests {
  let store = KeychainStore(service: "dev.glance.Glance.tests.\(UUID().uuidString)", account: "elevenlabs")

  @Test func roundTripsAndOverwrites() {
    defer { store.delete() }
    #expect(store.read() == nil)
    #expect(store.save("sk_first"))
    #expect(store.read() == "sk_first")
    #expect(store.save("sk_second"))
    #expect(store.read() == "sk_second")
  }

  @Test func deleteRemovesAndIsIdempotent() {
    #expect(store.save("sk_gone"))
    #expect(store.delete())
    #expect(store.read() == nil)
    #expect(store.delete())
  }

  @Test func elevenLabsItemUsesTheDocumentedNames() {
    #expect(KeychainStore.elevenLabs.service == "dev.glance.Glance")
    #expect(KeychainStore.elevenLabs.account == "elevenlabs")
  }

  /// Every Keychain read can raise a macOS access prompt, so a key is read once and then served from memory.
  @Test func readsAreServedFromMemoryAfterTheFirst() {
    defer { store.delete() }
    #expect(store.save("sk_cached"))
    #expect(store.read() == "sk_cached")
    // Remove the item behind the store's back: the cached value still answers, with no second Keychain read.
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: store.service, kSecAttrAccount as String: store.account]
    #expect(SecItemDelete(query as CFDictionary) == errSecSuccess)
    #expect(store.read() == "sk_cached")
    // Going through the store keeps the cache honest.
    #expect(store.delete())
    #expect(store.read() == nil)
  }

  /// A denied prompt or a missing item is remembered too, so focusing Settings never asks again in the same run.
  @Test func aMissingItemIsAlsoRememberedUntilSaved() {
    defer { store.delete() }
    #expect(store.read() == nil)
    // Added behind the store's back after a failed read: the store keeps answering "none" without asking again.
    var add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                              kSecAttrService as String: store.service, kSecAttrAccount as String: store.account]
    add[kSecValueData as String] = Data("sk_outside".utf8)
    #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
    #expect(store.read() == nil)
    #expect(store.save("sk_saved"))
    #expect(store.read() == "sk_saved")
  }

  @Test func providerItemsShareTheServiceAndUseTheProviderAccount() {
    #expect(KeychainStore.provider(.elevenLabs).service == KeychainStore.elevenLabs.service)
    #expect(KeychainStore.provider(.elevenLabs).account == KeychainStore.elevenLabs.account)
    #expect(KeychainStore.provider(.miniMax).service == "dev.glance.Glance")
    #expect(KeychainStore.provider(.miniMax).account == "minimax")
  }
}
