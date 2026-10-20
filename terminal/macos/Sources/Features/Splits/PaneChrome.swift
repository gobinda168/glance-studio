import SwiftUI

/// GLANCE: the chrome around split panes (see `PaneLayoutModel`): the status dot, the dock of minimized strips, the
/// tab bar of the tabs view and the little controls that appear over a pane the pointer is on.

/// A pane's state as a dot: running pulses, done is green, failed is red. `loud` rings it for a minimized pane whose
/// command just ended.
private struct PaneDot: View {
    let state: PaneLayoutModel.State
    var loud = false

    @State private var pulse = false

    private var color: Color {
        switch state {
        case .running: StudioColors.coral
        case .done: StudioColors.ok
        case .failed: StudioColors.danger
        case .idle: StudioColors.muted.opacity(0.55)
        }
    }

    var body: some View {
        ZStack {
            if loud {
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 0.9)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .opacity(state == .running && pulse ? 0.45 : 1)
        }
        .frame(width: 16, height: 16)
        .onAppear { startPulse() }
        .onChange(of: state) { _ in startPulse() }
        .onChange(of: loud) { _ in startPulse() }
    }

    private func startPulse() {
        pulse = false
        guard state == .running || loud else { return }
        withAnimation(.easeInOut(duration: loud ? 1.1 : 0.9).repeatForever(autoreverses: !loud)) { pulse = true }
    }
}

/// What a pane's command is doing, in words: "failed", "done", or the program's own progress.
private func stateLabel(_ status: PaneLayoutModel.Status) -> String? {
    if let percent = status.percent { return "\(percent)%" }
    switch status.state {
    case .failed: return "failed"
    case .done: return "done"
    case .running, .idle: return nil
    }
}

/// A minimized pane: its folder, the command, the latest output line and its state, in one slim row. Click to bring
/// the pane back. A command that ended while it was minimized tints the row until then; nothing takes focus.
struct PaneStrip: View {
    let view: Ghostty.SurfaceView
    let status: PaneLayoutModel.Status
    let loud: Bool
    let restore: () -> Void

    @State private var hovering = false

    private var tint: Color? {
        guard loud else { return nil }
        return status.state == .failed ? StudioColors.dangerFill : StudioColors.okFill
    }

    var body: some View {
        Button(action: restore) {
            HStack(spacing: 8) {
                PaneDot(state: status.state, loud: loud)
                Text(status.folder.isEmpty ? "Terminal" : status.folder)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                    .fixedSize()
                if !status.command.isEmpty {
                    Text(status.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                }
                Text(status.line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StudioColors.body.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let label = stateLabel(status) {
                    Text(label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(status.state == .failed ? StudioColors.danger
                            : status.state == .done ? StudioColors.ok : StudioColors.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(StudioColors.field))
                }
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                ZStack {
                    StudioColors.bar
                    if let tint { tint }
                    if hovering { StudioColors.hover }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Restore this pane" + (status.folder.isEmpty ? "" : " (\(status.folder))"))
        .accessibilityLabel("Minimized pane \(status.folder), \(status.command)")
        .accessibilityHint("Restores the pane")
    }
}

/// The minimized panes, stacked under the panes they left.
struct PaneDock: View {
    @ObservedObject var panes: PaneLayoutModel
    let docked: [Ghostty.SurfaceView]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(docked) { view in
                PaneStrip(view: view, status: panes.status(for: view.id), loud: panes.attention.contains(view.id)) {
                    panes.restore(view)
                }
                .overlay(alignment: .top) { Rectangle().fill(StudioColors.line).frame(height: 1) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// The tabs view's bar: one chip per pane with its state, folder and command; the trailing button goes back to the
/// split view.
/// Where each tab sits in the bar, as laid out (before a drag's offset), in the bar's own coordinate space.
private struct PaneTabFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A tab held by the pointer: which one, where in the tab it was grabbed, and where the pointer is.
private struct PaneTabDrag {
    let id: UUID
    let grab: CGFloat
    var x: CGFloat
}

/// The tabs view's bar. A tab drags like a macOS tab: it lifts under the pointer and follows it sideways, the others
/// slide aside as it passes their middles, and on release it settles into its place.
struct PaneTabBar: View {
    @ObservedObject var panes: PaneLayoutModel
    let tabs: [Ghostty.SurfaceView]
    let active: UUID?
    let close: (Ghostty.SurfaceView) -> Void

    private static let space = "paneTabs"
    private static let spacing: CGFloat = 4

    @State private var frames: [UUID: CGRect] = [:]
    @State private var drag: PaneTabDrag?
    /// A drag's mouse-up isn't a click on the tab.
    @State private var suppressSelect = false

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.spacing) {
                    ForEach(tabs) { view in
                        tab(view)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(PaneTabFrames.self) { frames = $0 }
            }
            PaneIconButton(symbol: "rectangle.split.2x1", help: "Back to split view") { panes.toggleTabs() }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(StudioColors.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line).frame(height: 1) }
    }

    private func tab(_ view: Ghostty.SurfaceView) -> some View {
        let lifted = drag?.id == view.id
        return PaneTab(panes: panes, view: view, selected: view.id == active,
                       select: { if !suppressSelect { panes.select(view) } }, close: { close(view) })
            .offset(x: lifted ? liftedOffset : 0)
            .scaleEffect(lifted ? 1.04 : 1)
            .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: lifted ? 9 : 0, y: lifted ? 3 : 0)
            .zIndex(lifted ? 1 : 0)
            // After the offset, so it reports where the tab is laid out, not where it is held.
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PaneTabFrames.self,
                                       value: [view.id: proxy.frame(in: .named(Self.space))])
            })
            .gesture(dragGesture(view))
    }

    /// How far the held tab is drawn from its slot, so it stays under the pointer while the slots change.
    private var liftedOffset: CGFloat {
        guard let drag, let frame = frames[drag.id] else { return 0 }
        return drag.x - drag.grab - frame.minX
    }

    private func dragGesture(_ view: Ghostty.SurfaceView) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    guard let frame = frames[view.id] else { return }
                    suppressSelect = true
                    NSCursor.closedHand.push()
                    panes.select(view)
                    withAnimation(PaneLayoutModel.animation) {
                        drag = PaneTabDrag(id: view.id, grab: value.startLocation.x - frame.minX, x: value.location.x)
                    }
                }
                drag?.x = value.location.x
                reorder()
            }
            .onEnded { _ in
                guard drag != nil else { return }
                NSCursor.pop()
                withAnimation(PaneLayoutModel.animation) { drag = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { suppressSelect = false }
            }
    }

    /// Moves the held tab to the slot nearest it: the slots are laid out from the other tabs' widths, and the one whose
    /// leading edge is closest to the held tab's wins. It depends only on where the pointer is, so a quick flick or a
    /// pause before letting go still lands the tab where it's held, across as many tabs as it passed (one throttled swap
    /// per mouse move left it short of the ends).
    private func reorder() {
        // The model's order, not `tabs`: that one is a redraw behind right after a move.
        let order = panes.tabOrder.filter { frames[$0] != nil }
        guard let drag, let index = order.firstIndex(of: drag.id), let start = order.compactMap({ frames[$0]?.minX }).min()
        else { return }
        let leading = drag.x - drag.grab
        var slot = start, best = 0, distance = abs(leading - start)
        for (offset, id) in order.filter({ $0 != drag.id }).enumerated() {
            slot += (frames[id]?.width ?? 0) + Self.spacing
            if abs(leading - slot) < distance { (best, distance) = (offset + 1, abs(leading - slot)) }
        }
        guard best != index else { return }
        panes.moveTab(drag.id, to: order[best])
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
}

/// A tab's name while it is being edited: Return keeps it, Esc cancels, clicking away keeps it. An empty name goes
/// back to the folder's.
private struct PaneRenameField: View {
    let commit: (String?) -> Void

    @State private var text: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(initial: String, commit: @escaping (String?) -> Void) {
        _text = State(initialValue: initial)
        self.commit = commit
    }

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(StudioColors.ink)
            .focused($focused)
            .frame(width: min(180, max(70, CGFloat(text.count) * 7.5 + 14)))
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            .onChange(of: focused) { isFocused in if !isFocused { finish(text) } }
            .onAppear { focused = true }
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        commit(value)
    }
}

private struct PaneTab: View {
    @ObservedObject var panes: PaneLayoutModel
    let view: Ghostty.SurfaceView
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false

    private var status: PaneLayoutModel.Status { panes.status(for: view.id) }
    private var editing: Bool { panes.renaming == view.id }

    var body: some View {
        HStack(spacing: 0) {
            // A tap, not a Button: a Button keeps the mouse, so the bar's drag to reorder never starts (the side bar's rows
            // work the same way).
            HStack(spacing: 6) {
                PaneDot(state: status.state)
                if editing {
                    PaneRenameField(initial: panes.names[view.id] ?? status.folder) {
                        panes.finishRename(view, name: $0)
                    }
                } else {
                    Text(status.folder.isEmpty ? "Terminal" : status.folder)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selected ? StudioColors.ink : StudioColors.body)
                        .lineLimit(1)
                }
                if !status.command.isEmpty {
                    Text(status.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                if let label = stateLabel(status) {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StudioColors.muted)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, selected || hovering ? 4 : 9)
            .frame(height: 26)
            .contentShape(Rectangle())
            .onTapGesture { if !editing { select() } }
            .simultaneousGesture(TapGesture(count: 2).onEnded { panes.renaming = view.id })
            .accessibilityElement(children: editing ? .contain : .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, select)
            // Close shows on the open tab and on the one under the pointer.
            if selected || hovering {
                PaneIconButton(symbol: "xmark", help: "Close this pane", destructive: true, action: close)
                    .scaleEffect(0.85)
                    .padding(.trailing, 2)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? StudioColors.solid : hovering ? StudioColors.hover : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? StudioColors.line3 : .clear, lineWidth: 1))
        .onHover { hovering = $0 }
        .help("Double-click to rename, drag to reorder")
        .contextMenu {
            Button("Rename") { panes.renaming = view.id }
            if panes.names[view.id] != nil {
                Button("Reset Name") { panes.finishRenameNow(view, name: "") }
            }
            Divider()
            Button("Move Left") { panes.nudgeTab(view.id, by: -1) }.disabled(!panes.canNudge(view.id, by: -1))
            Button("Move Right") { panes.nudgeTab(view.id, by: 1) }.disabled(!panes.canNudge(view.id, by: 1))
            Divider()
            Button("Close Pane", role: .destructive, action: close)
        }
    }
}

struct PaneIconButton: View {
    let symbol: String
    let help: String
    var destructive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? (destructive ? StudioColors.danger : StudioColors.ink) : StudioColors.muted)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? (destructive ? StudioColors.dangerFill : StudioColors.hover) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The controls over a pane's top right corner while the pointer is on it: minimize, zoom (fill the window; again to
/// go back), the tabs view and close (the pane asks first when a command is still running).
struct PaneHoverBar: View {
    @ObservedObject var panes: PaneLayoutModel
    let surfaceView: Ghostty.SurfaceView
    let controls: PaneControls
    let zoom: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            if controls.canMinimize {
                PaneIconButton(symbol: "minus", help: "Minimize this pane") { panes.minimize(surfaceView) }
            }
            if controls.canMinimize || controls.isZoomed {
                PaneIconButton(symbol: controls.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: controls.isZoomed ? "Back to all panes" : "Zoom this pane", action: zoom)
            }
            if !controls.isZoomed {
                PaneIconButton(symbol: "rectangle.stack", help: "Show panes as tabs") { panes.toggleTabs() }
            }
            Rectangle().fill(StudioColors.line).frame(width: 1, height: 14).padding(.horizontal, 2)
            PaneIconButton(symbol: "xmark", help: "Close this pane", destructive: true, action: close)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }
}

/// What the hover controls offer for the pane they're on.
struct PaneControls: Equatable {
    var canMinimize: Bool
    var isZoomed: Bool
}
