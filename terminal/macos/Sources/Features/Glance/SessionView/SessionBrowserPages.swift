import Combine
import GlanceCore
import GlanceKit

/// Whether Claude's browser has windows to show (Chromium; Lightpanda has none), as a published value: the broker's
/// engine is a plain property, so this follows its `onEngineChanged`.
@MainActor
final class SessionBrowserGate: ObservableObject {
    static let shared = SessionBrowserGate()

    @Published private(set) var hasWindows: Bool

    private init() {
        let broker = AgentBrowserBroker.shared
        hasWindows = broker.engine == .chromium
        broker.onEngineChanged = { [weak self] engine in self?.hasWindows = engine == .chromium }
    }
}

/// The pages open in one session's browser windows, derived from the window table and the browser's pages. It
/// publishes only when this session's list changes, not on every tool call or title of any other session.
@MainActor
final class SessionBrowserPages: ObservableObject {
    private struct Key: Equatable {
        var claudePID: Int32?
        var session: String?
    }

    @Published private(set) var pages: [AgentBrowserModel.Page] = []
    /// The page that appeared or changed address last, else nil: what Show browser brings forward.
    private(set) var lastChanged: String?

    private let key = CurrentValueSubject<Key, Never>(Key())
    private var watch: AnyCancellable?

    init() {
        watch = Publishers.CombineLatest3(AgentBrowserSessions.shared.$table, AgentBrowserModel.shared.$pages, key)
            .map { table, pages, key in
                // A page the browser hasn't reported yet isn't one to show.
                table.pages(claudePID: key.claudePID, session: key.session).compactMap { id in pages.first { $0.id == id } }
            }
            .removeDuplicates()
            .sink { [weak self] next in self?.apply(next) }
    }

    /// The `claude` process and session whose windows to show; the session id finds them when the process isn't known.
    func follow(claudePID: Int32?, session: String?) {
        key.send(Key(claudePID: claudePID, session: session))
    }

    /// The page Show browser brings forward: the one that changed last while it is open, else the newest.
    var front: String? {
        if let lastChanged, pages.contains(where: { $0.id == lastChanged }) { return lastChanged }
        return pages.last?.id
    }

    private func apply(_ next: [AgentBrowserModel.Page]) {
        let before = Dictionary(pages.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        if let changed = next.last(where: { before[$0.id] != $0.url }) { lastChanged = changed.id }
        pages = next
    }
}
