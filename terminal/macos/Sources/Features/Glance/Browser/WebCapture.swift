import AppKit
import GlanceCore
import WebKit

/// Records a plain Browser tab's console and network for `glance browser` and Claude Code (spec
/// 2026-10-12-web-logs-design.md). A script in every frame wraps `console`, `fetch` and XHR and posts what happens;
/// this class turns the posts into log lines (secrets masked first) in one file per tab, and WebPage's delegate adds
/// the page's own document request, which the script can't see. A tab's file goes when the tab closes.
@MainActor
final class WebCapture: NSObject, WKScriptMessageHandler {
    private var assembler = WebLogAssembler()
    private var writer: WebLogWriter?
    private var installed = false
    /// Entries that arrived before the tab was attached (the first page loads while the tab is being made).
    private var queued: [WebLogEntry] = []
    private(set) var tabKey: String?
    private(set) var fileName: String?
    /// When the tab last came to the front: 0 until it does.
    private(set) var focused: Double = 0

    /// Adds the script and the message handler to a configuration made for one page. Not for a window a site opened:
    /// it shares its opener's controller, which already has them (and a second handler of the same name throws).
    func install(on configuration: WKWebViewConfiguration) {
        guard BrowserData.capturesLogs else { return }
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: WebLogScript.source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
        controller.add(WeakScriptHandler(self), contentWorld: .page, name: WebLogScript.handlerName)
        installed = true
    }

    /// The tab has its key: the log file starts, with what was recorded so far.
    func attach(tabKey key: String) {
        guard installed, tabKey != key else { return }
        WebCaptureRegistry.prepare()
        tabKey = key
        let name = WebLogFiles.fileName(forTab: key)
        fileName = name
        writer = WebLogWriter(file: WebLogFiles.folder().appendingPathComponent(name))
        for entry in queued { writer?.append(entry) }
        queued = []
        WebCaptureRegistry.refresh()
    }

    /// The tab closed: its log goes with it.
    func detach() {
        writer?.remove()
        writer = nil
        tabKey = nil
        fileName = nil
        queued = []
    }

    func touch() { focused = Date().timeIntervalSince1970 }

    // MARK: From the page

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard installed, let body = message.body as? [String: Any] else { return }
            assembler.masksSecrets = BrowserData.masksLogSecrets
            record(assembler.receive(body))
        }
    }

    /// The page's own document answered.
    func document(_ response: HTTPURLResponse) {
        guard installed, let url = response.url?.absoluteString else { return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = "\(value)" }
        assembler.masksSecrets = BrowserData.masksLogSecrets
        record(assembler.document(url: url, status: response.statusCode, headers: headers,
                                  contentType: response.value(forHTTPHeaderField: "Content-Type")))
    }

    /// The page's document never arrived: connection refused, offline, a certificate.
    func documentFailed(_ error: Error, url: URL?) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code) { return }
        guard installed else { return }
        let address = ((error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url)?.absoluteString
        assembler.masksSecrets = BrowserData.masksLogSecrets
        record(assembler.documentFailed(url: address, message: error.localizedDescription))
    }

    private func record(_ entries: [WebLogEntry]) {
        for entry in entries {
            if let writer { writer.append(entry) } else if queued.count < 500 { queued.append(entry) }
        }
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// `tabs.json`: which tabs have a log, for `glance browser`.
@MainActor
enum WebCaptureRegistry {
    private static var purged = false
    private static var scheduled = false

    /// Once per launch, before the first log: nothing a page logged outlives the session that saw it.
    static func prepare() {
        guard !purged else { return }
        purged = true
        WebLogFiles.purge(in: WebLogFiles.folder())
    }

    /// Writes the index soon; a burst of changes (a page loading) makes one write.
    static func refresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                scheduled = false
                let tabs = BrowserTabController.all.compactMap(\.logTab)
                WebLogFiles.writeIndex(tabs, in: WebLogFiles.folder())
            }
        }
    }
}
