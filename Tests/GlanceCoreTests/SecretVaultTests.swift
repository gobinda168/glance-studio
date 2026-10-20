import CryptoKit
import Foundation
import Testing
@testable import GlanceCore

@Suite struct SecretVaultTests {
  /// Stands in for the Secure Enclave key: counts uses and takes a moment, like a Touch ID sheet.
  final class SoftwareKey: SecretKeyAgreement, @unchecked Sendable {
    let key = P256.KeyAgreement.PrivateKey()
    private let mutex = NSLock()
    private var count = 0
    var uses: Int { mutex.withLock { count } }
    var publicKey: P256.KeyAgreement.PublicKey { key.publicKey }
    func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey) async throws -> SharedSecret {
      mutex.withLock { count += 1 }
      try await Task.sleep(nanoseconds: 50_000_000)
      return try key.sharedSecretFromKeyAgreement(with: ephemeral)
    }
  }

  static func file() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("glance-vault-\(UUID().uuidString)/secrets.vault")
  }

  static func vault(_ file: URL, _ key: SoftwareKey) -> SecretVault { SecretVault(file: file, keys: { key }) }

  /// A vault at `file` holding `record()`, written with `key`.
  static func filled(_ file: URL, _ key: SoftwareKey) async throws -> SecretRecord {
    let vault = Self.vault(file, key)
    try await vault.unlock()
    let record = SecretRecordTests.record()
    try vault.save(record)
    return record
  }

  @Test func aNewVaultRoundTripsThroughTheFile() async throws {
    let file = Self.file(), key = SoftwareKey()
    let record = try await Self.filled(file, key)
    #expect(key.uses == 1) // creating a vault needs the private key too: the first Touch ID
    let again = Self.vault(file, key)
    #expect(!again.isUnlocked)
    #expect(again.records().isEmpty)
    try await again.unlock()
    #expect(key.uses == 2) // one use per unlock
    #expect(again.records() == [record])
    #expect(try again.load(record.id) == record)
    #expect(again.summaries() == [SecretSummary(id: record.id, name: "GITHUB_TOKEN", note: "GitHub")])
  }

  @Test func aLockedVaultRevealsNothing() async throws {
    let file = Self.file(), key = SoftwareKey()
    let vault = Self.vault(file, key)
    try await vault.unlock()
    let record = SecretRecordTests.record()
    try vault.save(record)
    vault.lock()
    #expect(!vault.isUnlocked)
    #expect(vault.records().isEmpty)
    #expect(vault.summaries().isEmpty)
    #expect(throws: SecretVault.Failure.locked) { try vault.load(record.id) }
    #expect(throws: SecretVault.Failure.locked) { try vault.save(record) }
  }

  @Test func theFileHoldsNoPlaintextAndIsOwnerOnly() async throws {
    let file = Self.file(), key = SoftwareKey()
    let record = try await Self.filled(file, key)
    let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
    for word in [record.value, record.name, record.note, "api.github.com", Data(record.value.utf8).base64EncodedString()] {
      #expect(!text.contains(word))
    }
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
  }

  @Test func anotherKeyCannotOpenIt() async throws {
    let file = Self.file()
    _ = try await Self.filled(file, SoftwareKey())
    let stranger = Self.vault(file, SoftwareKey())
    await #expect(throws: SecretVault.Failure.damaged) { try await stranger.unlock() }
    #expect(stranger.records().isEmpty)
  }

  @Test func anyTamperingIsRefused() async throws {
    let file = Self.file(), key = SoftwareKey()
    _ = try await Self.filled(file, key)
    let original = try Data(contentsOf: file)
    var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])

    // A changed generation (what a rollback would need to hide) breaks the authentication.
    json["generation"] = (json["generation"] as? Int ?? 0) + 5
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    await #expect(throws: SecretVault.Failure.damaged) { try await Self.vault(file, key).unlock() }

    // One flipped byte in the sealed records.
    json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    var sealed = try #require(Data(base64Encoded: json["records"] as? String ?? ""))
    sealed[sealed.count - 1] ^= 0x01
    json["records"] = sealed.base64EncodedString()
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    await #expect(throws: SecretVault.Failure.damaged) { try await Self.vault(file, key).unlock() }

    // Not JSON at all.
    try Data("{".utf8).write(to: file)
    await #expect(throws: SecretVault.Failure.damaged) { try await Self.vault(file, key).unlock() }
  }

  @Test func concurrentCallersShareOneUnlock() async throws {
    let file = Self.file(), key = SoftwareKey()
    _ = try await Self.filled(file, key)
    let vault = Self.vault(file, key)
    async let first: Void = vault.unlock()
    async let second: Void = vault.unlock()
    _ = try await (first, second)
    try await vault.unlock() // already open: no further use
    #expect(key.uses == 2) // one to create the file, one shared by both callers
  }

  @Test func savingAgainUpdatesInPlaceAndDeleteRemoves() async throws {
    let file = Self.file(), key = SoftwareKey()
    var record = try await Self.filled(file, key)
    let vault = Self.vault(file, key)
    try await vault.unlock()
    record.note = "GitHub, repo scope"
    record.hosts = ["api.github.com", "uploads.github.com"]
    try vault.save(record)
    #expect(vault.summaries().map(\.note) == ["GitHub, repo scope"])
    let reread = Self.vault(file, key)
    try await reread.unlock()
    #expect(try reread.load(record.id).hosts == ["api.github.com", "uploads.github.com"])
    try reread.delete(record.id)
    try reread.delete(record.id) // idempotent
    #expect(reread.summaries().isEmpty)
    #expect(throws: SecretVault.Failure.notFound) { try reread.load(record.id) }
  }

  @Test func resetLocksAndRemovesTheFile() async throws {
    let file = Self.file(), key = SoftwareKey()
    _ = try await Self.filled(file, key)
    let vault = Self.vault(file, key)
    try await vault.unlock()
    try vault.reset()
    #expect(!vault.isUnlocked)
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func aKeyThatCantBeHadIsReported() async throws {
    struct Gone: Error {}
    let vault = SecretVault(file: Self.file(), keys: { throw Gone() })
    await #expect { try await vault.unlock() } throws: { error in
      if case SecretVault.Failure.keyUnavailable = error { return true }
      return false
    }
  }

  /// The key's own refusal at the sheet (a decline) comes back from `unlock` as it was thrown.
  @Test func aDeclineAtTheSheetComesBackWithTheUnlock() async throws {
    final class Declining: SecretKeyAgreement {
      let publicKey = P256.KeyAgreement.PrivateKey().publicKey
      func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey) async throws -> SharedSecret {
        throw SecretVault.Failure.keyUnavailable("Cancelled.", declined: true)
      }
    }
    let vault = SecretVault(file: Self.file(), keys: { Declining() })
    await #expect(throws: SecretVault.Failure.keyUnavailable("Cancelled.", declined: true)) { try await vault.unlock() }
  }

  @Test func aKeyRefusalKeepsItsOwnWords() async throws {
    let vault = SecretVault(file: Self.file(), keys: { throw SecretVault.Failure.keyUnavailable("Its key file is gone.") })
    await #expect(throws: SecretVault.Failure.keyUnavailable("Its key file is gone.")) { try await vault.unlock() }
  }

  /// A key whose `sharedSecret` says it has been entered and then waits for the test to let it go: no timing involved.
  final class GatedKey: SecretKeyAgreement, @unchecked Sendable {
    let inner = SoftwareKey()
    private let entered = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()
    var publicKey: P256.KeyAgreement.PublicKey { inner.publicKey }
    func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey) async throws -> SharedSecret {
      entered.continuation.yield()
      for await _ in release.stream { break }
      return try await inner.sharedSecret(with: ephemeral)
    }
    /// Returns once a `sharedSecret` call is in flight.
    func waitUntilEntered() async { for await _ in entered.stream { break } }
    func letGo() { release.continuation.yield() }
  }

  @Test func lockingWhileUnlockingLeavesItLocked() async throws {
    let file = Self.file(), key = GatedKey()
    _ = try await Self.filled(file, key.inner)
    let vault = SecretVault(file: file, keys: { key })
    let pending = Task { try await vault.unlock() }
    await key.waitUntilEntered() // the key's sheet is up
    vault.lock()
    key.letGo()
    await #expect(throws: SecretVault.Failure.locked) { try await pending.value }
    #expect(!vault.isUnlocked)
    #expect(vault.records().isEmpty)
    // A fresh unlock still works.
    let again = Task { try await vault.unlock() }
    await key.waitUntilEntered()
    key.letGo()
    try await again.value
    #expect(vault.isUnlocked)
  }

  /// Locked while the key is being used to create the vault: no file is written, so nothing is left to open.
  @Test func lockingWhileCreatingWritesNoFile() async throws {
    let file = Self.file(), key = GatedKey()
    let vault = SecretVault(file: file, keys: { key })
    let pending = Task { try await vault.unlock() }
    await key.waitUntilEntered()
    vault.lock()
    key.letGo()
    await #expect(throws: SecretVault.Failure.locked) { try await pending.value }
    #expect(!vault.isUnlocked)
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func resettingWhileCreatingWritesNoFile() async throws {
    let file = Self.file(), key = GatedKey()
    let vault = SecretVault(file: file, keys: { key })
    let pending = Task { try await vault.unlock() }
    await key.waitUntilEntered()
    try vault.reset()
    key.letGo()
    await #expect(throws: SecretVault.Failure.locked) { try await pending.value }
    #expect(!vault.isUnlocked)
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  /// What an attacker who has only `key.publicKey` (and the code) can write: a v2 file sealed under a key it can compute.
  @Test func aVaultForgedWithOnlyThePublicKeyIsRefused() async throws {
    let file = Self.file(), key = SoftwareKey()
    let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    let ephemeral = P256.KeyAgreement.PrivateKey()
    let guess = try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)
      .hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                               sharedInfo: Data("glance-secrets-v2".utf8) + key.publicKey.x963Representation,
                               outputByteCount: 32)
    let forged = SecretRecordTests.record(name: "FORGED_TOKEN")
    let sealed = try AES.GCM.seal(JSONEncoder().encode([forged]), using: guess,
                                  authenticating: Data("glance-secrets-v2-1".utf8)).combined
    let envelope: [String: Any] = ["version": 2, "generation": 1, "salt": salt.base64EncodedString(),
                                   "records": try #require(sealed).base64EncodedString()]
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: envelope).write(to: file)
    let vault = Self.vault(file, key)
    await #expect(throws: SecretVault.Failure.damaged) { try await vault.unlock() }
    #expect(!vault.isUnlocked)
    #expect(vault.records().isEmpty)
  }

  @Test func anOldVersionFileIsRefused() async throws {
    let file = Self.file(), key = SoftwareKey()
    let v1: [String: Any] = ["version": 1, "generation": 3, "ephemeral": Data(repeating: 4, count: 65).base64EncodedString(),
                             "wrappedKey": Data(repeating: 5, count: 60).base64EncodedString(),
                             "records": Data(repeating: 6, count: 40).base64EncodedString()]
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: v1).write(to: file)
    let vault = Self.vault(file, key)
    await #expect(throws: SecretVault.Failure.damaged) { try await vault.unlock() }
    #expect(vault.records().isEmpty)
    #expect(key.uses == 0) // refused before the key is touched
  }
}
