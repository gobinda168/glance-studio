import Foundation
import GlanceCore
import GlanceKit
import WebKit

/// Serves `glance-automation://` (spec 2026-10-09-automations-design.md, "Web UI contract"): a package's own files
/// (only inside its folder, symlinks resolved; pages get the CSP as a header and as their first `<meta>`), and
/// Glance's tokens.css, glance.js and fonts. Only automations the engine has loaded are served, and a handler made for
/// one automation (`owner`) serves nothing of another's. Files are read off the main thread.
@MainActor
final class AutomationSchemeHandler: NSObject, WKURLSchemeHandler {
    private struct Served: Sendable {
        let path: String
        let data: Data
    }

    /// What a request needs to be answered off the main thread.
    private enum Job: Sendable {
        case asset(String)
        case package(folder: URL, libraryRoot: String, path: String)
    }

    private let owner: String?
    private let queue = DispatchQueue(label: "dev.glance.automation.web", qos: .userInitiated)
    /// Tasks WebKit hasn't stopped yet. Answering a stopped task throws an Objective-C exception, so the answer looks
    /// its task up here on the main actor.
    private var live: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    /// `owner`: the automation whose page this serves (its own files and the shared assets only); nil serves any
    /// automation the engine has loaded.
    init(owner: String? = nil) {
        self.owner = owner
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        guard let job = job(for: url) else { return finish(task, url: url, served: nil) }
        let key = ObjectIdentifier(task)
        live[key] = task
        queue.async { [weak self] in
            let served = Self.read(job)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let task = self.live.removeValue(forKey: key) else { return }
                    self.finish(task, url: url, served: served)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live[ObjectIdentifier(task)] = nil
    }

    /// The request as a job, or nil (404): not an address of ours, an unknown or reserved id, or another automation's.
    private func job(for url: URL) -> Job? {
        switch AutomationWeb.route(url) {
        case .refused:
            return nil
        case .asset(let name):
            return .asset(name)
        case .package(let id, let path):
            let engine = AutomationEngine.shared
            guard engine.entry(id) != nil, owner == nil || owner == id else { return nil }
            return .package(folder: engine.library.folder(id), libraryRoot: engine.library.realPath, path: path)
        }
    }

    private func finish(_ task: any WKURLSchemeTask, url: URL, served: Served?) {
        let status = served == nil ? 404 : 200
        var headers = AutomationWeb.headers(path: served?.path ?? "", length: served?.data.count ?? 0)
        if served == nil { headers["Content-Type"] = "text/plain; charset=utf-8" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: PreviewFiles.mimeType(forPath: served?.path ?? ""),
                           expectedContentLength: served?.data.count ?? 0, textEncodingName: nil)
        task.didReceive(response)
        if let served { task.didReceive(served.data) }
        task.didFinish()
    }

    /// The bytes for a job, or nil (not found, or a path that resolves outside its package).
    nonisolated private static func read(_ job: Job) -> Served? {
        switch job {
        case .asset("tokens.css"):
            guard let tokens = try? String(contentsOf: Resources.designTokens, encoding: .utf8) else { return nil }
            return Served(path: "tokens.css", data: Data(AutomationWeb.tokensCSS(designTokens: tokens).utf8))
        case .asset("glance.js"):
            return (try? Data(contentsOf: Resources.automationScript)).map { Served(path: "glance.js", data: $0) }
        case .asset(let font):
            // fonts/<name>.woff2, from Web/vendor/fonts.
            let file = Resources.web.appendingPathComponent("vendor").appendingPathComponent(font)
            return (try? Data(contentsOf: file)).map { Served(path: font, data: $0) }
        case .package(let folder, let libraryRoot, let path):
            // The path was percent-decoded once by AutomationWeb.route and is never decoded or expanded again. The
            // package's folder and the file are both resolved (realpath), so a symlink can't lead out of either.
            guard let root = realPath(folder.path), AutomationWeb.isInside(root, root: libraryRoot),
                  let file = realPath(folder.appendingPathComponent(path).path),
                  AutomationWeb.isInside(file, root: root) else { return nil }
            // A symlink inside the package can't reach a hidden file (.git, .env) of it either.
            let relative = file.dropFirst(root.count + 1)
            guard relative.split(separator: "/").allSatisfy({ !$0.hasPrefix(".") }),
                  var data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { return nil }
            if AutomationWeb.isHTML(path) {
                data = Data(AutomationWeb.injectingPolicy(String(decoding: data, as: UTF8.self)).utf8)
            }
            return Served(path: path, data: data)
        }
    }

    /// The path with every symlink resolved, or nil when nothing is there.
    nonisolated private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
