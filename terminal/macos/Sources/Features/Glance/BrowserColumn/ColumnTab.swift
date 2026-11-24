import Combine
import Foundation
import GlanceCore

/// One tab of a browser column. Its web view is made only when the tab is shown (`wake`) and dropped by `sleep`,
/// which keeps the address for the next wake (spec 2026-11-24-browser-column-design.md §1 "Pages").
@MainActor
final class ColumnTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var page: WebPage?
    @Published private(set) var state = WebViewState()
    private var parked: URL?

    init(url: URL?) { parked = url }

    /// Where the tab is, or where it goes when it wakes; nil for a New Tab.
    var url: URL? { page?.webView.url ?? parked }

    var title: String {
        if let title = page?.webView.title, !title.isEmpty { return title }
        return url.map(BrowserURL.displayHost) ?? "New Tab"
    }

    func wake() {
        guard page == nil, let parked else { return }
        load(parked)
    }

    func load(_ url: URL) {
        if page == nil {
            let made = WebPage()
            page = made
            state = WebViewState(made.webView)
        }
        page?.load(url)
    }

    func sleep() {
        guard let page else { return }
        parked = page.webView.url ?? parked
        page.close()
        self.page = nil
        state = WebViewState()
    }
}
