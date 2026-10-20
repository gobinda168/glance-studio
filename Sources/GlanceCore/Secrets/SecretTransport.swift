import Foundation

public enum SecretTransportError: Error, Equatable, Sendable {
  /// The response passed `maxBytes` (declared or while it streamed); reading stopped there.
  case tooLarge
}

public protocol SecretTransport: Sendable {
  /// Sends once and reads at most `maxBytes` of the body, throwing `tooLarge` past it; `follow` decides each redirect
  /// (false: the 3xx comes back as the response).
  func send(_ request: URLRequest, maxBytes: Int, follow: @escaping @Sendable (URL) -> Bool) async throws
    -> (HTTPURLResponse, Data)
}

/// An ephemeral session per request that keeps nothing: no cookies, cache or stored credentials, and no answer to an
/// auth challenge other than the server's TLS trust (checked against the system's, as usual). The body is collected
/// as it streams and dropped the moment it passes the cap, so an allowed host can't make Studio buffer gigabytes.
public final class URLSessionSecretTransport: SecretTransport, @unchecked Sendable {
  public static let maxRedirects = 5
  private let configuration: URLSessionConfiguration

  public convenience init() { self.init(protocolClasses: nil) }

  /// `protocolClasses` lets tests answer with a URLProtocol stub instead of the network.
  init(protocolClasses: [AnyClass]?) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 120
    if let protocolClasses { configuration.protocolClasses = protocolClasses }
    self.configuration = configuration
  }

  public func send(_ request: URLRequest, maxBytes: Int, follow: @escaping @Sendable (URL) -> Bool) async throws
    -> (HTTPURLResponse, Data) {
    let load = Load(maxBytes: maxBytes, follow: follow)
    let session = URLSession(configuration: configuration, delegate: load, delegateQueue: nil)
    // The session holds its delegate until it is invalidated.
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: request)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        load.begin(continuation)
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  private final class Load: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maxBytes: Int
    let follow: @Sendable (URL) -> Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>?
    private var redirects = 0
    private var response: HTTPURLResponse?
    private var body = Data()

    init(maxBytes: Int, follow: @escaping @Sendable (URL) -> Bool) {
      self.maxBytes = maxBytes
      self.follow = follow
    }

    func begin(_ continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>) {
      lock.withLock { self.continuation = continuation }
    }

    /// Resumes the caller once; later callbacks find nothing to resume.
    private func finish(_ result: Result<(HTTPURLResponse, Data), Error>) {
      let continuation = lock.withLock {
        let continuation = self.continuation
        self.continuation = nil
        return continuation
      }
      continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
      let count = lock.withLock {
        redirects += 1
        return redirects
      }
      guard count <= URLSessionSecretTransport.maxRedirects, let url = request.url, follow(url) else {
        completionHandler(nil)
        return
      }
      completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
      if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
        completionHandler(.performDefaultHandling, nil)
      } else {
        // No system or keychain credentials (Kerberos, NTLM, client certificates) ever go along: the 401 comes back.
        completionHandler(.rejectProtectionSpace, nil)
      }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
      guard let http = response as? HTTPURLResponse else {
        finish(.failure(URLError(.badServerResponse)))
        completionHandler(.cancel)
        return
      }
      guard http.expectedContentLength <= Int64(maxBytes) else {
        finish(.failure(SecretTransportError.tooLarge))
        completionHandler(.cancel)
        return
      }
      lock.withLock {
        self.response = http
        body = Data()
      }
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      let over = lock.withLock {
        guard body.count + data.count <= maxBytes else {
          body = Data()
          return true
        }
        body.append(data)
        return false
      }
      if over {
        finish(.failure(SecretTransportError.tooLarge))
        dataTask.cancel()
      }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      if let error {
        finish(.failure(error))
        return
      }
      let (response, body) = lock.withLock { (self.response, self.body) }
      if let response { finish(.success((response, body))) } else { finish(.failure(URLError(.badServerResponse))) }
    }
  }
}
