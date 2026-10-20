import AppKit
import Quartz

/// Shows a file over Studio's window, without switching apps: a pasted image's caption in a Claude session
/// (glance-replies posts `/preview`), or a reply's link to a picture, PDF or document. A picture opens in a popup
/// inside the window (`ImagePreviewOverlay`); PDFs, documents and media use Quick Look's panel.
@MainActor
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreview()

    private var items: [URL] = []

    /// False when the file is gone.
    @discardableResult
    func show(_ path: String) -> Bool {
        if Self.isPicture(path) {
            let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil }
            if ImagePreviewOverlay.show(path, in: window) {
                NSApp.activate()
                window?.makeKeyAndOrderFront(nil)
                return true
            }
        }
        guard FileManager.default.fileExists(atPath: path), let panel = QLPreviewPanel.shared() else { return false }
        items = [URL(fileURLWithPath: path)]
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        // The click came from Studio's terminal, so the panel opens over that window and Studio stays in front.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    private static func isPicture(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "icns", "svg"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { items[index] as NSURL }
    }
}
