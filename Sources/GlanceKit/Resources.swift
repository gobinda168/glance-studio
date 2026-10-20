import Foundation
import GlanceCore

/// Locates bundled files: inside Glance Studio they are in Contents/Resources; under `swift run` they are
/// read straight from the package checkout.
public enum Resources {
  static let root: URL = {
    if let resources = Bundle.main.resourceURL,
      FileManager.default.fileExists(atPath: resources.appendingPathComponent("Web/index.html").path) {
      return resources
    }
    return URL(fileURLWithPath: #filePath) // <package>/Sources/GlanceKit/Resources.swift
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }()

  public static var web: URL { root.appendingPathComponent("Web") }
  public static var editor: URL { web.appendingPathComponent("editor") }
  /// glance.js for automation UIs (glance-automation://glance/glance.js).
  public static var automationScript: URL { web.appendingPathComponent("automation/glance.js") }
  /// The design system's tokens (glance-automation://glance/tokens.css). In the app, scripts/build-terminal.sh copies
  /// the file to the same path under Contents/Resources.
  public static var designTokens: URL { root.appendingPathComponent("design-system/glance/tokens.css") }
  public static var notifyScript: URL { root.appendingPathComponent("hooks/notify.sh") }
  public static var statusLineScript: URL { root.appendingPathComponent("hooks/statusline.sh") }
  /// Glance browser broker (spec 2026-10-14-agent-browser-design.md), run with the user's node.
  public static var agentBrowserScript: URL { root.appendingPathComponent("agent-browser/agent-browser.mjs") }
  /// Glance Humanize (an output style file): `glance setup` installs it, Studio's headless chats append its text.
  public static var outputStyle: URL { root.appendingPathComponent("styles/humanize.md") }
  /// Glance Humanize without its front matter, read once.
  public static let humanizeBody: String =
    HumanizeStyle.body(of: (try? String(contentsOf: outputStyle, encoding: .utf8)) ?? "")
}
