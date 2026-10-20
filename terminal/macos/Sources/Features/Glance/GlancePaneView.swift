import AppKit
import SwiftUI

/// The Glance side pane: Liquid Glass (a blur before macOS 26) around a slot for Glance's web panel. There is one web
/// panel for the whole app; the host moves it into the key window's pane. As the floating card it has round corners,
/// and while the card is closed (`interactive` off) clicks go through it to the terminal.
struct GlancePaneView: NSViewRepresentable {
    var cornerRadius: CGFloat = 0
    var interactive = true
    /// The floating card (the panel drops its header there), not the side bar.
    var floating = false
    /// The floating card: the pointer came onto it or left it, and a click on it.
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> GlancePaneContainer {
        let slot = GlancePaneSlot()
        slot.floating = floating
        let effect: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = slot
            effect = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .sidebar
            blur.blendingMode = .behindWindow
            blur.state = .followsWindowActiveState
            slot.frame = blur.bounds
            slot.autoresizingMask = [.width, .height]
            blur.addSubview(slot)
            effect = blur
        }
        if floating {
            let card = GlanceCardContainer(cornerRadius: cornerRadius, content: effect, open: interactive)
            GlanceLayoutModel.shared.addCard(card)
            return card
        }
        let container = GlancePaneContainer()
        effect.frame = container.bounds
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)
        if cornerRadius > 0 {
            container.wantsLayer = true
            container.layer?.cornerRadius = cornerRadius
            container.layer?.cornerCurve = .continuous
            container.layer?.masksToBounds = true
        }
        return container
    }

    func updateNSView(_ nsView: GlancePaneContainer, context: Context) {
        nsView.interactive = interactive
        nsView.onHover = onHover
        nsView.onClick = onClick
        (nsView as? GlanceCardContainer)?.present(interactive)
    }
}

/// Holds the pane; lets clicks through while the floating card is closed. Reports the pointer coming and going, and
/// clicks (the web page underneath takes the events themselves), while someone listens.
class GlancePaneContainer: NSView {
    var interactive = true
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)? {
        didSet { if (onClick == nil) != (oldValue == nil) { watchClicks() } }
    }
    private var hoverArea: NSTrackingArea?
    nonisolated(unsafe) private var clickMonitor: Any?

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    /// The pointer is on this pane now (whatever the tracking area last said): it's in a visible window and the pointer
    /// is inside its frame on screen.
    var hasPointer: Bool {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
        return window.convertToScreen(convert(bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { if interactive { onHover?(true) } }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watchClicks()
    }

    /// A local monitor (only while in a window and someone listens): a mouse down inside the open card.
    private func watchClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard window != nil, onClick != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.interactive, event.window === self.window,
               self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                self.onClick?()
            }
            return event
        }
    }
}

/// Where the web panel sits. Tells the host when it joins or leaves a window.
final class GlancePaneSlot: NSView {
    /// In the floating card: the panel shows its floating chrome here.
    var floating = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated { GlanceTerminalHost.shared.slotsChanged() }
    }
}

// MARK: - The floating card

/// The floating card's frame: a warm two-part shadow, the solid ground under its glass, a hairline edge lit along the
/// top (the system's rim), and its entrance. It grows out of the orb: from 90% at its bottom right corner, 10 pt low,
/// on a soft spring with the fade quicker than the move, and goes back toward the orb faster than it came (MASTER.md
/// §6). Under Reduce Motion it only fades. It stays in the window while closed (invisible) so replies still render.
final class GlanceCardContainer: GlancePaneContainer {
    private let cornerRadius: CGFloat
    private let depth = CardShadowView()
    private let clip = NSView()
    private let edge = CardEdgeView()
    private var presented: Bool

    init(cornerRadius: CGFloat, content: NSView, open: Bool) {
        self.cornerRadius = cornerRadius
        presented = open
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        wantsLayer = true
        layer?.masksToBounds = false
        clip.wantsLayer = true
        clip.layer?.cornerRadius = cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        content.frame = clip.bounds
        content.autoresizingMask = [.width, .height]
        clip.addSubview(content)
        depth.cornerRadius = cornerRadius
        edge.cornerRadius = cornerRadius
        for view in [depth, clip, edge] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        layer?.opacity = open ? 1 : 0
        if !open { layer?.transform = transform(scale: Self.entryScale, drop: Self.entryDrop) }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let entryScale: CGFloat = 0.9
    private static let entryDrop: CGFloat = 10
    private static let exitScale: CGFloat = 0.96
    private static let exitDrop: CGFloat = 6

    /// Opens or closes the card, from wherever an interrupted animation left it.
    func present(_ open: Bool) {
        guard open != presented, let layer else { return }
        presented = open
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = layer.presentation()
        let fromOpacity = now?.opacity ?? layer.opacity
        // A card that was all but gone starts from the orb, not from where it faded out.
        let fromTransform = open && fromOpacity < 0.05
            ? transform(scale: Self.entryScale, drop: Self.entryDrop) : now?.transform ?? layer.transform
        let toTransform = open || reduceMotion
            ? CATransform3DIdentity : transform(scale: Self.exitScale, drop: Self.exitDrop)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = open ? 1 : 0
        layer.transform = toTransform

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = layer.opacity
        if open {
            fade.duration = reduceMotion ? 0.16 : 0.2
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)  // --ease-out
        } else {
            fade.duration = 0.16
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)  // --ease-in
        }
        layer.add(fade, forKey: "opacity")

        if !reduceMotion {
            let move: CABasicAnimation
            if open {
                // About 2% overshoot, the system's --spring.
                let spring = CASpringAnimation(keyPath: "transform")
                spring.mass = 1
                spring.stiffness = 320
                spring.damping = 27
                spring.duration = spring.settlingDuration
                move = spring
            } else {
                move = CABasicAnimation(keyPath: "transform")
                move.duration = 0.16
                move.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            }
            move.fromValue = fromTransform
            move.toValue = toTransform
            layer.add(move, forKey: "transform")
        } else {
            layer.removeAnimation(forKey: "transform")
        }
        CATransaction.commit()
    }

    /// Scales the card about its bottom right corner (the orb's side) and drops it: AppKit anchors a view's layer
    /// at its bottom left, and y points up.
    private func transform(scale: CGFloat, drop: CGFloat) -> CATransform3D {
        let anchor = layer?.anchorPoint ?? .zero
        let tx = (1 - scale) * (bounds.width - anchor.x * bounds.width)
        let ty = (1 - scale) * (0 - anchor.y * bounds.height) - drop
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(tx, ty, 0))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            clip.layer?.backgroundColor = Self.solid.cgColor
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        depth.dark = dark
        edge.dark = dark
    }

    /// The design system's `--solid`: warm, never the window's neutral grey.
    private static let solid = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x22 / 255, green: 0x1F / 255, blue: 0x1D / 255, alpha: 1)
            : NSColor(srgbRed: 0xFF / 255, green: 0xFA / 255, blue: 0xF6 / 255, alpha: 1)
    }
}

/// The card's depth (`--e3`): a wide, low ambient shadow and a tight contact one, warm in light mode.
private final class CardShadowView: NSView {
    var cornerRadius: CGFloat = 0
    var dark = true { didSet { style() } }
    private let contact = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(contact)
        style()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        layer?.shadowPath = path
        contact.frame = bounds
        contact.shadowPath = path
        CATransaction.commit()
    }

    private func style() {
        let color = dark ? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            : CGColor(red: 28 / 255, green: 26 / 255, blue: 23 / 255, alpha: 1)
        layer?.shadowColor = color
        layer?.shadowOpacity = dark ? 0.5 : 0.2
        layer?.shadowRadius = 20
        layer?.shadowOffset = CGSize(width: 0, height: -12)
        contact.shadowColor = color
        contact.shadowOpacity = dark ? 0.32 : 0.1
        contact.shadowRadius = 3
        contact.shadowOffset = CGSize(width: 0, height: -1)
    }
}

/// The card's edge: a hairline all round, and the rim, a brighter line along the top that fades out down the sides,
/// so the card reads as a lit sheet over the terminal rather than a grey box.
private final class CardEdgeView: NSView {
    var cornerRadius: CGFloat = 0
    var dark = true { didSet { style() } }
    private let hairline = CALayer()
    private let rim = CALayer()
    private let rimFade = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for line in [hairline, rim] {
            line.borderWidth = 1
            line.cornerCurve = .continuous
            layer?.addSublayer(line)
        }
        rimFade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)]
        // y points up: clear below 60% of the height, full at the top.
        rimFade.startPoint = CGPoint(x: 0.5, y: 0.6)
        rimFade.endPoint = CGPoint(x: 0.5, y: 1)
        rim.mask = rimFade
        style()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for line in [hairline, rim] {
            line.frame = bounds
            line.cornerRadius = cornerRadius
        }
        rimFade.frame = bounds
        CATransaction.commit()
    }

    private func style() {
        hairline.borderColor = dark ? CGColor(gray: 1, alpha: 0.08) : CGColor(red: 28 / 255, green: 26 / 255,
                                                                             blue: 23 / 255, alpha: 0.1)
        rim.borderColor = CGColor(gray: 1, alpha: dark ? 0.14 : 0.7)
    }
}
