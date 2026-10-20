import AppKit
import AuthenticationServices
import GlanceCore

/// One sign-in sheet (ASWebAuthenticationSession): opens `url` and answers the `glance://` URL it ends on.
/// Closing the sheet is `CloudError.cancelled`.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  func run(_ url: URL, scheme: String) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callback, error in
        if let callback {
          continuation.resume(returning: callback)
        } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
          continuation.resume(throwing: CloudError.cancelled)
        } else {
          continuation.resume(throwing: CloudError.unreachable)
        }
      }
      session.presentationContextProvider = self
      self.session = session
      if !session.start() {
        self.session = nil
        continuation.resume(throwing: CloudError.cancelled)
      }
    }
  }

  func cancel() {
    session?.cancel()
  }

  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
    }
  }
}
