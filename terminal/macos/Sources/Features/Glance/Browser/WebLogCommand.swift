import AppKit
import GlanceCore

/// `glance-browser` in Studio's shells (spec 2026-10-12-web-logs-design.md): a one-line script that runs the bundle's
/// `glance browser …`, so the person and Claude Code type a short name and never need the app's path.
@MainActor
enum WebLogCommand {
    static let name = "glance-browser"

    /// The `glance` helper in the app bundle.
    static var glanceBinary: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/glance").path
    }

    /// Writes the script into `folder`; false when the helper isn't in this build or the write fails.
    static func write(into folder: String) -> Bool {
        let binary = glanceBinary
        guard FileManager.default.isExecutableFile(atPath: binary) else { return false }
        let path = (folder as NSString).appendingPathComponent(name)
        let script = "#!/bin/sh\nexec '\(binary.replacingOccurrences(of: "'", with: "'\\''"))' browser \"$@\"\n"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return true
        } catch {
            NSLog("Glance: glance-browser isn't available in terminals: \(error)")
            return false
        }
    }

    /// A new terminal tab beside `window`'s, in the folder its terminal follows, following the tab's console and
    /// network.
    static func openWatch(tabKey: String, near window: NSWindow?) {
        let folder = HomeTabs.terminal(near: window)?.glanceDirectory ?? NSHomeDirectory()
        let quoted = tabKey.replacingOccurrences(of: "'", with: "'\\''")
        EditorBridgeActions.openTerminalTab(cwd: folder, near: window,
                                            input: "clear; \(name) watch --tab '\(quoted)'\n")
    }
}
