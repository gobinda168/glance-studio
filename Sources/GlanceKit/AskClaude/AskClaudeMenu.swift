import AppKit
import WebKit

/// The "Ask Glance…" item in Glance's own right-click menus (the terminal, web pages in tabs, the reply view) and the
/// entry the Services menu uses for other apps. Each one opens `AskClaudePanel` on the selection.
@MainActor
public enum AskClaudeMenu {
  public static let title = "Ask Glance…"
  private static let symbol = "sparkles"

  /// The item for a selection already in hand (the terminal's). Added after Copy, which it follows in the menu.
  public static func item(selection: String, source: String?) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(Handler.ask(_:)), keyEquivalent: "")
    item.target = Handler.shared
    item.representedObject = Handler.Payload(selection: selection, source: source, webView: nil)
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return item
  }

  /// A web view's menu: when WebKit offers Copy, text is selected, and the item reads it from the page when chosen.
  /// A page that draws its own menu (Slack, Jira's editor) never reaches this.
  public static func addItem(to menu: NSMenu, for webView: WKWebView, source: String? = nil) {
    guard menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }),
          !menu.items.contains(where: { $0.action == #selector(Handler.ask(_:)) }) else { return }
    let item = NSMenuItem(title: title, action: #selector(Handler.ask(_:)), keyEquivalent: "")
    item.target = Handler.shared
    item.representedObject = Handler.Payload(selection: nil, source: source ?? webView.url?.host, webView: webView)
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    let copy = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" } ?? menu.items.count - 1
    menu.insertItem(item, at: copy + 1)
  }

  @MainActor
  private final class Handler: NSObject {
    static let shared = Handler()

    final class Payload: @unchecked Sendable {
      let selection: String?
      let source: String?
      weak var webView: WKWebView?

      init(selection: String?, source: String?, webView: WKWebView?) {
        self.selection = selection
        self.source = source
        self.webView = webView
      }
    }

    @objc func ask(_ sender: NSMenuItem) {
      guard let payload = sender.representedObject as? Payload else { return }
      if let selection = payload.selection {
        AskClaudePanel.shared.ask(selection: selection, source: payload.source)
        return
      }
      payload.webView?.evaluateJavaScript("window.getSelection().toString()") { value, _ in
        let text = value as? String ?? ""
        MainActor.assumeIsolated { AskClaudePanel.shared.ask(selection: text, source: payload.source) }
      }
    }
  }
}
