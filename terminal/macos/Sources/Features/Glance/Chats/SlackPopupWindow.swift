import AppKit
import GlanceCore
import WebKit

/// A window a Slack page opened (SSO uses them): Studio's shared pop-up, titled "Slack", keeping Slack's pages, and
/// while signing in every page.
@MainActor
final class SlackPopupWindow {
    let webView: WKWebView

    init(configuration: WKWebViewConfiguration, signingIn: Bool, over parent: NSWindow?) {
        webView = WebPopupWindow(configuration: configuration, title: "Slack", over: parent) { url in
            SlackURL.route(url, signingIn: signingIn) == .stay
        }.webView
    }
}
