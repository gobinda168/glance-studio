import AppKit

/// A plain-text view that also takes pasted images, handing them over as files.
open class ImagePasteTextView: NSTextView {
  public var attachImages: (([URL]) -> Void)?
  public var imagePasteboard = NSPasteboard.general

  open override func paste(_ sender: Any?) {
    if let urls = ImageIntake.urls(from: imagePasteboard) { attachImages?(urls) } else { super.paste(sender) }
  }

  // A plain-text view disables Paste when the clipboard holds no text, so ⌘V would never reach paste(_:) for a screenshot.
  open override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(paste(_:)), ImageIntake.hasImage(imagePasteboard) { return true }
    return super.validateMenuItem(menuItem)
  }
}
