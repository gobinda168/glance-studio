import AppKit
import WebKit

/// What the address field drives: a Browser tab, or a terminal tab's browser column (spec
/// 2026-11-24-browser-column-design.md §1).
@MainActor
protocol AddressTarget: ObservableObject {
    /// Going up puts the caret in the field with everything selected (⌘L).
    var addressFocus: Int { get }
    var window: NSWindow? { get }
    var webView: WKWebView? { get }
    /// This target's own Browser tab, left out of the open-tab suggestions; nil for a column.
    var addressTabKey: String? { get }
    func go(_ text: String)
    func go(_ url: URL)
}
