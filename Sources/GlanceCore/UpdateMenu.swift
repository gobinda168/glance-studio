import Foundation

/// Where the overlay's update flow stands, as far as the menu bar cares. Sparkle's own dialog does the rest.
public enum UpdateState: Equatable, Sendable {
  case idle
  case available(version: String)
  case installing
}

public struct UpdateMenuItem: Equatable, Sendable {
  public let title: String
  public let isEnabled: Bool
  /// The menu-bar icon wears a badge while an update is waiting (the user may have dismissed the dialog).
  public let showsBadge: Bool

  public init(title: String, isEnabled: Bool, showsBadge: Bool) {
    self.title = title
    self.isEnabled = isEnabled
    self.showsBadge = showsBadge
  }
}

public enum UpdateMenu {
  public static func item(for state: UpdateState, canCheck: Bool) -> UpdateMenuItem {
    switch state {
    case .idle:
      return UpdateMenuItem(title: "Check for Updates…", isEnabled: canCheck, showsBadge: false)
    case .available(let version):
      let version = version.trimmingCharacters(in: .whitespaces)
      let title = version.isEmpty ? "Update Available…" : "Update Available: \(version)…"
      return UpdateMenuItem(title: title, isEnabled: true, showsBadge: true)
    case .installing:
      return UpdateMenuItem(title: "Installing Update…", isEnabled: false, showsBadge: false)
    }
  }
}

public enum UpdateFeed {
  /// GLANCE_FEED_URL points a build at another appcast, to test a release against a local server before publishing.
  /// Only http(s) URLs count; anything else falls back to the feed in Info.plist. Updates still need a valid EdDSA signature.
  public static func override(environment: [String: String]) -> String? {
    guard let raw = environment["GLANCE_FEED_URL"], let url = URL(string: raw),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil
    else { return nil }
    return raw
  }
}
