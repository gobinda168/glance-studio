import AppKit
import GlanceCore
import GlanceKit
import WebKit

/// A web app inside a Studio tab (Slack, Jira, Confluence): the page gets every key except Glance Studio's tab- and
/// app-level shortcuts, which go straight to the menu, as in the GS Code tab.
final class StudioWebView: WKWebView {
    /// Right-click on selected text: Ask Claude what to do with it.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        AskClaudeMenu.addItem(to: menu, for: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let key = EditorShortcuts.Key(characters: event.charactersIgnoringModifiers ?? "",
                                      command: flags.contains(.command), shift: flags.contains(.shift),
                                      option: flags.contains(.option), control: flags.contains(.control))
        if EditorShortcuts.belongsToApp(key), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        // ⌘W and ⌘, are the app's too: close the tab, open Settings.
        if key.command, !key.shift, !key.option, ["w", ","].contains(key.characters.lowercased()),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// The user agent's application name that gets a web app's full client: Safari's, at this Mac's Safari version
    /// (18.0 when Safari's Info.plist can't be read).
    static let safariApplicationName: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let version = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? "18.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    /// The whole user agent of Safari on an iPhone, at this Mac's Safari version, for a site's mobile version.
    static let iPhoneUserAgent: String = {
        let safari = safariApplicationName.replacingOccurrences(of: " Safari/605.1.15", with: "")
        let os = (safari.split(separator: "/").last.map(String.init) ?? "18.0").replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "\(safari) Mobile/15E148 Safari/604.1"
    }()
}
