import AppKit
import GhosttyKit
import GlanceCore // GLANCE
import OSLog
import SwiftUI

/// What a pane's shell reports (see `ShellAssist.paneSnapshot`).
struct PaneSnapshot {
    let folder: String
    let running: String?
    let lastCommand: String?
    let lastExit: Int?
}

/// GLANCE: how a window's split panes are presented. The split tree itself is never touched: a minimized pane is left
/// out of the tree that gets drawn (its terminal keeps running, exactly as when another pane is zoomed) and sits in a
/// dock of slim strips under the panes; the tabs view draws one pane at a time under a tab bar. A pane's strip and
/// chip show its folder, command, latest output line and whether it is running, done or failed.
@MainActor
final class PaneLayoutModel: ObservableObject {
    typealias Tree = SplitTree<Ghostty.SurfaceView>
    typealias Node = Tree.Node

    enum State: Equatable { case running, done, failed, idle }

    struct Status: Equatable {
        var folder = ""
        var command = ""
        var line = ""
        var state = State.idle
        /// 0...100 from the program's own progress report (OSC 9;4), when it sends one.
        var percent: Int?
    }

    /// Everything the split view draws for a tree.
    struct Layout {
        var node: Node?
        /// The drawn node is the whole picture (no divider, nothing to dim).
        var isRoot = true
        /// Splits whose drawn node differs from the tree's, back to the tree's own for resizing.
        var origins: [Node.StructuralIdentity: Node] = [:]
        var docked: [Ghostty.SurfaceView] = []
        /// In the tabs view: every pane, in tree order.
        var tabs: [Ghostty.SurfaceView]?
        var active: UUID?
        /// The hover controls are offered (the window has more than one pane).
        var controls = false
        var canMinimize = false
        var isZoomed = false
    }

    /// Minimized panes, oldest first (the dock's order).
    @Published private(set) var minimized: [UUID] = []
    @Published private(set) var tabbed = false
    @Published private(set) var active: UUID?
    @Published private(set) var statuses: [UUID: Status] = [:]
    /// Minimized panes whose command ended since they were minimized: the dock draws them louder.
    @Published private(set) var attention: Set<UUID> = []
    /// The tab bar's own order (the split layout keeps the tree's), and names the user gave panes.
    @Published private(set) var tabOrder: [UUID] = []
    @Published private(set) var names: [UUID: String] = [:]
    /// The pane whose tab is being renamed.
    @Published var renaming: UUID?

    private var views: [UUID: Weak<Ghostty.SurfaceView>] = [:]
    private var order: [UUID] = []
    private var timer: Timer?
    /// The tree last drawn, and whether a sync to it is queued (`resyncIfStale`).
    private var drawn: Tree?
    private var resyncQueued = false

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Glance Studio", category: "PaneLayout")

    static let animation = Animation.spring(response: 0.3, dampingFraction: 0.88)

    // MARK: Relaunch

    /// What a window keeps across a relaunch: the pane tabs' names and order, which panes are minimized, whether the
    /// tabs view is on and the pane it shows. Keys are pane (surface) IDs, which restoration keeps.
    struct Saved: Codable, Equatable {
        var names: [String: String] = [:]
        var tabOrder: [String] = []
        var minimized: [String] = []
        var tabbed = false
        var active: String?
        var isDefault: Bool { self == Saved() }
    }

    /// The models on screen, found by any of their panes, so a window's state can be read without the view.
    private static var live: [UUID: Weak<PaneLayoutModel>] = [:]
    /// Restored windows' saved state, by each of their panes, until their view first syncs.
    private static var pending: [UUID: Saved] = [:]

    /// The saved state of the window whose panes are `ids`; nil when it has nothing worth keeping.
    static func saved(panes ids: [UUID]) -> Saved? {
        guard let model = ids.lazy.compactMap({ live[$0]?.value }).first else {
            return ids.lazy.compactMap { pending[$0] }.first
        }
        let state = model.snapshot()
        return state.isDefault ? nil : state
    }

    /// A restored window's panes, before its view exists.
    static func stage(_ saved: Saved, panes ids: [UUID]) {
        for id in ids { pending[id] = saved }
    }

    private func snapshot() -> Saved {
        let ids = Set(order)
        return Saved(
            names: Dictionary(uniqueKeysWithValues: names.filter { ids.contains($0.key) }.map { ($0.key.uuidString, $0.value) }),
            tabOrder: tabOrder.filter(ids.contains).map(\.uuidString),
            minimized: minimized.filter(ids.contains).map(\.uuidString),
            tabbed: tabbed && order.count > 1,
            active: active?.uuidString)
    }

    private func apply(_ saved: Saved) {
        let ids = Set(order)
        func uuid(_ string: String) -> UUID? { UUID(uuidString: string).flatMap { ids.contains($0) ? $0 : nil } }
        names = Dictionary(uniqueKeysWithValues: saved.names.compactMap { key, name in uuid(key).map { ($0, name) } })
        tabOrder = saved.tabOrder.compactMap(uuid) + order.filter { id in !saved.tabOrder.contains(id.uuidString) }
        minimized = saved.minimized.compactMap(uuid)
        if let active = saved.active.flatMap(uuid) { self.active = active }
        tabbed = saved.tabbed && order.count > 1
        updatePolling()
    }

    /// Asks AppKit to save the window again, so a rename or a reorder survives a quit that follows at once.
    private func changed() {
        views.values.lazy.compactMap { $0.value?.window }.first?.invalidateRestorableState()
    }

    // MARK: Layout

    func layout(for tree: Tree) -> Layout {
        let leaves = tree.root?.leaves() ?? []
        resyncIfStale(tree, leaves: leaves)
        if let zoomed = tree.zoomed {
            return Layout(node: zoomed, isRoot: zoomed == tree.root, controls: leaves.count > 1, isZoomed: true)
        }
        guard leaves.count > 1 else { return Layout(node: tree.root) }

        if tabbed {
            let current = leaves.first { $0.id == active } ?? leaves[0]
            return Layout(node: tree.root?.node(view: current), tabs: ordered(leaves), active: current.id)
        }

        let ids = Set(leaves.map(\.id))
        var hidden = minimized.filter { ids.contains($0) }
        // The last pane left can't be minimized; if every pane is, the newest one comes back.
        if hidden.count == leaves.count { hidden.removeLast() }
        let hiddenSet = Set(hidden)
        var origins: [Node.StructuralIdentity: Node] = [:]
        let node = tree.root.flatMap { Self.pruned($0, hiding: hiddenSet, origins: &origins) }
        let visible = leaves.count - hidden.count
        return Layout(
            node: node, isRoot: visible == 1, origins: origins,
            docked: hidden.compactMap { id in leaves.first { $0.id == id } },
            controls: true, canMinimize: visible > 1)
    }

    /// The view syncs on appear and on each tree change, yet a window has drawn its tabs from panes this model never
    /// synced: every tab a bare "Terminal" (no status was read) and drag to reorder dead (the dragged tab isn't in
    /// `tabOrder`). The tree drawn is the truth, so when it isn't the one synced, sync on the next turn (not during
    /// the view update). A normal tree change syncs through the view before then, so only a missed one logs.
    private func resyncIfStale(_ tree: Tree, leaves: [Ghostty.SurfaceView]) {
        drawn = tree
        guard !resyncQueued, !isSynced(leaves) else { return }
        resyncQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let tree = drawn else { return }
            resyncQueued = false
            let leaves = tree.root?.leaves() ?? []
            guard !isSynced(leaves) else { return }
            Self.logger.notice("pane layout missed a tree change: synced \(self.order.count, privacy: .public) panes, drawing \(leaves.count, privacy: .public)")
            sync(tree)
        }
    }

    private func isSynced(_ leaves: [Ghostty.SurfaceView]) -> Bool {
        leaves.map(\.id) == order && leaves.allSatisfy { views[$0.id]?.value === $0 }
    }

    /// `node` without the hidden panes: a split loses a hidden side and becomes the other. `origins` remembers each
    /// rebuilt split's real one, so a divider drag resizes the node the controller has.
    private static func pruned(_ node: Node, hiding hidden: Set<UUID>, origins: inout [Node.StructuralIdentity: Node]) -> Node? {
        switch node {
        case .leaf(let view):
            return hidden.contains(view.id) ? nil : node
        case .split(let split):
            let left = pruned(split.left, hiding: hidden, origins: &origins)
            let right = pruned(split.right, hiding: hidden, origins: &origins)
            switch (left, right) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let left?, let right?):
                guard left != split.left || right != split.right else { return node }
                let rebuilt = Node.split(.init(direction: split.direction, ratio: split.ratio, left: left, right: right))
                origins[rebuilt.structuralIdentity] = node
                return rebuilt
            }
        }
    }

    // MARK: Changes

    /// The tree changed: forget panes that are gone, and in the tabs view show a pane that just appeared.
    func sync(_ tree: Tree) {
        let leaves = tree.root?.leaves() ?? []
        let ids = leaves.map(\.id)
        let hadPanes = !order.isEmpty
        let added = Set(ids).subtracting(order)
        order = ids
        views = Dictionary(uniqueKeysWithValues: leaves.map { ($0.id, Weak($0)) })
        for id in ids { Self.live[id] = Weak(self) }
        minimized.removeAll { !ids.contains($0) }
        attention.formIntersection(ids)
        statuses = statuses.filter { ids.contains($0.key) }
        names = names.filter { ids.contains($0.key) }
        tabOrder = tabOrder.filter { ids.contains($0) } + ids.filter { !tabOrder.contains($0) }
        if let renaming, !ids.contains(renaming) { self.renaming = nil }
        if tabbed, hadPanes, let newest = leaves.last(where: { added.contains($0.id) }) {
            active = newest.id
        } else if !ids.contains(where: { $0 == active }) {
            active = ids.first
        }
        if leaves.count < 2, tabbed { tabbed = false }
        updatePolling()
        // A restored window's saved state, applied once its panes are here.
        if let saved = ids.lazy.compactMap({ Self.pending[$0] }).first {
            for id in ids { Self.pending[id] = nil }
            apply(saved)
        }
        changed()
    }

    func minimize(_ view: Ghostty.SurfaceView) {
        guard !minimized.contains(view.id), order.count - minimized.count > 1 else { return }
        let next = order.first { $0 != view.id && !minimized.contains($0) }
        withAnimation(Self.animation) { minimized.append(view.id) }
        changed()
        attention.remove(view.id)
        if view.window?.firstResponder === view, let next, let target = views[next]?.value {
            Ghostty.moveFocus(to: target, from: view)
        }
        updatePolling()
    }

    func restore(_ view: Ghostty.SurfaceView) {
        withAnimation(Self.animation) { minimized.removeAll { $0 == view.id } }
        changed()
        attention.remove(view.id)
        Ghostty.moveFocus(to: view)
        updatePolling()
    }

    func toggleTabs() {
        if !tabbed {
            // The tabs open on the pane you were typing in.
            let focused = order.compactMap { views[$0]?.value }.first { $0.window?.firstResponder === $0 }
            active = focused?.id ?? active ?? order.first
        }
        withAnimation(Self.animation) { tabbed.toggle() }
        changed()
        if let view = active.flatMap({ views[$0]?.value }) { Ghostty.moveFocus(to: view) }
        updatePolling()
    }

    func select(_ view: Ghostty.SurfaceView) {
        let switched = tabbed && active != view.id
        withAnimation(Self.animation) { active = view.id }
        changed()
        Ghostty.moveFocus(to: view)
        if switched { fadeIn(view) }
    }

    /// A pane tab switch crossfades like a window tab switch (`TabSidebarModel.fadeIn`): the pane that comes to the
    /// front fades up from a dimmer state over 0.18 s. One Core Animation on its layer, so it costs the main thread
    /// nothing while it plays, and nothing at all under Reduce Motion. It starts a beat later, once SwiftUI has put the
    /// pane in the window.
    private func fadeIn(_ view: Ghostty.SurfaceView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak view] in
            guard let layer = view?.layer else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.35
            fade.toValue = 1
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "paneSwitch")
        }
    }

    // MARK: Tab order and names

    /// `leaves` in the tab bar's order.
    private func ordered(_ leaves: [Ghostty.SurfaceView]) -> [Ghostty.SurfaceView] {
        let rank = Dictionary(uniqueKeysWithValues: tabOrder.enumerated().map { ($1, $0) })
        return leaves.enumerated().sorted {
            (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset)
        }.map(\.element)
    }

    /// Moves a tab to where `target` is (the dragged tab takes its place and the rest shift).
    func moveTab(_ id: UUID, to target: UUID) {
        guard id != target, let from = tabOrder.firstIndex(of: id), let to = tabOrder.firstIndex(of: target) else { return }
        withAnimation(Self.animation) { tabOrder.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to) }
        changed()
    }

    /// Moves a tab one place (the menu's Move Left and Move Right).
    func nudgeTab(_ id: UUID, by step: Int) {
        guard let from = tabOrder.firstIndex(of: id), tabOrder.indices.contains(from + step) else { return }
        moveTab(id, to: tabOrder[from + step])
    }

    func canNudge(_ id: UUID, by step: Int) -> Bool {
        tabOrder.firstIndex(of: id).map { tabOrder.indices.contains($0 + step) } ?? false
    }

    /// Ends a rename: nil cancels, an empty name goes back to the folder's, anything else is the pane's name.
    func finishRename(_ view: Ghostty.SurfaceView, name: String?) {
        guard renaming == view.id else { return }
        renaming = nil
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            names[view.id] = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
            changed()
        }
        Ghostty.moveFocus(to: view)
    }

    /// Sets a name without going through the tab's editor (Reset Name).
    func finishRenameNow(_ view: Ghostty.SurfaceView, name: String) {
        renaming = view.id
        finishRename(view, name: name)
    }

    /// A pane's status as the strips and chips show it: its folder's place taken by the name it was given.
    func status(for id: UUID) -> Status {
        var status = statuses[id] ?? Status()
        if let name = names[id] { status.folder = name }
        return status
    }

    // MARK: Status

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The strips and chips are live only while they're on screen: one 1 s tick reads them, and nothing runs when no
    /// pane is minimized and the tabs view is off.
    private func updatePolling() {
        let needed = !minimized.isEmpty || (tabbed && order.count > 1)
        if !needed {
            stop()
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
        }
    }

    private func refresh() {
        let wanted = tabbed ? order : minimized
        var next = statuses
        for id in wanted {
            guard let view = views[id]?.value else { continue }
            let status = Self.status(of: view)
            let before = statuses[id]?.state
            if minimized.contains(id), before == .running, status.state == .done || status.state == .failed {
                attention.insert(id)
            }
            next[id] = status
        }
        if next != statuses { statuses = next }
    }

    private static func status(of view: Ghostty.SurfaceView) -> Status {
        let snapshot = ShellAssist.shared.paneSnapshot(for: view)
        var status = Status()
        // The shell's folder arrives with its first prompt, and Ghostty's pwd only with shell integration: until then
        // (or without them) read where the pane's process actually is, so its tab never shows a bare "Terminal".
        status.folder = folderName([snapshot?.folder, view.pwd].lazy.compactMap { $0 }.first { !$0.isEmpty }
                                   ?? processFolder(of: view))
        if let running = snapshot?.running {
            status.state = .running
            status.command = running
        } else if let exit = snapshot?.lastExit {
            status.state = Corrections.notFailures.contains(exit) ? .done : .failed
            status.command = snapshot?.lastCommand ?? ""
        } else {
            status.command = view.title
        }
        // While a command runs the screen's tail is its output; once it ended, the prompt is, so read its output.
        let text = status.state == .idle || status.state == .running ? SurfaceScreen.visibleText(view) : lastOutput(of: view)
        status.line = text.flatMap(lastLine) ?? ""
        if let report = view.progressReport, report.state == .set, let progress = report.progress {
            status.percent = Int(progress)
        }
        return status
    }

    private static func lastOutput(of view: Ghostty.SurfaceView) -> String? {
        guard let surface = view.surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_last_output(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    private static func lastLine(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let trimmed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !trimmed.isEmpty { return String(trimmed.prefix(200)) }
        }
        return nil
    }

    /// The working directory of the pane's foreground process, from the kernel.
    private static func processFolder(of view: Ghostty.SurfaceView) -> String? {
        guard let pid = view.surfaceModel?.foregroundPID.flatMap(pid_t.init(exactly:)) else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    static func folderName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        if path == NSHomeDirectory() { return "~" }
        return (path as NSString).lastPathComponent
    }
}
