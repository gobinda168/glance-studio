import AppKit
import Combine
import GlanceCore
import GlanceKit
import SwiftUI
import WebKit

/// How the Glance pane shows, shared by every window: the pin's mode (`PaneLayout.Mode`), whether the floating card is
/// open, and the orb's state. Each window works out its own placement from its width (`glancePlacement(_:)`).
@MainActor
final class GlanceLayoutModel: ObservableObject {
    static let shared = GlanceLayoutModel()

    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard

    @Published var mode: PaneLayout.Mode {
        didSet { Self.defaults.set(mode.rawValue, forKey: "terminalPaneLayout") }
    }

    /// A summary is open: the pane is the sidebar whatever the mode, until it closes (not saved).
    @Published var reading = false

    /// The sidebar's width, dragged on its left edge (320–720), saved and shared by every window.
    @Published var sidebarWidth: CGFloat {
        didSet { Self.defaults.set(Double(sidebarWidth), forKey: "glanceSidebarWidth") }
    }

    /// Floating: the panel's card is open above the orb.
    @Published var cardOpen = false {
        didSet {
            if cardOpen {
                // Opened by hand (the orb, ⌥Space): the card fits what's on it.
                if !telling { tellSize = .auto }
            } else {
                telling = false
                foldTimer?.invalidate()
                foldTimer = nil
            }
        }
    }

    /// The height the panel's content needs (`GlanceSession.onContentHeight`), and the size the `tell` on the card
    /// asked for: the floating card's height comes from both (`TellCard.height`).
    @Published var contentHeight: CGFloat = 0
    @Published private(set) var tellSize: TellCard.Size = .auto
    var cardHeight: CGFloat { TellCard.height(content: contentHeight, size: tellSize) }

    /// The panel's status ("Ready", "Reading aloud"), for the orb's tooltip when no session caption is set.
    private(set) var statusText = "Glance"

    /// Bumped when a window's Glance opens or closes, so the top bar's Glance button redraws.
    @Published private(set) var paneRevision = 0

    private var orbs: [Weak<GlanceOrbNSView>] = []
    private var orbMode = "idle"

    // A `tell` on the card: a short one folds back into the orb `TellCard.foldDelay` after it's been read, unless the
    // pointer is on the card; a click on it keeps it open.
    private var telling = false
    private var read = false
    private var keptOpen = false
    private var hovering = false
    private var foldTimer: Timer?
    /// The floating cards' panes, to ask whether the pointer is on one (the tracking areas miss a pointer that was
    /// already there when the card opened).
    private var cards: [Weak<GlancePaneContainer>] = []

    private init() {
        mode = PaneLayout.Mode(saved: Self.defaults.string(forKey: "terminalPaneLayout"))
        sidebarWidth = CGFloat(PaneLayout.sidebarWidth(Self.defaults.object(forKey: "glanceSidebarWidth") as? Double))
    }

    func paneOpenChanged() { paneRevision += 1 }

    // MARK: Telling

    /// A `tell` is about to show: the card takes its size. The host opens the card (or the side bar) right after.
    func beginTell(size: TellCard.Size) {
        foldTimer?.invalidate()
        foldTimer = nil
        telling = true
        read = false
        keptOpen = false
        hovering = pointerOnCard
        tellSize = size
    }

    func addCard(_ card: GlancePaneContainer) {
        cards.removeAll { $0.value == nil }
        cards.append(.init(card))
    }

    private var pointerOnCard: Bool { cards.contains { $0.value?.hasPointer == true } }

    /// Something else replaced the tell on the panel (a reply): the card fits it, and nothing folds.
    func endTell() {
        guard telling else { return }
        telling = false
        foldTimer?.invalidate()
        foldTimer = nil
        tellSize = .auto
    }

    /// The panel finished reading what's on it (or showed it without reading): a short tell's fold timer starts.
    func replyRead() {
        guard telling else { return }
        read = true
        armFold()
    }

    func cardHover(_ inside: Bool) {
        hovering = inside
        if inside {
            foldTimer?.invalidate()
            foldTimer = nil
        } else {
            armFold()
        }
    }

    /// A click on the card: the user is using it, so it stays.
    func cardClicked() {
        guard telling else { return }
        keptOpen = true
        foldTimer?.invalidate()
        foldTimer = nil
    }

    /// The pointer arriving cancels the timer and leaving starts it again; when it fires, the pointer's real place
    /// decides (a pointer that never "entered" still keeps the card, and a missed exit can't keep it forever).
    private func armFold() {
        foldTimer?.invalidate()
        foldTimer = nil
        guard telling, read, !keptOpen, cardOpen else { return }
        let timer = Timer(timeInterval: TellCard.foldDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.foldTimer = nil
                guard self.telling, !self.keptOpen, TellCard.folds(height: self.cardHeight) else { return }
                self.hovering = self.pointerOnCard
                if self.hovering { self.armFold() } else { self.cardOpen = false }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        foldTimer = timer
    }

    // MARK: The orbs

    fileprivate func add(_ orb: GlanceOrbNSView) {
        orbs.removeAll { $0.value == nil }
        orbs.append(.init(orb))
        orb.setMode(orbMode)
    }

    /// The panel's status: `PanelStatus.mode` (idle, thinking, reading or speaking) for the orbs' look, and its
    /// header line for their tooltip.
    func setStatus(_ status: PanelStatus) {
        let text = status.header.prefix(1) + status.header.dropFirst().lowercased()
        statusText = "Glance · " + text.replacingOccurrences(of: "claude", with: "Claude")
        orbMode = status.mode
        orbs.compactMap(\.value).forEach { $0.setMode(status.mode) }
    }

    func level(_ value: Float) {
        // 30 times a second while speaking: only to orbs someone can see (not a background tab's, nor a covered one).
        orbs.compactMap(\.value).filter { $0.window?.occlusionState.contains(.visible) == true }.forEach { $0.level(value) }
    }

    func setCardOpenOnOrbs(_ open: Bool) {
        orbs.compactMap(\.value).forEach { $0.setOpen(open) }
    }
}

// MARK: - Placement

extension View {
    /// Works out where this window's Glance pane goes from the width of the view it's applied to (the window's whole
    /// content, tab sidebar included) and the pin's mode.
    func glancePlacement(_ placement: Binding<PaneLayout.Placement?>) -> some View {
        modifier(GlancePlacementReader(placement: placement))
    }
}

private struct GlancePlacementReader: ViewModifier {
    @Binding var placement: PaneLayout.Placement?
    @ObservedObject private var layout = GlanceLayoutModel.shared
    @ObservedObject private var tabSidebar = TabSidebarModel.shared
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width; update() }
                    .onChange(of: proxy.size.width) { _, newWidth in width = newWidth; update() }
            })
            .onChange(of: layout.mode) { _, _ in update() }
            .onChange(of: layout.reading) { _, _ in update() }
            .onChange(of: tabSidebar.isOpen) { _, _ in update() }
            .onChange(of: tabSidebar.width) { _, _ in update() }
    }

    private func update() {
        let shared = width - (tabSidebar.isOpen ? tabSidebar.width : 0)
        let next = PaneLayout.placement(mode: layout.mode, width: Double(shared), current: placement,
                                        reading: layout.reading)
        if next != placement { placement = next }
    }
}

// MARK: - Floating

/// The floating layout, over the bottom right of the terminal: the orb, always there, and the panel's card above it
/// while open. The card has no header (the panel's floating chrome: its buttons are a hover strip), and its height fits
/// what's on it, from a short card up to full height (`TellCard`). It stays in the window while it's closed
/// (invisible, and clicks go through it) so replies still render and are read aloud.
struct GlanceFloatView: View {
    @ObservedObject private var layout = GlanceLayoutModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let cornerRadius: CGFloat = 18
    static let cardWidth: CGFloat = 400
    /// Between the card's bottom edge and the orb's body.
    static let gap: CGFloat = 10

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            GlanceOrbView { layout.cardOpen.toggle() }
                .frame(width: GlanceOrbNSView.side, height: GlanceOrbNSView.side)
            GlancePaneView(cornerRadius: Self.cornerRadius, interactive: layout.cardOpen, floating: true,
                           onHover: { layout.cardHover($0) }, onClick: { layout.cardClicked() })
                .frame(width: Self.cardWidth)
                .frame(maxHeight: layout.cardHeight)
                // Its shadow, edge and entrance (out of the orb) are the card's own (`GlanceCardContainer`).
                .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: layout.cardHeight)
                .allowsHitTesting(layout.cardOpen)
                // Right edge on the orb body's, bottom edge `gap` above it.
                .padding(.trailing, DockGeometry.orbHalo)
                .padding(.bottom, GlanceOrbNSView.side - DockGeometry.orbHalo + Self.gap)
        }
        .padding(.top, 12)
        .padding(.trailing, 4)
        .padding(.bottom, 4)
        .onChange(of: layout.cardOpen) { _, open in GlanceLayoutModel.shared.setCardOpenOnOrbs(open) }
    }
}

/// The orb from the overlay's editor orb (Web/orb.html): thinking, reading and speaking like the panel's. It stays
/// while the card is open (its glow rests a little).
private struct GlanceOrbView: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> GlanceOrbNSView {
        let orb = GlanceOrbNSView()
        orb.onClick = onClick
        GlanceLayoutModel.shared.add(orb)
        orb.setOpen(GlanceLayoutModel.shared.cardOpen)
        return orb
    }

    func updateNSView(_ nsView: GlanceOrbNSView, context: Context) {
        nsView.onClick = onClick
    }
}

final class GlanceOrbNSView: NSView, WKNavigationDelegate {
    static let side = DockGeometry.orbDiameter + 2 * DockGeometry.orbHalo

    var onClick: (() -> Void)?
    private let web: WKWebView
    private var ready = false
    private var mode = "idle"
    /// The panel's own status; a due meeting shows over it (`OrbAttention`).
    private var panelMode = "idle"
    private var open = false

    init() {
        let frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        super.init(frame: frame)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.loadFileURL(Resources.web.appendingPathComponent("orb.html"), allowingReadAccessTo: Resources.web)
        addSubview(web)
        // A meeting nudge: the orb's meeting mode, and its frame (while it can be seen) to set the nudge's card beside.
        NotificationCenter.default.addObserver(forName: OrbAttention.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMode() }
        }
        OrbAttention.register(self) { [weak self] in self?.screenFrame }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Only the orb itself (and a little around it) takes clicks, not its glow; the page underneath only draws.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let reach = DockGeometry.orbDiameter / 2 + 6
        return hypot(local.x - bounds.midX, local.y - bounds.midY) <= reach ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    /// A click closes an open card; otherwise a pending prompt's cards or a snoozed meeting nudge come first, then
    /// it opens the card. (While a prompt waits, a click that only opened its cards could never close this one.)
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if open || !OrbAttention.orbClicked() { onClick?() }
    }

    func setMode(_ mode: String) {
        panelMode = mode
        applyMode()
    }

    /// The mode to show (the panel's, a meeting nudge, or the orb channel's), and the session's caption as the tooltip
    /// (the panel's status when there's none: the floating card has no header to show it).
    private func applyMode() {
        toolTip = OrbAttention.tooltip ?? GlanceLayoutModel.shared.statusText
        let mode = OrbAttention.mode(panelMode)
        guard mode != self.mode else { return }
        self.mode = mode
        call("glanceOrb.state('\(mode)')")
    }

    /// The orb's body on screen, while its window is showing it.
    private var screenFrame: NSRect? {
        guard let window, window.isVisible, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor
        else { return nil }
        return window.convertToScreen(convert(bounds, to: nil)).insetBy(dx: DockGeometry.orbHalo, dy: DockGeometry.orbHalo)
    }

    /// The card is open: the orb rests.
    func setOpen(_ open: Bool) {
        guard open != self.open else { return }
        self.open = open
        call("glanceOrb.open(\(open))")
    }

    func level(_ value: Float) {
        call("glanceOrb.level(\(String(format: "%.4f", value)))")
    }

    private func call(_ script: String) {
        guard ready else { return }
        web.evaluateJavaScript("void " + script, completionHandler: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            ready = true
            call("glanceOrb.state('\(mode)')")
            call("glanceOrb.open(\(open))")
        }
    }
}

/// The Glance pane as a sidebar: the shared width (dragged on its left edge, 320–720, saved) and the drag handle (spec
/// 2026-10-11-humanize-summaries-design.md, "A fixed right side for reading"). Every tab that hosts the pane uses it.
private struct GlanceSidebarModifier: ViewModifier {
    @ObservedObject private var layout = GlanceLayoutModel.shared
    @State private var start: CGFloat?
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(width: layout.sidebarWidth)
            .overlay(alignment: .leading) { grip }
    }

    private var grip: some View {
        Rectangle()
            .fill(hovering || start != nil ? Color(red: 0.91, green: 0.39, blue: 0.24) : .clear)
            .frame(width: 2)
            .frame(width: 9)
            .contentShape(Rectangle())
            .offset(x: -4)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let from = start ?? layout.sidebarWidth
                    start = from
                    layout.sidebarWidth = CGFloat(PaneLayout.sidebarWidth(Double(from - drag.translation.width)))
                }
                .onEnded { _ in start = nil })
            .overlay(alignment: .leading) {
                if start != nil {
                    Text("\(Int(layout.sidebarWidth)) px")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .fixedSize()
                        .offset(x: 14)
                        .allowsHitTesting(false)
                }
            }
            .help("Drag to resize")
    }
}

extension View {
    /// The Glance pane's sidebar width and its drag handle.
    func glanceSidebar() -> some View { modifier(GlanceSidebarModifier()) }
}
