import Foundation

/// `http_request`'s arguments, checked for shape (ChannelTools); the broker checks them against the secret's rules.
public struct SecretHTTPCall: Equatable, Sendable {
  public var secret: String
  public var method: String
  public var url: String
  public var headers: [String: String]
  /// Sent as is (not trimmed).
  public var body: String?
  /// A file inside the session's folder, sent as the body.
  public var bodyFile: String?
  /// A file inside the session's folder the (scrubbed) response body is written to.
  public var saveTo: String?

  public init(secret: String, method: String, url: String, headers: [String: String], body: String?, bodyFile: String?,
              saveTo: String?) {
    self.secret = secret
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.bodyFile = bodyFile
    self.saveTo = saveTo
  }
}
