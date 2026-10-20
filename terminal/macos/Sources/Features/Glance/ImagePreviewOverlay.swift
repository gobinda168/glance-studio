import AppKit

/// A picture shown in a popup over Studio's window: dimmed backdrop, the image at its own proportions, its name and
/// size underneath. Esc, Space, the close button or a click outside the picture dismiss it, and the keyboard goes back
/// to wherever it was (the terminal) afterwards.
@MainActor
final class ImagePreviewOverlay: NSView {
    private static let margin: CGFloat = 56
    private static let captionHeight: CGFloat = 40

    private let image: NSImage
    private let card = NSView()
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let close = NSButton()
    private weak var previousResponder: NSResponder?

    /// The overlay now showing, so a second click replaces it instead of stacking.
    private static weak var current: ImagePreviewOverlay?

    /// False when `path` isn't a picture AppKit can draw, or `window` has no content view to put it in.
    @discardableResult
    static func show(_ path: String, in window: NSWindow?) -> Bool {
        guard let window, let content = window.contentView, let image = NSImage(contentsOfFile: path) else { return false }
        current?.dismiss(animated: false)
        let overlay = ImagePreviewOverlay(image: image, path: path)
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.alphaValue = 0
        content.addSubview(overlay)
        overlay.previousResponder = window.firstResponder
        window.makeFirstResponder(overlay)
        current = overlay
        overlay.layoutCard()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            overlay.animator().alphaValue = 1
        }
        return true
    }

    private init(image: NSImage, path: String) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor

        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        addSubview(card)

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.setAccessibilityLabel((path as NSString).lastPathComponent)
        card.addSubview(imageView)

        let size = Self.pixelSize(of: image)
        caption.stringValue = "\((path as NSString).lastPathComponent)  ·  \(Int(size.width)) × \(Int(size.height))"
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .white.withAlphaComponent(0.6)
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        card.addSubview(caption)

        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close preview")
        close.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        close.contentTintColor = .white.withAlphaComponent(0.75)
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Close (Esc)"
        addSubview(close)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        layoutCard()
    }

    /// The card fits the picture inside the window's margins, never scaling a small picture past its own size.
    private func layoutCard() {
        let available = NSSize(width: max(bounds.width - Self.margin * 2, 120),
                               height: max(bounds.height - Self.margin * 2 - Self.captionHeight, 120))
        let size = Self.pixelSize(of: image)
        let scale = min(1, available.width / max(size.width, 1), available.height / max(size.height, 1))
        let fitted = NSSize(width: max((size.width * scale).rounded(), 160), height: max((size.height * scale).rounded(), 100))
        let cardSize = NSSize(width: fitted.width, height: fitted.height + Self.captionHeight)
        card.frame = NSRect(x: ((bounds.width - cardSize.width) / 2).rounded(),
                            y: ((bounds.height - cardSize.height) / 2).rounded(),
                            width: cardSize.width, height: cardSize.height)
        imageView.frame = NSRect(x: 0, y: Self.captionHeight, width: fitted.width, height: fitted.height)
        caption.frame = NSRect(x: 16, y: 11, width: cardSize.width - 32, height: 18)
        close.frame = NSRect(x: bounds.width - 52, y: bounds.height - 52, width: 28, height: 28)
    }

    private static func pixelSize(of image: NSImage) -> NSSize {
        if let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }), rep.pixelsWide > 0 {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    @objc private func closeClicked() { dismiss(animated: true) }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss(animated: true) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 49: dismiss(animated: true) // Esc, Space
        default: break
        }
    }

    override func cancelOperation(_ sender: Any?) { dismiss(animated: true) }

    private func dismiss(animated: Bool) {
        guard superview != nil else { return }
        if Self.current === self { Self.current = nil }
        if let window, window.firstResponder === self, let previous = previousResponder { window.makeFirstResponder(previous) }
        guard animated else { removeFromSuperview(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        })
    }
}
