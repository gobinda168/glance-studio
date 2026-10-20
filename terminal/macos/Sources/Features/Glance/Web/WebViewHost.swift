import SwiftUI
import WebKit

/// A tab's web view in SwiftUI. The view is moved into this container from wherever it was, so a tab that rebuilds
/// its SwiftUI keeps the same page.
struct WebViewHost: NSViewRepresentable {
    let view: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
