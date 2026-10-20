import Foundation

/// "Allow for this session" answers, held in Studio's memory only (spec "Approval card"): they end with the session,
/// and when the secret is edited or deleted.
public struct SecretGrants: Sendable {
  private var granted: Set<Key> = []
  private struct Key: Hashable, Sendable {
    let session: Int32
    let secret: UUID
  }

  public init() {}

  public func needsAsking(_ approval: SecretApproval, session: Int32, secret: UUID) -> Bool {
    switch approval {
    case .always: false
    case .everyTime: true
    case .oncePerSession: !granted.contains(Key(session: session, secret: secret))
    }
  }

  public mutating func grant(session: Int32, secret: UUID) { granted.insert(Key(session: session, secret: secret)) }
  public mutating func end(session: Int32) { granted = granted.filter { $0.session != session } }
  public mutating func forget(secret: UUID) { granted = granted.filter { $0.secret != secret } }
}
