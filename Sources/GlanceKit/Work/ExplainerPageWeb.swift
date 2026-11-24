import Foundation
import GlanceCore
import WebKit

/// The sandbox an explainer page runs in (spec 2026-11-03-explainer-mode-design.md §8). The page is untrusted: its CSP
/// stops every script of its own, a rule list stops the network, nothing is stored, and Glance's own script runs in a
/// world of its own, the only place the bridge exists.
@MainActor
public enum ExplainerPageWeb {
  /// The message handler's name, in Glance's world only.
  public static let handlerName = "explainer"
  public static let world = WKContentWorld.world(name: "dev.glance.explainer")

  public struct Unavailable: Error {
    public let reason: String
  }

  /// A configuration with the sandbox in place. Throws rather than offer one without it: never show a page unsandboxed.
  public static func configuration(handler: WKScriptMessageHandler) async throws -> WKWebViewConfiguration {
    guard let script = try? String(contentsOf: Resources.web.appendingPathComponent("explainer/runtime.js"), encoding: .utf8) else {
      throw Unavailable(reason: "The explainer's script is missing from this build.")
    }
    let rules: WKContentRuleList?
    do {
      rules = try await WKContentRuleListStore.default()?.compileContentRuleList(
        forIdentifier: "dev.glance.explainer.no-network", encodedContentRuleList: ExplainerRenderer.blockNetworkRules)
    } catch {
      throw Unavailable(reason: "Couldn't set up the network block.")
    }
    guard let rules else { throw Unavailable(reason: "Couldn't set up the network block.") }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    let controller = configuration.userContentController
    controller.add(rules)
    controller.add(handler, contentWorld: world, name: handlerName)
    controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
    return configuration
  }

  /// The page's styles: the fonts as data: URIs (the CSP allows no other), then the kit. Read once.
  public static func css() throws -> String {
    if let cached = cachedCSS { return cached }
    let folder = Resources.web
    guard let kit = try? String(contentsOf: folder.appendingPathComponent("explainer/kit.css"), encoding: .utf8) else {
      throw Unavailable(reason: "The explainer's styles are missing from this build.")
    }
    var faces = ""
    for (file, family, weights) in [("dm-sans", "DM Sans", "400 700"), ("jetbrains-mono", "JetBrains Mono", "400 600")] {
      guard let data = try? Data(contentsOf: folder.appendingPathComponent("vendor/fonts/\(file).woff2")) else { continue }
      faces += "@font-face { font-family: \"\(family)\"; font-weight: \(weights); src: url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\"); }\n"
    }
    let css = faces + kit
    cachedCSS = css
    return css
  }

  private static var cachedCSS: String?

  /// Only the page's own first load; everything else (a link, a refresh, a popup) goes nowhere.
  public static func allows(navigation action: WKNavigationAction, loaded: Bool) -> Bool {
    !loaded && action.targetFrame?.isMainFrame == true && action.request.url?.scheme == "about"
  }
}
