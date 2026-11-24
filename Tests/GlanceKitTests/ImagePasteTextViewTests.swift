import AppKit
import Testing
@testable import GlanceKit

/// 1×1 PNG: all these tests need is image data on the pasteboard.
private let png = Data(base64Encoded:
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAEAQH/7yMK/gAAAABJRU5ErkJggg==")!

private func scratchPasteboard() -> NSPasteboard {
  let pasteboard = NSPasteboard(name: .init("glance-test-\(UUID().uuidString)"))
  pasteboard.clearContents()
  return pasteboard
}

/// A screenshot on the clipboard is image data and nothing else, the case a plain-text view disables Paste for.
@MainActor @Test func pasteIsEnabledInARealMenuForAnImageOnlyClipboard() {
  _ = NSApplication.shared  // a menu validates nothing until the app object exists, and every item stays off
  let pasteboard = scratchPasteboard()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setData(png, forType: .png)
  let view = ImagePasteTextView()
  view.isRichText = false
  view.imagePasteboard = pasteboard
  let menu = NSMenu()
  let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
  item.target = view
  menu.addItem(item)

  menu.update()

  #expect(item.isEnabled)
}

@MainActor @Test func pastingAnImageOnlyClipboardAttachesAFile() throws {
  let pasteboard = scratchPasteboard()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setData(png, forType: .png)
  let view = ImagePasteTextView()
  view.imagePasteboard = pasteboard
  var attached: [URL] = []
  view.attachImages = { attached = $0 }

  view.paste(nil)

  let file = try #require(attached.first)
  defer { try? FileManager.default.removeItem(at: file) }
  #expect(FileManager.default.contents(atPath: file.path) == png)
  #expect(view.string.isEmpty)
}

@Test func anImageWithRealTextIsNotTreatedAsAnImage() {
  let pasteboard = scratchPasteboard()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setData(png, forType: .png)
  pasteboard.setString("two words", forType: .string)

  #expect(!ImageIntake.hasImage(pasteboard))
}
