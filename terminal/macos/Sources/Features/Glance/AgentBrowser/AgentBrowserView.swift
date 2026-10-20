import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Glance browser panel's content: the top strip (page, status, Pages, Take over, Screenshot, Stop) over the live page.
struct AgentBrowserView: View {
    @ObservedObject var model: AgentBrowserModel
    @ObservedObject var broker: AgentBrowserBroker
    var close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            strip
            Divider().opacity(0.5)
            ZStack {
                GlanceColor.ground
                if model.frame != nil {
                    PageFrameView(model: model)
                } else {
                    placeholder
                }
                if let toast = model.toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(GlanceFont.sans(12, .medium))
                            .foregroundStyle(GlassChrome.ink)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .glassSurface(Capsule())
                            .padding(.bottom, 14)
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                if model.takingOver {
                    Rectangle().strokeBorder(GlassChrome.lit(.topLeading, .bottomTrailing), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(GlassChrome.fade, value: model.toast)
        .frame(minWidth: 320, minHeight: 220)
    }

    // MARK: Top strip

    private var strip: some View {
        HStack(spacing: 8) {
            stripButton("xmark", "Hide (the browser keeps going; View → Show Glance Browser brings it back)", action: close)
            status
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(GlanceFont.sans(12, .semibold)).foregroundStyle(GlassChrome.ink).lineLimit(1)
                if let host = host {
                    Text(host).font(GlanceFont.mono(10.5)).foregroundStyle(GlassChrome.ink2).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            pagesMenu
            stripButton(model.takingOver ? "hand.raised.fill" : "hand.raised",
                        model.takingOver ? "Give control back to Claude" : "Take over: your mouse and keys go to the page",
                        lit: model.takingOver) { model.takingOver.toggle() }
                .disabled(model.followed == nil)
            stripButton("camera", "Screenshot to the Desktop and the clipboard") { model.screenshot() }
                .disabled(model.followed == nil)
            stopButton
            moreMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(WindowDragArea())
    }

    private var title: String {
        if let page = model.followed { return page.title.isEmpty ? (page.url.isEmpty ? "New page" : page.url) : page.title }
        return "Glance browser"
    }

    private var host: String? {
        guard let page = model.followed else { return nil }
        let host = URL(string: page.url)?.host ?? (page.url.hasPrefix("data:") ? "data: page" : page.url)
        return page.kind == .test ? "\(host) · test, Playwright \(page.version)" : host
    }

    private var status: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let (color, help) = statusLook(at: context.date)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(working(at: context.date) ? 0.8 : 0), radius: 4)
                .help(help)
                .accessibilityLabel(help)
        }
    }

    private func working(at date: Date) -> Bool {
        guard let last = model.lastFrameAt else { return false }
        return date.timeIntervalSince(last) < 3
    }

    private func statusLook(at date: Date) -> (Color, String) {
        switch broker.state {
        case .stopped: return (GlanceColor.critical, "Stopped")
        case .failed(let message): return (GlanceColor.critical, message)
        case .installing(let what): return (GlanceColor.amber, "Installing \(what)…")
        case .starting: return (GlanceColor.amber, "Starting…")
        default: return working(at: date) ? (GlanceColor.coral, "Working") : (Color.secondary.opacity(0.5), "Idle")
        }
    }

    private var pagesMenu: some View {
        Menu {
            let groups = Dictionary(grouping: model.pages) { $0.kind == .claude ? "Claude" : "Tests · Playwright \($0.version)" }
            ForEach(groups.keys.sorted { $0 == "Claude" ? true : $1 == "Claude" ? false : $0 < $1 }, id: \.self) { group in
                Section(group) {
                    ForEach(groups[group] ?? []) { page in
                        Button {
                            model.follow(page.id, pin: true)
                        } label: {
                            if page.id == model.followedId {
                                Label(page.title.isEmpty ? page.url : page.title, systemImage: "checkmark")
                            } else {
                                Text(page.title.isEmpty ? page.url : page.title)
                            }
                        }
                    }
                }
            }
            if model.pages.isEmpty { Text("No pages yet") }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "square.on.square")
                Text("\(model.pages.count)").font(GlanceFont.mono(11))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(GlassChrome.ink2)
        .help("Pages")
    }

    private var stopButton: some View {
        Group {
            if broker.state == .stopped {
                stripButton("play.fill", "Let Claude use the browser again") { broker.resume() }
            } else {
                stripButton("stop.fill", "Stop: close the pages; Claude's next step fails until you continue", tint: GlanceColor.criticalInk) {
                    broker.stop()
                }
                .disabled(broker.browsers.isEmpty)
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Picker("Page size", selection: $model.viewport) {
                Text("Fit to the window").tag(AgentBrowserModel.Viewport.fit)
                ForEach(AgentBrowserModel.Viewport.presets, id: \.0) { preset in
                    Text(preset.0).tag(preset.1)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Text("Test pages keep the size their test sets")
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(GlassChrome.ink2)
        .help("Page size")
    }

    private func stripButton(_ symbol: String, _ help: String, lit: Bool = false, tint: Color? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .foregroundStyle(lit ? GlanceColor.coralInk : (tint ?? GlassChrome.ink2))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(lit ? GlanceColor.coral.opacity(0.16) : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Empty states

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 10) {
            switch broker.state {
            case .installing(let what):
                ProgressView().controlSize(.small)
                message("Installing \(what)…", "The first time only")
            case .starting:
                ProgressView().controlSize(.small)
                message("Starting…", nil)
            case .failed(let text):
                message(text, nil)
                Button("Restart") { broker.restart() }.controlSize(.small)
            case .stopped:
                message("Stopped", "Claude can't use the browser until you continue")
                Button("Continue") { broker.resume() }.controlSize(.small)
            default:
                Image(systemName: "safari").font(.system(size: 26, weight: .light)).foregroundStyle(GlassChrome.ink2)
                message("No pages yet", "Pages Claude opens and Playwright tests run in Studio show up here")
            }
        }
        .padding(24)
    }

    private func message(_ title: String, _ detail: String?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(GlanceFont.sans(13, .medium)).foregroundStyle(GlassChrome.ink).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(GlanceFont.sans(11.5)).foregroundStyle(GlassChrome.ink2).multilineTextAlignment(.center)
            }
        }
    }
}

/// The strip's background moves the window.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The live page: frames drawn aspect-fit; while taking over, mouse, scroll and keys go to the page.
private struct PageFrameView: NSViewRepresentable {
    @ObservedObject var model: AgentBrowserModel

    func makeNSView(context: Context) -> FrameView {
        let view = FrameView()
        view.model = model
        return view
    }

    func updateNSView(_ view: FrameView, context: Context) {
        view.image = model.frame
        view.pageSize = model.pageSize
        view.takingOver = model.takingOver
    }
}

final class FrameView: NSView {
    weak var model: AgentBrowserModel?
    var image: CGImage? { didSet { layer?.contents = image } }
    var pageSize: CGSize = .zero
    var takingOver = false {
        didSet {
            guard takingOver != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if takingOver { window?.makeKey(); window?.makeFirstResponder(self) }
        }
    }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { takingOver }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { takingOver }

    override func layout() {
        super.layout()
        model?.viewResized(bounds.size, scale: window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        model?.viewResized(bounds.size, scale: window?.backingScaleFactor ?? 2)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Mouse

    private func pagePoint(_ event: NSEvent) -> CGPoint? {
        let shown = AgentBrowserFit.aspectFit(frame: pageSize, in: bounds)
        return AgentBrowserFit.pagePoint(convert(event.locationInWindow, from: nil), shown: shown, page: pageSize)
    }

    private func send(_ type: String, _ event: NSEvent, button: String) {
        guard takingOver, let point = pagePoint(event) else { return }
        model?.mouse(type, at: point, button: button, clicks: type == "mouseMoved" ? 0 : event.clickCount,
                     modifiers: Self.modifiers(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        guard takingOver else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        send("mousePressed", event, button: "left")
    }
    override func mouseUp(with event: NSEvent) { send("mouseReleased", event, button: "left") }
    override func mouseDragged(with event: NSEvent) { send("mouseMoved", event, button: "left") }
    override func mouseMoved(with event: NSEvent) { send("mouseMoved", event, button: "none") }
    override func rightMouseDown(with event: NSEvent) { send("mousePressed", event, button: "right") }
    override func rightMouseUp(with event: NSEvent) { send("mouseReleased", event, button: "right") }

    override func scrollWheel(with event: NSEvent) {
        guard takingOver, let point = pagePoint(event) else { return super.scrollWheel(with: event) }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        model?.wheel(at: point, dx: event.scrollingDeltaX * factor, dy: event.scrollingDeltaY * factor)
    }

    // MARK: Keys

    /// CDP's modifier bits: Alt 1, Ctrl 2, Meta 4, Shift 8.
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.option) ? 1 : 0) | (flags.contains(.control) ? 2 : 0)
            | (flags.contains(.command) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
    }

    /// Keys with a name in the DOM (and their Windows key codes, which Chromium wants).
    private static let named: [UInt16: (String, Int)] = [
        36: ("Enter", 13), 76: ("Enter", 13), 48: ("Tab", 9), 51: ("Backspace", 8), 117: ("Delete", 46), 53: ("Escape", 27),
        123: ("ArrowLeft", 37), 124: ("ArrowRight", 39), 125: ("ArrowDown", 40), 126: ("ArrowUp", 38),
        115: ("Home", 36), 119: ("End", 35), 116: ("PageUp", 33), 121: ("PageDown", 34),
    ]

    override func keyDown(with event: NSEvent) {
        guard takingOver, let model else { return super.keyDown(with: event) }
        let modifiers = Self.modifiers(event.modifierFlags)
        if let (key, code) = Self.named[event.keyCode] {
            var down: [String: JSONValue] = ["type": "rawKeyDown", "key": .string(key), "code": .string(key),
                                             "windowsVirtualKeyCode": .number(Double(code)), "modifiers": .number(Double(modifiers))]
            model.key(.object(down))
            if key == "Enter" {
                down["type"] = "char"
                down["text"] = "\r"
                model.key(.object(down))
            }
            down["type"] = "keyUp"
            down.removeValue(forKey: "text")
            model.key(.object(down))
        } else if let text = event.characters, !text.isEmpty, !event.modifierFlags.contains(.control) {
            model.insertText(text)
        }
    }

    /// ⌘ keys stay in the page while taking over (⌘W mustn't close a Studio tab): paste, select all, undo.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard takingOver, window?.firstResponder === self, let model,
              event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v":
            if let text = NSPasteboard.general.string(forType: .string) { model.insertText(text) }
        case "a":
            model.key(["type": "rawKeyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65, "modifiers": 4,
                       "commands": ["selectAll"]])
            model.key(["type": "keyUp", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65, "modifiers": 4])
        case "z":
            let redo = event.modifierFlags.contains(.shift)
            model.key(["type": "rawKeyDown", "key": "z", "code": "KeyZ", "windowsVirtualKeyCode": 90,
                       "modifiers": .number(Double(redo ? 12 : 4)), "commands": .array([.string(redo ? "redo" : "undo")])])
            model.key(["type": "keyUp", "key": "z", "code": "KeyZ", "windowsVirtualKeyCode": 90, "modifiers": 4])
        case "q":
            return super.performKeyEquivalent(with: event)
        default:
            break
        }
        return true
    }
}
