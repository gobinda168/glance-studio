import Foundation

/// Glance's version, build number and commit, stamped into Info.plist by scripts/stamp-version.sh at build time.
/// Glance Studio keeps Ghostty's own CFBundle versions, so the Glance* keys come first.
public struct AppVersion: Sendable {
  public let version: String?
  public let build: String?
  public let commit: String?
  /// A development build, which has the features not GA yet and the Develop menu: stamp-version.sh stamps every build
  /// but a release (GLANCE_RELEASE=1, from scripts/release.sh). A bundle without the stamp counts as a release, so a
  /// missed stamp can only leave features out.
  public let isDevelopment: Bool

  public init(info: [String: Any]?) {
    let info = info ?? [:]
    func value(_ keys: String...) -> String? {
      keys.lazy.compactMap { info[$0] as? String }.first { !$0.isEmpty }
    }
    version = value("GlanceVersion", "CFBundleShortVersionString")
    build = value("GlanceBuild", "CFBundleVersion")
    commit = value("GlanceCommit")
    isDevelopment = value("GlanceDevelopment") == "1"
  }

  public static var current: AppVersion { AppVersion(info: Bundle.main.infoDictionary) }

  /// "0.1.0 (151)", or "dev" when running outside an app bundle (swift run).
  public var short: String { label(details: [build]) }

  /// "0.1.0 (151, f53fb74)", for bug reports.
  public var full: String { label(details: [build, commit]) }

  private func label(details: [String?]) -> String {
    guard let version else { return "dev" }
    let details = details.compactMap { $0 }
    return details.isEmpty ? version : "\(version) (\(details.joined(separator: ", ")))"
  }
}
