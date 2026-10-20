import AppKit
import GlanceCore
import WebKit

/// Site icons for tiles, tab rows and suggestions, cached on disk (Browser/Favicons/<key>.png, 64 px) and in memory,
/// keyed by `BrowserURL.iconKey`; read again once a week.
@MainActor
final class Favicons: ObservableObject {
    static let shared = Favicons()

    /// Bumped when an icon arrives, so views showing one redraw.
    @Published private(set) var revision = 0
    private var images: [String: NSImage] = [:]
    private var fetching: Set<String> = []
    private let folder = BrowserData.folder.appendingPathComponent("Favicons", isDirectory: true)

    func image(key: String?) -> NSImage? {
        guard let key else { return nil }
        if let image = images[key] { return image }
        guard let image = NSImage(contentsOf: file(key)) else { return nil }
        images[key] = image
        return image
    }

    /// After a page loads: its largest declared icon, else /favicon.ico, unless this site's icon is under a week old.
    func read(from webView: WKWebView) {
        guard let url = webView.url, ["http", "https"].contains(url.scheme ?? ""),
              let key = BrowserURL.iconKey(url), !fetching.contains(key), !isFresh(key) else { return }
        fetching.insert(key)
        webView.evaluateJavaScript(Self.script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                let declared = (result as? String).flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
                self?.fetch(declared ?? URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL, key: key)
            }
        }
    }

    private static let script = """
        (() => {
          const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')];
          const size = l => Math.max(0, ...((l.sizes && l.sizes.value) || '0').split(' ').map(s => parseInt(s) || 0));
          links.sort((a, b) => size(b) - size(a));
          return links.length ? links[0].href : null;
        })()
        """

    private func fetch(_ url: URL?, key: String) {
        guard let url else { fetching.remove(key); return }
        Task {
            defer { fetching.remove(key) }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400,
                  let image = NSImage(data: data), image.isValid, let png = Self.png(image, side: 64) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: file(key), options: .atomic)
            images[key] = NSImage(data: png)
            revision &+= 1
        }
    }

    private func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".png") }

    private func isFresh(_ key: String) -> Bool {
        let modified = (try? FileManager.default.attributesOfItem(atPath: file(key).path))?[.modificationDate] as? Date
        return modified.map { Date().timeIntervalSince($0) < 7 * 24 * 3600 } ?? false
    }

    /// `image` drawn into a `side`×`side` PNG.
    private static func png(_ image: NSImage, side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
