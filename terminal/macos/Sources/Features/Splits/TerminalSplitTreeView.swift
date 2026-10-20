import SwiftUI

/// A single operation within the split tree.
///
/// Rather than binding the split tree (which is immutable), any mutable operations are
/// exposed via this enum to the embedder to handle.
enum TerminalSplitOperation {
    case resize(Resize)
    case drop(Drop)
    /// GLANCE: the pane's close button.
    case close(Ghostty.SurfaceView)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        /// The surface being dragged.
        let payload: Ghostty.SurfaceView

        /// The surface it was dragged onto
        let destination: Ghostty.SurfaceView

        /// The zone it was dropped to determine how to split the destination.
        let zone: TerminalSplitDropZone
    }
}

struct TerminalSplitTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void

    // GLANCE: minimized panes, the tabs view and the zoom controls (PaneLayoutModel).
    @StateObject private var panes = PaneLayoutModel()

    var body: some View {
        let layout = panes.layout(for: tree)
        VStack(spacing: 0) {
            if let tabs = layout.tabs {
                PaneTabBar(panes: panes, tabs: tabs, active: layout.active, close: { action(.close($0)) })
            }
            if let node = layout.node {
                TerminalSplitSubtreeView(
                    node: node,
                    isRoot: layout.isZoomed ? node == tree.root : layout.isRoot,
                    panes: panes,
                    controls: layout.controls && layout.tabs == nil
                        ? PaneControls(canMinimize: layout.canMinimize, isZoomed: layout.isZoomed) : nil,
                    action: { operation in
                        // A split drawn without its minimized panes resizes the real one.
                        if case .resize(let resize) = operation, let origin = layout.origins[resize.node.structuralIdentity] {
                            action(.resize(.init(node: origin, ratio: resize.ratio)))
                        } else {
                            action(operation)
                        }
                    })
                // This is necessary because we can't rely on SwiftUI's implicit
                // structural identity to detect changes to this view. Due to
                // the tree structure of splits it could result in bad behaviors.
                // See: https://github.com/ghostty-org/ghostty/issues/7546
                .id(node.structuralIdentity)
            }
            if !layout.docked.isEmpty {
                PaneDock(panes: panes, docked: layout.docked)
            }
        }
        .onAppear { panes.sync(tree) }
        .onChange(of: tree.structuralIdentity) { _ in panes.sync(tree) }
        .onDisappear { panes.stop() }
    }
}

private struct TerminalSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<Ghostty.SurfaceView>.Node
    var isRoot: Bool = false
    let panes: PaneLayoutModel
    let controls: PaneControls?
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        switch node {
        case .leaf(let leafView):
            TerminalSplitLeaf(surfaceView: leafView, isSplit: !isRoot, panes: panes, controls: controls, action: action)

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    action(.resize(.init(node: node, ratio: $0)))
                }),
                dividerColor: ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    TerminalSplitSubtreeView(node: split.left, panes: panes, controls: controls, action: action)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, panes: panes, controls: controls, action: action)
                },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                }
            )
        }
    }
}

private struct TerminalSplitLeaf: View {
    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool
    let panes: PaneLayoutModel
    let controls: PaneControls?
    let action: (TerminalSplitOperation) -> Void

    @EnvironmentObject private var ghostty: Ghostty.App

    @State private var dropState: DropState = .idle
    @State private var isSelfDragging: Bool = false

    var body: some View {
        GeometryReader { geometry in
            Ghostty.InspectableSurface(
                surfaceView: surfaceView,
                isSplit: isSplit)
            .background {
                // If we're dragging ourself, we hide the entire drop zone. This makes
                // it so that a released drop animates back to its source properly
                // so it is a proper invalid drop zone.
                if !isSelfDragging {
                    Color.clear
                        .onDrop(of: [.ghosttySurfaceId], delegate: SplitDropDelegate(
                            dropState: $dropState,
                            viewSize: geometry.size,
                            destinationSurface: surfaceView,
                            action: action
                        ))
                }
            }
            .overlay {
                if !isSelfDragging, case .dropping(let zone) = dropState {
                    zone.overlay(in: geometry)
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { value in
                isSelfDragging = value == surfaceView.id
                if isSelfDragging {
                    dropState = .idle
                }
            }
            .overlay(alignment: .topTrailing) {
                if let controls {
                    PaneHoverOverlay(surfaceView: surfaceView, panes: panes, controls: controls, zoom: toggleZoom, close: { action(.close(surfaceView)) })
                        .padding(8)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal pane")
        }
    }

    private func toggleZoom() {
        guard let surface = surfaceView.surface else { return }
        ghostty.splitToggleZoom(surface: surface)
    }

    private enum DropState: Equatable {
        case idle
        case dropping(TerminalSplitDropZone)
    }

    private struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let viewSize: CGSize
        let destinationSurface: Ghostty.SurfaceView
        let action: (TerminalSplitOperation) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.ghosttySurfaceId])
        }

        func dropEntered(info: DropInfo) {
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            // For some reason dropUpdated is sent after performDrop is called
            // and we don't want to reset our drop zone to show it so we have
            // to guard on the state here.
            guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            dropState = .idle
        }

        func performDrop(info: DropInfo) -> Bool {
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)
            dropState = .idle

            // Load the dropped surface asynchronously using Transferable
            let providers = info.itemProviders(for: [.ghosttySurfaceId])
            guard let provider = providers.first else { return false }

            // Capture action before the async closure
            _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { [weak destinationSurface] result in
                switch result {
                case .success(let sourceSurface):
                    DispatchQueue.main.async {
                        // Don't allow dropping on self
                        guard let destinationSurface else { return }
                        guard sourceSurface !== destinationSurface else { return }
                        action(.drop(.init(payload: sourceSurface, destination: destinationSurface, zone: zone)))
                    }

                case .failure:
                    break
                }
            }

            return true
        }
    }
}

enum TerminalSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right

    /// Determines which drop zone the cursor is in based on proximity to edges.
    ///
    /// Divides the view into four triangular regions by drawing diagonals from
    /// corner to corner. The drop zone is determined by which edge the cursor
    /// is closest to, creating natural triangular hit regions for each side.
    static func calculate(at point: CGPoint, in size: CGSize) -> TerminalSplitDropZone {
        let relX = point.x / size.width
        let relY = point.y / size.height

        let distToLeft = relX
        let distToRight = 1 - relX
        let distToTop = relY
        let distToBottom = 1 - relY

        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    @ViewBuilder
    func overlay(in geometry: GeometryProxy) -> some View {
        let overlayColor = Color.accentColor.opacity(0.3)

        switch self {
        case .top:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
                Spacer()
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
                Spacer()
            }
        case .right:
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
            }
        }
    }
}

/// The hover controls, shown while the pointer is on the pane (or on the controls). The pane's own `mouseOverSurface`
/// drives it so the terminal view's mouse handling is left alone.
private struct PaneHoverOverlay: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @ObservedObject var panes: PaneLayoutModel
    let controls: PaneControls
    let zoom: () -> Void
    let close: () -> Void

    @State private var overBar = false

    var body: some View {
        PaneHoverBar(panes: panes, surfaceView: surfaceView, controls: controls, zoom: zoom, close: close)
            .onHover { overBar = $0 }
            .opacity(surfaceView.mouseOverSurface || overBar ? 1 : 0)
            .allowsHitTesting(surfaceView.mouseOverSurface || overBar)
            .animation(.easeOut(duration: 0.12), value: surfaceView.mouseOverSurface || overBar)
    }
}
