import AppKit
import Combine
import GlanceCore

/// The Terminal side bar's tab groups (spec 2026-10-11-tab-groups-design.md): which group each terminal tab is in,
/// keyed by its window, and each group's name and fold, saved in the defaults after every change. A tab's group is also
/// saved with its window (`TerminalRestorableState.glanceGroup`), so relaunching brings it back.
@MainActor
final class TabGroups: ObservableObject {
    static let shared = TabGroups()

    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard
    private static let key = "tabGroups"

    private var book: TabGroupBook<ObjectIdentifier>
    /// The group whose name field is open: one just made, or Rename.
    @Published var renaming: UUID?

    private init() {
        let saved = Self.defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([TabGroupInfo].self, from: $0) } ?? []
        book = TabGroupBook(groups: saved)
    }

    /// Groups show in the side bar (Develop menu → Tab Groups in a development build).
    var isOn: Bool { StudioFeatures.shared.isOn(.tabGroups) }

    var membership: [ObjectIdentifier: UUID] { book.membership }
    var groups: [UUID: TabGroupInfo] { book.groups }
    func info(_ id: UUID) -> TabGroupInfo? { book.groups[id] }
    func group(of window: NSWindow) -> UUID? { book.group(of: ObjectIdentifier(window)) }

    /// `rows` (the Terminal side bar's, in tab order) as sections and as drawn items.
    func sections(for rows: [TabRow]) -> [TabGroupLayout.Section<ObjectIdentifier>] {
        TabGroupLayout.sections(rows.map(\.id), membership: book.membership, groups: book.groups)
    }

    func items(for rows: [TabRow]) -> [TabGroupLayout.Item<ObjectIdentifier>] {
        TabGroupLayout.items(sections(for: rows))
    }

    /// The groups with a tab among `rows`, top to bottom: what Move to Group offers.
    func groups(in rows: [TabRow]) -> [TabGroupInfo] {
        sections(for: rows).compactMap(\.group)
    }

    // MARK: Changes

    /// Add to New Group: a group around the window's tab, its name field open.
    @discardableResult
    func newGroup(with window: NSWindow) -> UUID {
        let id = book.newGroup(with: ObjectIdentifier(window))
        renaming = id
        changed([window])
        return id
    }

    func assign(_ window: NSWindow, to group: UUID?) {
        book.assign(ObjectIdentifier(window), to: group)
        changed([window])
    }

    /// A restored window's saved group; an ID whose group is gone leaves it ungrouped.
    func restore(_ window: NSWindow, to group: UUID?) {
        guard let group else { return }
        book.assign(ObjectIdentifier(window), to: group)
        TabSidebarModel.shared.refreshSoon()
    }

    func rename(_ id: UUID, to name: String) {
        book.rename(id, to: name)
        if renaming == id { renaming = nil }
        changed([])
    }

    func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        book.setCollapsed(id, collapsed)
        changed([])
    }

    /// Ungroup: the tabs stay, out of any group. `windows` are the group's, so their saved state forgets it.
    func ungroup(_ id: UUID, windows: [NSWindow]) {
        book.dissolve(id)
        changed(windows)
    }

    /// Forgets tabs that have closed.
    func keep(only windows: [NSWindow]) {
        book.keep(only: Set(windows.map(ObjectIdentifier.init)))
    }

    /// At quit: only the groups some open tab is in are kept.
    func prune() {
        save(book.inUse)
    }

    private func changed(_ windows: [NSWindow]) {
        for window in windows { window.invalidateRestorableState() }
        save(book.all)
        TabSidebarModel.shared.refreshSoon()
    }

    private func save(_ groups: [TabGroupInfo]) {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        Self.defaults.set(data, forKey: Self.key)
    }
}
