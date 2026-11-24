import AppKit
import Combine
import GlanceCore
import WebKit

/// A terminal tab's browser column: its tabs, the selected one, the width the user dragged to. Owned by the tab's
/// `BaseTerminalController`, so switching Terminal ⇄ Hyperviz or closing the column loses nothing.
@MainActor
final class BrowserColumnModel: ObservableObject, AddressTarget {
    static let sleepAfter: TimeInterval = 600

    @Published private(set) var tabs: [ColumnTab]
    @Published private(set) var selectedID: UUID
    /// nil: 42% of the space (BrowserColumnLayout).
    @Published var savedWidth: Double?
    @Published var addressFocus = 0
    private weak var controller: BaseTerminalController?
    private var sleepTimer: Timer?

    init(controller: BaseTerminalController) {
        self.controller = controller
        let first = ColumnTab(url: nil)
        tabs = [first]
        selectedID = first.id
    }

    var selected: ColumnTab { tabs.first { $0.id == selectedID } ?? tabs[0] }

    // MARK: AddressTarget

    var window: NSWindow? { controller?.window }
    var webView: WKWebView? { selected.page?.webView }
    var addressTabKey: String? { nil }

    func go(_ text: String) {
        guard let url = BrowserURL.resolve(text, engine: BrowserData.searchEngine) else { return }
        go(url)
    }

    func go(_ url: URL) {
        if BrowserURL.destination(url) == .system {
            NSWorkspace.shared.open(url)
            return
        }
        selected.load(url)
    }

    // MARK: Tabs

    func newTab(_ url: URL? = nil) {
        let tab = ColumnTab(url: nil)
        var list = BrowserColumnTabs(ids: tabs.map(\.id), selected: selectedID)!
        list.add(tab.id)
        tabs.insert(tab, at: list.ids.firstIndex(of: tab.id)!)
        selectedID = list.selected
        if let url { go(url) } else { addressFocus += 1 }
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        selected.wake()
    }

    func close(_ id: UUID) {
        var list = BrowserColumnTabs(ids: tabs.map(\.id), selected: selectedID)!
        guard list.close(id) else { return }
        tabs.first { $0.id == id }?.sleep()
        tabs.removeAll { $0.id == id }
        selectedID = list.selected
        selected.wake()
    }

    /// A web link from the terminal or the Hyperviz view: in the selected tab when it's a New Tab, else a new tab.
    func open(_ url: URL) {
        selected.url == nil ? go(url) : newTab(url)
    }

    // MARK: Showing

    /// The column came on screen: the selected tab wakes, nothing goes to sleep.
    func shown() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        selected.wake()
        if selected.url == nil { addressFocus += 1 }
    }

    /// The column left the screen: its pages are dropped after 10 minutes unless it comes back.
    func hidden() {
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: Self.sleepAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tabs.forEach { $0.sleep() } }
        }
    }

    /// The terminal tab closed: no timer left behind, no page left alive.
    func shutdown() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        tabs.forEach { $0.sleep() }
    }

    // MARK: Saving

    func saved(open: Bool) -> BrowserColumnSaved? {
        BrowserColumnSaved.make(open: open, width: savedWidth, urls: tabs.map(\.url),
                                selected: tabs.firstIndex { $0.id == selectedID } ?? 0)
    }

    /// Back from a saved state: tabs parked on their addresses, nothing loads until the column shows.
    func restore(_ saved: BrowserColumnSaved) {
        tabs.forEach { $0.sleep() }
        let restored = saved.restoredURLs.map(ColumnTab.init(url:))
        tabs = restored
        selectedID = restored[saved.restoredSelection].id
        savedWidth = saved.width
    }
}
