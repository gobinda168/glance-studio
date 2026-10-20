import AppKit
import GlanceKit
import SwiftUI

/// The window chrome (the top bar and the tab sidebar) in the design system's language (design-system/glance/MASTER.md):
/// Liquid Glass, neutral at rest, and coral where something is selected or lit, the way MASTER §8 marks a selected tab.
/// Coral is also Claude's and Glance's (the thinking light, the Glance orb); plan usage is teal, as in the Glance pane.
/// A tab's kind shows in its glyph, not in a colour. Motion follows MASTER §6: springs for moves, short fades for
/// hovers, loops only while on screen, and a fade instead of either under Reduce Motion.
enum GlassChrome {
    // MARK: Colour (MASTER §3, shared with Home through GlanceKit's GlanceColor)

    static let coral = GlanceColor.coral
    static let coralHi = GlanceColor.coralHi
    static let coralLo = GlanceColor.coralLo
    static let teal = GlanceColor.teal          // Claude thinking, plan usage
    static let ok = GlanceColor.ok              // Claude finished
    static let amber = GlanceColor.amber        // the bell
    static let warn = GlanceColor.warn          // a meter from 70%
    static let critical = GlanceColor.critical  // a meter from 90%

    /// Coral, the limits and the diff counts as text and thin glyphs: deep enough for 4.5:1 on light glass, bright on
    /// dark.
    static let coralInk = GlanceColor.coralInk
    static let okInk = GlanceColor.okInk        // lines added
    static let warnInk = GlanceColor.warnInk
    static let criticalInk = GlanceColor.criticalInk

    /// Text on glass. The system's secondary label colour falls under 4.5:1 on light glass; these stay above it.
    static let ink = Color.primary.opacity(0.88)
    static let ink2 = Color.primary.opacity(0.64)

    /// The selection's light, coral into peach: the current tab's underline, a lit hairline.
    static func lit(_ start: UnitPoint = .leading, _ end: UnitPoint = .trailing) -> LinearGradient {
        LinearGradient(colors: [coral, coralHi], startPoint: start, endPoint: end)
    }

    // MARK: Motion

    /// Moves and arrivals: the `.smooth` spring; a short fade under Reduce Motion.
    static func move(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : .smooth(duration: 0.38)
    }

    /// Hovers, fades, and anything leaving (--t-fast).
    static let fade = Animation.easeOut(duration: 0.16)

    /// Press feedback (--t-instant, with a little give).
    static let press = Animation.spring(response: 0.2, dampingFraction: 0.62)
}

// MARK: - Glass

extension View {
    /// Liquid Glass in `shape` on macOS 26, a translucent material with a specular rim before it, and `solid` under
    /// Reduce Transparency. `tint` colours the glass (keep it faint); `interactive` lets it answer a press.
    func glassSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false,
                                         solid: Color = Color(nsColor: .windowBackgroundColor)) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, solid: solid))
    }

    /// A soft round light of `color` behind the view (an LED's halo, the orb's), `strength` 0...1.
    func glowHalo(_ color: Color, radius: CGFloat = 3, strength: Double = 1) -> some View {
        background {
            Circle()
                .fill(color)
                .blur(radius: radius)
                .opacity(0.2 + 0.55 * strength)
                .scaleEffect(1.15 + 0.35 * strength)
                .allowsHitTesting(false)
        }
    }
}

private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let solid: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(solid))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1).allowsHitTesting(false))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(tint ?? .clear))
                        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                }
                .overlay(SpecularRim(shape: shape))
        }
    }
}

/// Sibling glass that renders, and morphs, together: a GlassEffectContainer on macOS 26, the content alone before.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Glass's rim: a one-pixel edge lit from above. Without it glass reads as grey (MASTER §2).
struct SpecularRim<S: InsettableShape>: View {
    let shape: S
    var strength = 1.0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let top = (scheme == .dark ? 0.3 : 0.9) * strength
        shape
            .strokeBorder(LinearGradient(colors: [.white.opacity(top), .white.opacity(top * 0.12)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// Lit glass behind a button: Liquid Glass faintly tinted on macOS 26, a tinted material before it, a plain tint
/// under Reduce Transparency, each with a quiet rim. `light` (0...1) is how lit. Neutral unless `tint` says otherwise.
struct ChromePlate: View {
    var tint: Color
    var light = 1.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = Capsule(style: .continuous)
        let rim = shape
            .strokeBorder(tint.opacity(0.3), lineWidth: 0.75)
            .opacity(0.6 * light)
        if reduceTransparency {
            shape.fill(tint.opacity(0.14 * light)).overlay(rim)
        } else if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(tint.opacity(0.16 * light)), in: shape)
                .overlay(rim)
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(tint.opacity(0.14)))
                .overlay(SpecularRim(shape: shape, strength: 0.8))
                .overlay(rim)
                .opacity(0.4 + 0.6 * light)
        }
    }
}

// MARK: - Buttons

/// The chrome's buttons. At rest the glyph sits on nothing; under the pointer a capsule of neutral glass fades in
/// behind it, and a press squishes it. `isOn` keeps it lit, coral, with the glyph in `onInk` (a toggle that's on);
/// `resting` shows the glass at rest too (a labelled button); `inset` keeps the light inside a bigger hit target.
/// Reduce Motion keeps the fades and drops the squish.
struct ChromeButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var onInk: Color = GlassChrome.coralInk
    var isOn = false
    var resting = false
    var inset: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        ChromeButton(configuration: configuration, style: self)
    }
}

private struct ChromeButton: View {
    let configuration: ButtonStyleConfiguration
    let style: ChromeButtonStyle
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How lit the glass is; 0 is none.
    private var light: Double {
        guard isEnabled else { return style.resting ? 0.3 : 0 }
        if configuration.isPressed { return 1 }
        if hovering { return 0.85 }
        if style.isOn { return 0.6 }
        return style.resting ? 0.4 : 0
    }

    private var glyph: Color {
        if hovering { return .primary }
        if style.isOn { return style.onInk }
        return style.resting ? GlassChrome.ink : GlassChrome.ink2
    }

    var body: some View {
        configuration.label
            .foregroundStyle(glyph)
            .background {
                if light > 0 {
                    ChromePlate(tint: style.isOn && !hovering ? GlassChrome.coral : style.tint, light: light)
                        .padding(style.inset)
                        .transition(.opacity)
                }
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(GlassChrome.fade, value: light)
            .animation(reduceMotion ? nil : GlassChrome.press, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// A press squish and nothing else, for a button that draws its own surface. Under Reduce Motion a press dims instead.
struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressButton(configuration: configuration)
    }
}

private struct PressButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.75 : 1)
            .animation(reduceMotion ? nil : GlassChrome.press, value: configuration.isPressed)
    }
}

// MARK: - Lights

/// Fades `content` between `low` and 1 and back every `period` seconds: a slow breathing light. The loop is a Core
/// Animation on the content's own layer, so it runs in the render server and the app never redraws the view per frame
/// (a 30 fps timeline kept the main thread busy for every light). It holds still at the middle under Reduce Motion,
/// when not `running`, and while its window is off screen (a background tab, covered, minimised), so a light nobody can
/// see costs nothing. Give it a frame: it fills what it is offered.
struct Breathing<Content: View>: View {
    var period: Double
    var running = true
    var low = 0.4
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = true

    var body: some View {
        BreathingLayer(period: period, low: low, live: running && onScreen && !reduceMotion, content: content())
            .background(OnScreenReader { onScreen = $0 })
    }
}

private struct BreathingLayer<Content: View>: NSViewRepresentable {
    let period: Double
    let low: Double
    let live: Bool
    let content: Content

    func makeNSView(context: Context) -> Host<Content> {
        Host(rootView: content)
    }

    func updateNSView(_ host: Host<Content>, context: Context) {
        host.rootView = content
        host.set(period: period, low: low, live: live)
    }

    /// The hosting view that owns the animation. A layer loses its animations when the view leaves its window or its
    /// layer is rebuilt, so the loop is added again whenever the view lands in a window.
    final class Host<Root: View>: NSHostingView<Root> {
        private var period = 1.0
        private var low = 0.4
        private var live = false
        private static var key: String { "breathing" }

        override var isOpaque: Bool { false }

        func set(period: Double, low: Double, live: Bool) {
            guard period != self.period || low != self.low || live != self.live else { return }
            self.period = period
            self.low = low
            self.live = live
            apply()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            wantsLayer = true
            guard let layer else { return }
            layer.removeAnimation(forKey: Self.key)
            guard live, window != nil else {
                layer.opacity = Float((1 + low) / 2)
                return
            }
            layer.opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = low
            fade.duration = period / 2
            fade.autoreverses = true
            fade.repeatCount = .infinity
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: Self.key)
        }
    }
}

/// A status light: a small lit sphere with a highlight. Flat, with no halo: a badge marks a state, it doesn't glow.
struct LEDDot: View {
    var color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.mix(with: .white, by: 0.55), color],
                                 center: UnitPoint(x: 0.36, y: 0.32), startRadius: 0, endRadius: size * 0.7))
            .frame(width: size, height: size)
    }
}

/// A one-pixel separator that fades out at both ends, so it divides without cutting the glass in two. `lit` draws it in
/// coral instead of grey.
struct GradientHairline: View {
    var axis: Axis = .horizontal
    var lit = false

    var body: some View {
        let colors: [Color] = lit
            ? [.clear, GlassChrome.coral.opacity(0.55), GlassChrome.coralHi.opacity(0.4), .clear]
            : [.clear, Color.primary.opacity(0.16), .clear]
        let horizontal = axis == .horizontal
        Rectangle()
            .fill(LinearGradient(colors: colors, startPoint: horizontal ? .leading : .top,
                                 endPoint: horizontal ? .trailing : .bottom))
            .frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
            .accessibilityHidden(true)
    }
}

/// A tab kind's glyph: a mono prompt for a terminal, the tab's symbol otherwise. The shape tells the kind; the colour
/// stays neutral, brighter when `lit`.
struct TabKindGlyph: View {
    let kind: TabRow.Kind
    let symbol: String
    var size: CGFloat = 11
    var lit = false

    var body: some View {
        Group {
            switch kind {
            case .terminal:
                Text(">_")
                    .font(.system(size: size - 1, weight: .bold, design: .monospaced))
            case .home, .editor, .other, .chat:
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
            }
        }
        .foregroundStyle(lit ? GlassChrome.ink : GlassChrome.ink2)
        .accessibilityHidden(true)
    }
}

/// Reports whether the window the view is in is on screen: visible, and not wholly covered.
struct OnScreenReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = window.map { window in
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.report() } }
            }
            report()
        }

        /// Later, not while SwiftUI is still placing this view.
        private func report() {
            let visible = window?.occlusionState.contains(.visible) == true
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
