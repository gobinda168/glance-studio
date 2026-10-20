import CryptoKit
import Foundation

/// What Settings lists: a secret without its value.
public struct SecretSummary: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let note: String
  public init(id: UUID, name: String, note: String) {
    self.id = id
    self.name = name
    self.note = note
  }
}

/// The key the vault's data key is derived from (spec "Storage"). Studio's is a Secure Enclave key, and `sharedSecret`
/// is where the Touch ID sheet appears; tests use a software key.
public protocol SecretKeyAgreement: Sendable {
  var publicKey: P256.KeyAgreement.PublicKey { get }
  func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey) async throws -> SharedSecret
}

/// The secrets, values and rules together, in one AES-GCM-sealed file (spec "Storage"). Its data key is derived from
/// ECDH(the key-agreement key, a fixed anchor point) and a random salt kept in the file, so deriving it, whether to
/// open the vault or to create one, takes the private key: in Studio, a finger on the Touch ID sensor. Holding only the
/// public key is not enough to write a vault Studio will open. Unlocked, the records live in memory until `lock()`.
/// Any change to the file, rules included, makes it fail to open.
public final class SecretVault: @unchecked Sendable {
  public enum Failure: Error, Equatable {
    case locked, notFound, damaged
    /// The key couldn't be used: cancelled, no fingerprint, or the key is gone. `declined`: the owner said no (cancelled
    /// the sheet, or Touch ID didn't take the finger), as the key reports it; it travels with this unlock's own result.
    case keyUnavailable(String, declined: Bool = false)
    case io(String)
  }

  public static var standardFile: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Glance/secrets.vault")
  }

  /// A P-256 public key whose private scalar was discarded when it was generated: nobody knows it. Anyone can compute
  /// ECDH(e, key.publicKey) for an ephemeral `e` they choose, but ECDH(privateKey, anchor) needs the private key (in
  /// Studio, a finger on Touch ID). The data key comes from the second, so only the key's owner can make or open a vault.
  public static let anchor = try! P256.KeyAgreement.PublicKey(x963Representation: Data(
    base64Encoded: "BHqEQ4NPdpaLkD8b51gDQ/G6o8XawbAn5XZFQL3t48VbI+f9Dt2IMF7KpxMQeeXDPs1e+pEBFIpJ3ZANL8pmmJo=")!)

  static let version = 2

  /// The file. `version` and `generation` are authenticated with the records; the salt is public, the rest is opaque.
  struct Envelope: Codable {
    var version: Int
    var generation: Int
    var salt: Data
    var records: Data
  }

  private struct Opened {
    let dataKey: SymmetricKey
    var envelope: Envelope
    var records: [SecretRecord]
  }

  private let file: URL
  private let keys: @Sendable () throws -> SecretKeyAgreement
  private let mutex = NSLock()
  private var opened: Opened?
  private var unlocking: Task<Void, Error>?
  /// Bumped by `lock()` and `reset()`, so an unlock that was under way when either ran can't open the vault afterwards.
  private var epoch = 0

  public init(file: URL = SecretVault.standardFile, keys: @escaping @Sendable () throws -> SecretKeyAgreement) {
    self.file = file
    self.keys = keys
  }

  public var isUnlocked: Bool { mutex.withLock { opened != nil } }

  /// Opens the vault, or creates an empty one on first use. Callers arriving while an unlock is under way wait for it
  /// instead of asking again.
  public func unlock() async throws {
    let task: Task<Void, Error>? = mutex.withLock {
      if opened != nil { return nil }
      if let unlocking { return unlocking }
      let epoch = self.epoch
      let task = Task { try await self.openOrCreate(epoch: epoch) }
      unlocking = task
      return task
    }
    guard let task else { return }
    defer { mutex.withLock { if unlocking == task { unlocking = nil } } }
    try await task.value
  }

  /// Forgets the data key and the records.
  public func lock() {
    mutex.withLock {
      opened = nil
      unlocking = nil
      epoch += 1
    }
  }

  /// Deletes the vault (its key can't be used any more, e.g. the fingerprints changed).
  public func reset() throws {
    // Under the mutex, so a create that is about to write can't recreate the file after it is removed.
    try mutex.withLock {
      opened = nil
      unlocking = nil
      epoch += 1
      do {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
      } catch { throw Failure.io("Couldn't delete \(file.lastPathComponent).") }
    }
  }

  public func records() -> [SecretRecord] { mutex.withLock { opened?.records ?? [] } }

  public func summaries() -> [SecretSummary] {
    records().map { SecretSummary(id: $0.id, name: $0.name, note: $0.note) }.sorted { $0.name < $1.name }
  }

  public func load(_ id: UUID) throws -> SecretRecord {
    try mutex.withLock {
      guard let opened else { throw Failure.locked }
      guard let record = opened.records.first(where: { $0.id == id }) else { throw Failure.notFound }
      return record
    }
  }

  public func save(_ record: SecretRecord) throws {
    try change { records in
      if let index = records.firstIndex(where: { $0.id == record.id }) {
        records[index] = record
      } else {
        records.append(record)
      }
    }
  }

  public func delete(_ id: UUID) throws { try change { $0.removeAll { $0.id == id } } }

  // MARK: - The file

  private func change(_ edit: (inout [SecretRecord]) -> Void) throws {
    try mutex.withLock {
      guard var current = opened else { throw Failure.locked }
      edit(&current.records)
      current.envelope = try write(current.records, into: current.envelope, dataKey: current.dataKey)
      opened = current
    }
  }

  private func openOrCreate(epoch: Int) async throws {
    let key: SecretKeyAgreement
    do { key = try keys() } catch let failure as Failure { throw failure } catch {
      throw Failure.keyUnavailable("\(error)")
    }
    guard FileManager.default.fileExists(atPath: file.path) else { return try await create(for: key, epoch: epoch) }
    guard let data = try? Data(contentsOf: file) else { throw Failure.io("Couldn't read \(file.lastPathComponent).") }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == Self.version,
          envelope.salt.count == 32 else { throw Failure.damaged }
    let dataKey = try await Self.dataKey(key, salt: envelope.salt)
    guard let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: envelope.records), using: dataKey,
                                        authenticating: Self.label(envelope)),
          let records = try? JSONDecoder().decode([SecretRecord].self, from: plain) else { throw Failure.damaged }
    try publish(Opened(dataKey: dataKey, envelope: envelope, records: records), epoch: epoch)
  }

  /// Opens the vault for the unlock that started in `epoch`, unless `lock()` or `reset()` ran since.
  private func publish(_ new: Opened, epoch: Int) throws {
    try mutex.withLock {
      guard epoch == self.epoch else { throw Failure.locked }
      opened = new
    }
  }

  /// First use: a random salt, the data key it gives with the private key (so Touch ID, as for any unlock), no records.
  private func create(for key: SecretKeyAgreement, epoch: Int) async throws {
    let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    let dataKey = try await Self.dataKey(key, salt: salt)
    let blank = Envelope(version: Self.version, generation: 0, salt: salt, records: Data())
    // One critical section: an unlock that was locked or reset meanwhile writes no file, and a `reset()` can't land
    // between the check and the write.
    try mutex.withLock {
      guard epoch == self.epoch else { throw Failure.locked }
      let envelope = try write([], into: blank, dataKey: dataKey)
      opened = Opened(dataKey: dataKey, envelope: envelope, records: [])
    }
  }

  /// Seals `records` as the next generation and writes the file, owner-only.
  private func write(_ records: [SecretRecord], into envelope: Envelope, dataKey: SymmetricKey) throws -> Envelope {
    var next = envelope
    next.generation += 1
    do {
      guard let sealed = try AES.GCM.seal(JSONEncoder().encode(records), using: dataKey,
                                          authenticating: Self.label(next)).combined else { throw Failure.damaged }
      next.records = sealed
      let manager = FileManager.default
      try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
      try JSONEncoder().encode(next).write(to: file, options: .atomic)
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch let failure as Failure {
      throw failure
    } catch {
      throw Failure.io("Couldn't write \(file.lastPathComponent).")
    }
    return next
  }

  private static func label(_ envelope: Envelope) -> Data {
    Data("glance-secrets-v\(envelope.version)-\(envelope.generation)".utf8)
  }

  /// The data key: HKDF over ECDH(key, anchor). The one place the private key is used.
  private static func dataKey(_ key: SecretKeyAgreement, salt: Data) async throws -> SymmetricKey {
    let shared: SharedSecret
    do { shared = try await key.sharedSecret(with: anchor) } catch let failure as Failure {
      throw failure
    } catch {
      throw Failure.keyUnavailable(error.localizedDescription)
    }
    return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                          sharedInfo: Data("glance-secrets-v2".utf8) + key.publicKey.x963Representation,
                                          outputByteCount: 32)
  }
}
