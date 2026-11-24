import SwiftUI
import GhosttyKit
import GlanceCore // GLANCE
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    // GLANCE: whether this window shows the Glance side pane.
    var glancePaneOpen: Bool { get set }

    // GLANCE: where it shows (a sidebar or a floating orb), from the window's width; nil until measured.
    var glancePlacement: PaneLayout.Placement? { get set }

    // GLANCE: whether this tab shows the Glance view of its Claude session instead of the terminal (the terminal keeps
    // running underneath). Spec 2026-11-01-command-center-design.md §2.
    var glanceMode: Bool { get set }

    // GLANCE: whether this tab shows its browser column (spec 2026-11-24-browser-column-design.md §1).
    var browserColumnOpen: Bool { get set }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // GLANCE: the split view's width, measured; the browser column shares it (less the Glance side pane) with the terminal.
    @State private var splitWidth: CGFloat = 0

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // GLANCE: the side bar's shared state (open, width).
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                // GLANCE: the activity strip's side bar at its own fixed width, then the terminal and the Glance side
                // pane on its right (body kept at its upstream indent).
                HStack(spacing: 0) {
                if tabSidebar.isOpen { SidebarColumn() }
                HSplitView {
                VStack(spacing: 0) {
                    // If we're running in debug mode we show a warning so that users
                    // know that performance will be degraded.
                    if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                        DebugBuildWarningView()
                    }

                    TerminalSplitTreeView(
                        tree: viewModel.surfaceTree,
                        action: { delegate?.performSplitAction($0) })
                        .environmentObject(ghostty)
                        .ghosttyLastFocusedSurface(lastFocusedSurface)
                        .focused($focused)
                        .onAppear { self.focused = true }
                        .onChange(of: focusedSurface) { newValue in
                            // We want to keep track of our last focused surface so even if
                            // we lose focus we keep this set to the last non-nil value.
                            if newValue != nil {
                                lastFocusedSurface = .init(newValue)
                                self.delegate?.focusedSurfaceDidChange(to: newValue)
                            }
                        }
                        .onChange(of: pwdURL) { newValue in
                            self.delegate?.pwdDidChange(to: newValue)
                        }
                        .onChange(of: cellSize) { newValue in
                            guard let size = newValue else { return }
                            self.delegate?.cellSizeDidChange(to: size)
                        }
                        .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                               idealHeight: lastFocusedSurface?.value?.initialSize?.height)
                }
                // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == .hidden ? .top : [])
                .frame(minWidth: 300, maxWidth: .infinity)
                // GLANCE: in narrow windows (or unpinned) the pane floats over the terminal as an orb.
                .overlay(alignment: .bottomTrailing) {
                    if viewModel.glancePaneOpen && viewModel.glancePlacement == .floating {
                        GlanceFloatView()
                            .padding(.trailing, coverWidth) // GLANCE: the orb and its card stay left of an overlaid browser column.
                    }
                }
                // GLANCE: the Glance view of this tab's Claude session, over the (still running) terminal.
                .overlay {
                    if viewModel.glanceMode, StudioFeatures.shared.isOn(.commandCenter),
                       let controller = delegate as? BaseTerminalController {
                        SessionView(model: controller.glanceSessionModel())
                            // GLANCE: lays out only beside an overlaid browser column, never under it.
                            .padding(.trailing, coverWidth)
                            .transition(.opacity.animation(.easeOut(duration: 0.16)))
                    }
                }
                // GLANCE: a tab too narrow for both: the column covers its right side.
                .overlay(alignment: .trailing) {
                    if showsColumn, BrowserColumnLayout.overlays(space: Double(columnSpace)),
                       let controller = delegate as? BaseTerminalController {
                        BrowserColumnView(model: controller.browserColumn)
                            .browserColumnWidth(model: controller.browserColumn, space: columnSpace, overlay: true)
                    }
                }

                // GLANCE: the browser column beside the terminal or Hyperviz view (spec 2026-11-24-browser-column-design.md).
                if showsColumn, !BrowserColumnLayout.overlays(space: Double(columnSpace)),
                   let controller = delegate as? BaseTerminalController {
                    BrowserColumnView(model: controller.browserColumn)
                        .browserColumnWidth(model: controller.browserColumn, space: columnSpace, overlay: false)
                }

                if viewModel.glancePaneOpen && viewModel.glancePlacement == .sidebar {
                    GlancePaneView()
                        .glanceSidebar()
                }
                }
                // GLANCE: what the browser column shares with the terminal: the split view without the Glance side pane.
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { splitWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { splitWidth = $0 }
                })
                } // GLANCE: the side bar's HStack
                .glancePlacement($viewModel.glancePlacement) // GLANCE
                .activityStrip() // GLANCE: the icon strip at the window's left edge

                if let surfaceView = lastFocusedSurface?.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        ghosttyConfig: ghostty.config,
                        updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                        self.delegate?.performAction(action, on: surfaceView)
                    }
                }

                // GLANCE: update news is the toast that `activityStrip()` puts at the window's bottom left.
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
        }
    }

    // GLANCE: the browser column shows on this tab (the flag is checked here too, so switching it off hides it at once).
    private var showsColumn: Bool { viewModel.browserColumnOpen && StudioFeatures.shared.isOn(.browserColumn) }

    // GLANCE: what the browser column shares with the terminal: the split view's width less the Glance side pane when
    // it's a sidebar (worked out at each render, so opening or closing the pane counts at once).
    private var columnSpace: CGFloat {
        let pane = viewModel.glancePaneOpen && viewModel.glancePlacement == .sidebar ? GlanceLayoutModel.shared.sidebarWidth : 0
        return max(0, splitWidth - pane)
    }

    // GLANCE: how much of the tab's right side an overlaid browser column covers (0 side by side or closed), so the
    // Hyperviz view and the floating orb keep clear of it.
    private var coverWidth: CGFloat {
        guard showsColumn, BrowserColumnLayout.overlays(space: Double(columnSpace)),
              let controller = delegate as? BaseTerminalController else { return 0 }
        return CGFloat(BrowserColumnLayout.width(saved: controller.browserColumn.savedWidth, space: Double(columnSpace)))
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Glance Studio! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Glance Studio are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
