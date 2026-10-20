import AppKit
import GlanceCore

/// Where glance.openURL and a link clicked in an automation's page go (`AutomationLinks`): GitHub pull requests and
/// issues as PR tabs (github.com never opens in a browser), Slack workspaces in Chats, files in the editor (pictures
/// in Quick Look, folders in Finder), other web pages in the browser. A page can name any path, so nothing the system
/// could run is opened: applications and scripts are only shown in Finder.
@MainActor
enum AutomationLinkOpener {
    /// Extensions of things that run (or launch something) when opened.
    static let runnableExtensions: Set<String> = ["app", "command", "tool", "terminal", "webloc", "inetloc", "fileloc",
                                                  "workflow", "scpt", "sh"]

    /// nil when it opened; otherwise why not (glance.openURL rejects with it).
    @discardableResult
    static func open(_ text: String, from window: NSWindow?) -> String? {
        switch AutomationLinks.route(text) {
        case .pullRequest(let repository, let number):
            let tab = PullRequestWindowController.open(repository: repository, number: number, root: nil, from: window)
            return tab == nil ? "Couldn't open \(repository)#\(number) in Studio." : nil
        case .slack(let team):
            guard StudioFeatures.shared.isOn(.browser) else { return "Slack opens in the Browser, which is off in this build." }
            BrowserTabController.openSlack(teamID: team, from: window)
            return nil
        case .file(let path):
            // Only "~" and "~/…" reach here (AutomationLinks); other users' homes are not expanded.
            let absolute = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: absolute) else { return "There's nothing at \(path)." }
            openFile(absolute, from: window)
            return nil
        case .browser(let url):
            NSWorkspace.shared.open(url)
            return nil
        case .refused(let reason):
            return reason
        }
    }

    /// What the page's own scripts and clicks may reach: only paths inside `roots` open, and a web page opens in the
    /// browser only after the user says yes in a sheet on `window`, clicks included (a script can click a link too).
    /// `completion` gets nil when it opened, else why not (what glance.openURL rejects with).
    static func openFromPage(_ text: String, from window: NSWindow?, roots: [String],
                             completion: @escaping @MainActor (String?) -> Void) {
        switch AutomationLinks.route(text) {
        case .file(let path):
            guard let absolute = insideRoots(path, roots: roots) else { return completion(outsideFolders) }
            guard FileManager.default.fileExists(atPath: absolute) else {
                return completion("There's nothing at \(path).")
            }
            openFile(absolute, from: window)
            completion(nil)
        case .browser(let url):
            confirmBrowser(url, in: window, completion: completion)
        default:
            completion(open(text, from: window))
        }
    }

    static let outsideFolders = "Glance only opens files from this automation's folders."

    /// The absolute path for `path` ("~" and "~/…" expand to the user's home) when it is inside one of `roots` or is
    /// one; nil otherwise, whether or not anything is there, so a page learns nothing about the rest of the disk.
    /// Symlinks are resolved on the path (as far as it exists) and on the roots; ".." is never accepted.
    static func insideRoots(_ path: String, roots: [String]) -> String? {
        guard path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else { return nil }
        let absolute = (path as NSString).expandingTildeInPath
        guard !absolute.split(separator: "/").contains("..") else { return nil }
        let real = resolved(absolute)
        for root in roots {
            let base = resolved(root)
            if real == base || AutomationWeb.isInside(real, root: base) { return absolute }
        }
        return nil
    }

    /// The path with symlinks resolved as far as it exists, then the rest as it is.
    private static func resolved(_ path: String) -> String {
        var existing = path
        var rest: [Substring] = []
        while existing.count > 1, realpathString(existing) == nil {
            guard let slash = existing.lastIndex(of: "/") else { break }
            rest.insert(existing[existing.index(after: slash)...], at: 0)
            existing = slash == existing.startIndex ? "/" : String(existing[..<slash])
        }
        let base = realpathString(existing) ?? existing
        return rest.isEmpty ? base : (base == "/" ? "" : base) + "/" + rest.joined(separator: "/")
    }

    private static func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether a link is waiting for the user's answer: one sheet at a time, so a page can't stack them.
    private static var confirming = false

    private static func confirmBrowser(_ url: URL, in window: NSWindow?,
                                       completion: @escaping @MainActor (String?) -> Void) {
        guard let window else { return completion("Open the automation's tab first.") }
        guard !confirming else { return completion("Another link is waiting for an answer.") }
        confirming = true
        let alert = NSAlert()
        alert.messageText = "Open \(url.host ?? "this page") in your browser?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    confirming = false
                    guard response == .alertFirstButtonReturn else { return completion("The link wasn't opened.") }
                    NSWorkspace.shared.open(url)
                    completion(nil)
                }
            }
        }
    }

    /// The editor or Quick Look for a file, Finder for a folder, an application or a script.
    private static func openFile(_ absolute: String, from window: NSWindow?) {
        if !runs(absolute), let window, GlanceEditorHost.openFromPane(absolute, from: window, directory: nil) { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolute)])
    }

    /// An application bundle, or a file of a kind that runs when opened. A symlink counts by what it points to too.
    static func runs(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        for url in [URL(fileURLWithPath: path), resolved] {
            if runnableExtensions.contains(url.pathExtension.lowercased()) { return true }
            if (try? url.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true { return true }
        }
        return false
    }
}
