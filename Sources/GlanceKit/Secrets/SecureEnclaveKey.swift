import CryptoKit
import CryptoTokenKit
import Foundation
import GlanceCore
import LocalAuthentication

/// The vault's key (spec "Storage"): a P-256 key inside the Secure Enclave. Every use, by any program, needs a finger
/// on the Touch ID sensor (`biometryCurrentSet`: no password fallback, and a changed fingerprint set retires it). Its
/// handle in `secrets.key` is useless off this Mac and without a finger.
///
/// The handle file can be replaced by anyone running as the user, so a loaded key is trusted only once it has shown
/// that using it needs a person (`check`): otherwise Claude could delete the vault, put the handle of its own
/// unprotected key in `secrets.key`, and derive the data key of the vault Studio then creates.
struct SecureEnclaveKey: SecretKeyAgreement {
  static var standardFile: URL {
    SecretVault.standardFile.deletingLastPathComponent().appendingPathComponent("secrets.key")
  }
  static let reason = "unlock your Glance secrets"
  private static let touchIDUnavailable = "Touch ID isn't available right now."

  let handle: Data
  let publicKey: P256.KeyAgreement.PublicKey

  /// The saved key. With `create` (there's no vault yet), a new one when there's none, or when the saved one isn't
  /// protected by Touch ID or no longer works: no vault depends on it. Creating the key asks for nothing; creating the
  /// vault with it does (its data key comes from the private key). Without `create` the vault exists, so a missing or
  /// refused key is an error.
  static func load(file: URL = standardFile, create: Bool) throws -> SecureEnclaveKey {
    if let handle = try? Data(contentsOf: file) {
      switch check(handle) {
      case .protected(let key): return key
      case .unprotected where !create:
        throw SecretVault.Failure.keyUnavailable("Its key isn't protected by Touch ID.")
      case .unusable where !create:
        throw SecretVault.Failure.keyUnavailable("Its key no longer works (the fingerprints changed, or it was replaced).")
      case .touchIDUnavailable:
        // Even with no vault yet: the key may be fine once Touch ID is back, so it isn't replaced.
        throw SecretVault.Failure.keyUnavailable(touchIDUnavailable)
      case .unprotected, .unusable: break   // no vault yet: make a new key below
      }
    } else if !create {
      throw SecretVault.Failure.keyUnavailable("Its key file is gone.")
    }
    var error: Unmanaged<CFError>?
    guard SecureEnclave.isAvailable,
          let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                       [.privateKeyUsage, .biometryCurrentSet], &error) else {
      throw SecretVault.Failure.keyUnavailable("This Mac has no Secure Enclave or no Touch ID.")
    }
    let created = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
    let key: SecureEnclaveKey
    switch check(created.dataRepresentation) {
    case .protected(let checked): key = checked
    case .touchIDUnavailable: throw SecretVault.Failure.keyUnavailable(touchIDUnavailable)
    case .unprotected, .unusable: throw SecretVault.Failure.keyUnavailable("Its new key isn't protected by Touch ID.")
    }
    let manager = FileManager.default
    try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    try key.handle.write(to: file, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return key
  }

  private enum Check {
    case protected(SecureEnclaveKey)
    /// Usable without a person: not a key Studio made.
    case unprotected
    /// Not a Secure Enclave key of this Mac, or one retired by a fingerprint change.
    case unusable
    /// Touch ID can't be used now (locked out after failed tries, or no sensor while the lid is closed).
    case touchIDUnavailable
  }

  /// Uses the key once with interaction forbidden: a key that needs Touch ID fails at once with "user interaction
  /// is required" (LAError -1004) and shows no sheet. Succeeding, or failing any other way, refuses the key.
  private static func check(_ handle: Data) -> Check {
    let context = LAContext()
    context.interactionNotAllowed = true
    guard let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle,
                                                                    authenticationContext: context) else {
      return .unusable
    }
    do {
      _ = try key.sharedSecretFromKeyAgreement(with: SecretVault.anchor)
      return .unprotected
    } catch {
      if hasLAError(error, [.notInteractive]) {
        return .protected(SecureEnclaveKey(handle: handle, publicKey: key.publicKey))
      }
      return hasLAError(error, [.biometryLockout, .biometryNotAvailable]) ? .touchIDUnavailable : .unusable
    }
  }

  /// One of these LocalAuthentication errors, itself or under the error that carries it.
  private static func hasLAError(_ error: Error, _ codes: Set<LAError.Code>) -> Bool {
    has(error) { $0.domain == LAErrorDomain && LAError.Code(rawValue: $0.code).map(codes.contains) == true }
  }

  private static func has(_ error: Error, _ match: (NSError) -> Bool) -> Bool {
    var next: NSError? = error as NSError
    for _ in 0..<8 {
      guard let current = next else { return false }
      if match(current) { return true }
      next = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
  }

  /// The owner said no to the sheet: cancelled it (or it was cancelled), or Touch ID didn't take the finger. Either
  /// LocalAuthentication's word for it, or CryptoTokenKit's when the Secure Enclave reports it.
  static func isDecline(_ error: Error) -> Bool {
    hasLAError(error, [.userCancel, .authenticationFailed, .systemCancel, .appCancel])
      || has(error) {
        $0.domain == TKErrorDomain
          && [TKError.Code.canceledByUser.rawValue, TKError.Code.authenticationFailed.rawValue].contains($0.code)
      }
  }

  /// Shows the Touch ID sheet ("Glance Studio is trying to unlock your Glance secrets."), to open the vault or to
  /// create it. Blocks, so off the main thread.
  func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey) async throws -> SharedSecret {
    let handle = handle
    return try await Task.detached {
      let context = LAContext()
      context.localizedReason = Self.reason
      do {
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle,
                                                                 authenticationContext: context)
        return try key.sharedSecretFromKeyAgreement(with: ephemeral)
      } catch {
        // The decline travels with this unlock's own result (SecretsService's quiet period after a Claude-caused one).
        throw SecretVault.Failure.keyUnavailable(error.localizedDescription, declined: Self.isDecline(error))
      }
    }.value
  }
}
