import Combine
import WebKit

/// What the top bar shows of a web view, kept current by key-value observing; empty for the start page.
@MainActor
final class WebViewState: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var isSecure = false
    private var tokens: [NSKeyValueObservation] = []

    init() {}

    init(_ webView: WKWebView) {
        watch(webView, \.url) { $0.url = $1.url }
        watch(webView, \.title) { $0.title = $1.title ?? "" }
        watch(webView, \.canGoBack) { $0.canGoBack = $1.canGoBack }
        watch(webView, \.canGoForward) { $0.canGoForward = $1.canGoForward }
        watch(webView, \.isLoading) { $0.isLoading = $1.isLoading }
        watch(webView, \.estimatedProgress) { $0.progress = $1.estimatedProgress }
        watch(webView, \.hasOnlySecureContent) { $0.isSecure = $1.hasOnlySecureContent }
    }

    private func watch<Value>(_ webView: WKWebView, _ path: KeyPath<WKWebView, Value>,
                              _ apply: @escaping (WebViewState, WKWebView) -> Void) {
        tokens.append(webView.observe(path, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated { if let self { apply(self, view) } }
        })
    }
}
