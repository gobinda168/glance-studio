import CryptoKit
import Foundation

/// PKCE (RFC 7636) for the browser sign-ins, Google's and the Glance server's: a random verifier or state, and its S256
/// challenge.
public enum PKCE {
  /// 32 random bytes, base64url: a PKCE verifier or a state.
  public static func randomToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
  }

  /// base64url(SHA-256(verifier)).
  public static func challenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
