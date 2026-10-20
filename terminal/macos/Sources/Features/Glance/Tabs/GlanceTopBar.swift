import AppKit
import Combine
import GlanceCore
import GlanceKit
import SwiftUI

/// Glance Studio's top bar: a compact toolbar across the top of the window with the ☰ that opens the side bar and the ⌂
/// that opens Home (after the window buttons; editors are on the activity strip), the tab's title in the middle, and the repo's
/// branch with Create PR, uncommitted changes, Claude's plan usage, the quick note and the Glance button on the right. Tabs live in the sidebar, so the native tab bar never shows (see `TabSidebarModel.applyNativeTabBar`). The `tabs` titlebar style has its own toolbar, so there the ☰
/// and ⌂ stay a titlebar accessory; the `hidden` style has no titlebar for a bar. The buttons are glass that lights under
/// the pointer (`ChromeButtonStyle`).
@MainActor
enum GlanceTopBar {
    private static var barKey: UInt8 = 0

    static func install(in window: NSWindow, style: Ghostty.Config.MacOSTitlebarStyle) {
        switch style {
        case .hidden:
            return
        case .tabs:
            installAccessory(in: window)
        case .native, .transparent:
            let bar = Bar(window: window)
            // NSToolbar's delegate is weak: the window keeps the bar alive.
            objc_setAssociatedObject(window, &barKey, bar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            let toolbar = NSToolbar(identifier: "GlanceTopBar")
            toolbar.delegate = bar
            toolbar.allowsUserCustomization = false
            toolbar.centeredItemIdentifiers = [.glanceTitle]
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .line
        }
    }

    /// The ☰ and ⌂, as a titlebar accessory on the left.
    private static func installAccessory(in window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        let host = NonDraggableHostingView(rootView: HStack(spacing: 2) {
            TabSidebarToggleButton()
            HomeButton(window: window)
        })
        host.frame = NSRect(x: 0, y: 0, width: 70, height: 28)
        accessory.view = host
        window.addTitlebarAccessoryViewController(accessory)
    }

    @MainActor
    private final class Bar: NSObject, NSToolbarDelegate {
        private let title = TitleModel()
        private let changes: WorkingChangesModel
        private let branchBar: BranchBarModel
        private weak var window: NSWindow?
        private var titleToken: NSKeyValueObservation?

        init(window: NSWindow) {
            self.window = window
            changes = WorkingChangesModel(window: window)
            branchBar = BranchBarModel(window: window)
            super.init()
            syncTitle()
            titleToken = window.observe(\.title) { [weak self] _, _ in
                Task { @MainActor in self?.syncTitle() }
            }
            // The window gets its controller (and so its kind) after the toolbar is made.
            Task { @MainActor [weak self] in self?.syncTitle() }
        }

        private func syncTitle() {
            let text = ChannelLaunch.hidingFlag(in: window?.title ?? "")
            if title.text != text { title.text = text }
            guard let window else { return }
            let kind = TabSidebarModel.kind(for: window)
            if title.kind != kind { title.kind = kind }
            let symbol = TabSidebarModel.icon(for: window)
            if title.symbol != symbol { title.symbol = symbol }
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [.glanceSidebar, .glanceHome, .flexibleSpace, .glanceTitle, .flexibleSpace,
             .glanceSwap, .glanceSwitch, .glanceBranch, .glanceChanges, .glanceUsage, .glanceQuickNote, .glanceToggle]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.isBordered = false // no system glass capsule behind the item: the buttons light their own
            switch identifier {
            case .glanceSidebar:
                item.label = "Side Bar"
                item.view = NonDraggableHostingView(rootView: TabSidebarToggleButton())
            case .glanceHome:
                item.label = "Home"
                item.view = NonDraggableHostingView(rootView: HomeButton(window: window))
            case .glanceTitle:
                item.view = PassThroughHostingView(rootView: TitleView(model: title))
                item.view?.setContentCompressionResistancePriority(.required, for: .horizontal)
                item.visibilityPriority = .user
                item.isEnabled = false
            case .glanceSwap:
                item.label = "Switch Editor"
                item.view = NonDraggableHostingView(rootView: EditorSwapButton(window: window))
            case .glanceSwitch:
                item.label = "Open in Editor or Terminal"
                item.view = NonDraggableHostingView(rootView: ProjectSwitchButton(window: window))
            case .glanceBranch:
                item.label = "Create PR"
                item.view = NSHostingView(rootView: BranchBarItem(model: branchBar))
                item.visibilityPriority = .low
            case .glanceChanges:
                item.label = "Changes"
                item.view = NSHostingView(rootView: WorkingChangesItem(model: changes))
                item.visibilityPriority = .low
            case .glanceUsage:
                item.label = "Claude Usage"
                item.view = NonDraggableHostingView(rootView: PlanUsageItem())
                item.visibilityPriority = .high
            case .glanceQuickNote:
                item.label = "Quick Note"
                item.view = NonDraggableHostingView(rootView: QuickNoteButton())
                item.visibilityPriority = .high
            case .glanceToggle:
                item.label = "Glance"
                item.view = NonDraggableHostingView(rootView: GlanceToggleButton(window: window))
                item.visibilityPriority = .high
            default:
                break
            }
            return item
        }
    }

    @MainActor
    final class TitleModel: ObservableObject {
        @Published var text = ""
        @Published var kind = TabRow.Kind.terminal
        @Published var symbol = "terminal"
    }

    /// The tab's title in mono after a small mark of its kind, over a short coral line: the current tab (MASTER §8).
    private struct TitleView: View {
        @ObservedObject var model: TitleModel

        var body: some View {
            HStack(spacing: 6) {
                TabKindGlyph(kind: model.kind, symbol: model.symbol, size: 10)
                // An empty title would make the item zero-sized, and the toolbar drops zero-sized items.
                Text(model.text.isEmpty ? " " : model.text)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(GlassChrome.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(GlassChrome.lit())
                    .frame(width: 24, height: 2)
                    .opacity(0.85)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: 40, maxWidth: 520)
            .animation(GlassChrome.fade, value: model.kind)
        }
    }

    /// Clicks go through to the bar, so dragging the title moves the window.
    private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension NSToolbarItem.Identifier {
    static let glanceSidebar = NSToolbarItem.Identifier("GlanceSidebar")
    static let glanceHome = NSToolbarItem.Identifier("GlanceHome")
    static let glanceTitle = NSToolbarItem.Identifier("GlanceTitle")
    static let glanceUsage = NSToolbarItem.Identifier("GlanceUsage")
    static let glanceBranch = NSToolbarItem.Identifier("GlanceBranch")
    static let glanceChanges = NSToolbarItem.Identifier("GlanceChanges")
    static let glanceSwap = NSToolbarItem.Identifier("GlanceSwap")
    static let glanceSwitch = NSToolbarItem.Identifier("GlanceSwitch")
    static let glanceToggle = NSToolbarItem.Identifier("GlanceToggle")
    static let glanceQuickNote = NSToolbarItem.Identifier("GlanceQuickNote")
}

/// The ☰ that opens and closes the side bar (the activity strip's selected mode): lit while it's open.
private struct TabSidebarToggleButton: View {
    @ObservedObject private var model = TabSidebarModel.shared

    var body: some View {
        Button { model.isOpen.toggle() } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle(isOn: model.isOpen))
        .help("Side Bar (⇧⌘L)")
        .accessibilityLabel(model.isOpen ? "Hide Side Bar" : "Show Side Bar")
    }
}

/// The ⌂ beside the ☰: the window's Home tab, else a new one. Lit in the Home tab itself.
private struct HomeButton: View {
    weak var window: NSWindow?
    @State private var isHome = false

    var body: some View {
        Button { TabSidebarModel.shared.showHome(near: window ?? NSApp.keyWindow) } label: {
            StudioIcon(.home, size: 13)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle(isOn: isHome))
        .help("Home (⇧⌘H)")
        .accessibilityLabel("Home")
        // The window gets its controller after the toolbar is made: look once it's on screen.
        .onAppear { DispatchQueue.main.async { isHome = window.map(TabSidebarModel.kind(for:)) == .home } }
    }
}

/// In an editor tab: "Open in GS Code" or "Open in Razor Code", which swaps the tab for the other editor.
/// Nothing in a terminal tab.
private struct EditorSwapButton: View {
    weak var window: NSWindow?
    @State private var kind: EditorKind?

    var body: some View {
        Group {
            if let kind, EditorTabs.offersGSCode {
                Button { if let tab = window?.windowController as? any EditorTab { EditorTabs.swap(tab) } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: kind.other.symbol)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(GlassChrome.ink2)
                        Text(kind.swapTitle)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .contentShape(Capsule())
                }
                .buttonStyle(ChromeButtonStyle(resting: true))
                .help(kind.swapTitle)
            } else {
                Color.clear.frame(width: 1, height: 1) // the toolbar drops zero-sized items
            }
        }
        // The window gets its controller after the toolbar is made: look once it's on screen.
        .onAppear { DispatchQueue.main.async { kind = (window?.windowController as? any EditorTab)?.editorKind } }
    }
}

/// In a terminal tab "Open in Editor", in an editor tab "Open in Terminal" (spec 2026-10-11-strip-switching-design.md
/// §4), with its ⌥⌘E chip. Below 1280 pt of window it shows the icon and the chip only, so the title stays clear.
private struct ProjectSwitchButton: View {
    weak var window: NSWindow?
    @State private var direction: ProjectSwitch.Direction?
    @State private var compact = false
    @ObservedObject private var rows = TabSidebarModel.shared.rowsChange // the help text follows the open tabs

    var body: some View {
        Group {
            if let direction {
                Button { ProjectSwitch.toggle(window) } label: {
                    HStack(spacing: 6) {
                        if direction == .toEditor {
                            StudioIcon(.editor, size: 12).foregroundStyle(GlassChrome.ink2)
                        } else {
                            Text(">_").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(GlassChrome.ink2)
                        }
                        if !compact {
                            Text(direction == .toEditor ? "Open in Editor" : "Open in Terminal")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text("⌥⌘E").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(GlassChrome.ink2)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .contentShape(Capsule())
                }
                .buttonStyle(ChromeButtonStyle(resting: true))
                .help(helpText)
                .accessibilityLabel(direction == .toEditor ? "Open in Editor" : "Open in Terminal")
            } else {
                Color.clear.frame(width: 1, height: 1) // the toolbar drops zero-sized items
            }
        }
        // The window gets its controller after the toolbar is made: look once it's on screen.
        .onAppear { DispatchQueue.main.async { direction = ProjectSwitch.direction(for: window); fit() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: window)) { _ in fit() }
    }

    private func fit() { compact = (window?.frame.width ?? 2000) < 1280 }

    /// Read through `rows` so the text is redone when tabs open, close or move.
    private var helpText: String {
        _ = rows.revision
        return ProjectSwitch.help(for: window)
    }
}

/// Opens the quick note box (⌃⌥N from any app), which saves into Notes.
private struct QuickNoteButton: View {
    var body: some View {
        Button { QuickNotePanel.shared.show() } label: {
            StudioIcon(.notes, size: 13)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle())
        .help("Quick Note (⌃⌥N)")
        .accessibilityLabel("Quick Note")
    }
}

/// Opens and closes Glance in this window, as a sidebar or a floating orb.
private struct GlanceToggleButton: View {
    weak var window: NSWindow?
    @ObservedObject private var layout = GlanceLayoutModel.shared

    private var isOpen: Bool {
        _ = layout.paneRevision
        return (window?.windowController as? GlancePaneOwner)?.glancePaneOpen ?? false
    }

    var body: some View {
        let open = isOpen
        Button { GlanceTerminalHost.shared.toggleGlance(in: window) } label: {
            GlanceOrb(open: open)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle(tint: GlassChrome.coral, onInk: GlassChrome.coralInk))
        .help(open ? "Close Glance" : "Open Glance (⌥Space)")
        .accessibilityLabel(open ? "Close Glance" : "Open Glance")
    }
}

/// Glance's presence: while Glance is open, a lit coral sphere with a specular highlight and a halo that breathes
/// slowly (only while the window is in front and on screen, and never under Reduce Motion); a quiet ring while closed.
private struct GlanceOrb: View {
    let open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        ZStack {
            if open {
                sphere
                    .background {
                        // The halo breathes; it is bigger than the orb so its blur isn't clipped.
                        Breathing(period: 4, running: activeState != .inactive, low: 0.35) {
                            Circle()
                                .fill(GlassChrome.coral)
                                .blur(radius: 3.5)
                                .padding(6)
                                .opacity(0.75)
                        }
                        .frame(width: 29, height: 29)
                        .allowsHitTesting(false)
                    }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
            } else {
                Circle()
                    .strokeBorder(.foreground, lineWidth: 1.3)
                    .transition(.opacity)
            }
        }
        .frame(width: 13, height: 13)
        .animation(reduceMotion ? GlassChrome.fade : .spring(response: 0.38, dampingFraction: 0.68), value: open)
    }

    private var sphere: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [GlassChrome.coralHi, GlassChrome.coral, GlassChrome.coralLo],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 9))
            // The specular highlight, up and to the left.
            Ellipse()
                .fill(Color.white.opacity(0.75))
                .frame(width: 5, height: 3)
                .blur(radius: 0.5)
                .offset(x: -2, y: -3.2)
            Circle()
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
        }
    }
}
