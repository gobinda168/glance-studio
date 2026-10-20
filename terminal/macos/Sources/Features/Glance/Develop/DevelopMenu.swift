import AppKit
import GlanceCore
import GlanceKit

/// The Develop menu, between View and Window as in Safari, in a development build only: a checkmark for each feature
/// that isn't GA yet, to use Studio with or without it. A release build has no such menu.
@MainActor
final class DevelopMenu: NSObject, NSMenuItemValidation {
    static let shared = DevelopMenu()

    func install(in mainMenu: NSMenu) {
        guard StudioFeatures.shared.isDevelopment, !Feature.unreleased.isEmpty else { return }
        let menu = NSMenu(title: "Develop")
        menu.addItem(.sectionHeader(title: "Unreleased Features"))
        for feature in Feature.unreleased {
            let item = NSMenuItem(title: feature.title, action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = feature.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Notifications"))
        let test = NSMenuItem(title: "Show a Test Notification", action: #selector(showTestNotice), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Tickets"))
        let morning = NSMenuItem(title: "Show the Morning Card", action: #selector(showMorning), keyEquivalent: "")
        morning.target = self
        menu.addItem(morning)
        let checkIn = NSMenuItem(title: "Show the Check-in", action: #selector(showCheckIn), keyEquivalent: "")
        checkIn.target = self
        menu.addItem(checkIn)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Claude Needs You"))
        let screen = NSMenuItem(title: "Copy Focused Split's Screen", action: #selector(copyScreen), keyEquivalent: "")
        screen.target = self
        menu.addItem(screen)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Glance Server"))
        for name in CloudEnvironment.Name.allCases {
            let item = NSMenuItem(title: "Server: \(name.title)", action: #selector(useCloud(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "cloud.\(name.rawValue)"
            menu.addItem(item)
        }
        let develop = NSMenuItem(title: "Develop", action: nil, keyEquivalent: "")
        develop.submenu = menu
        let window = mainMenu.items.firstIndex { $0.submenu?.title == "Window" } ?? mainMenu.items.count
        mainMenu.insertItem(develop, at: window)
    }

    @objc private func toggle(_ item: NSMenuItem) {
        guard let feature = feature(of: item) else { return }
        StudioFeatures.shared.set(feature, on: !StudioFeatures.shared.isOn(feature))
    }

    /// A made-up Slack message as a nudge card, and in the inbox (Notifications on only).
    @objc private func showTestNotice() {
        NudgeStack.shared.showTest()
    }

    /// The morning card now: a fetch and a rank, as at the user's morning time (Tickets on only).
    @objc private func showMorning() {
        TicketService.shared.morning()
    }

    /// The end-of-day check-in now, with what was touched today (nothing shows when nothing was).
    @objc private func showCheckIn() {
        TicketService.shared.checkIn()
    }

    /// The key window's focused split's visible text on the pasteboard: fixtures from the real terminal, and a look
    /// at what the dialog parser saw.
    @objc private func copyScreen() {
        guard let view = Self.focusedSplit, let text = SurfaceScreen.visibleText(view) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static var focusedSplit: Ghostty.SurfaceView? {
        (NSApp.keyWindow?.windowController as? TerminalController)?.focusedSurface
            ?? TerminalController.preferredParent?.focusedSurface
    }

    /// The Glance server for this development build (each keeps its own sign-in).
    @objc private func useCloud(_ item: NSMenuItem) {
        if let name = cloud(of: item) { CloudAccount.shared.use(name) }
    }

    /// Each feature's checkmark, and the Glance server's, current whenever the menu opens.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showTestNotice) { return StudioFeatures.shared.isOn(.notifications) }
        if item.action == #selector(showMorning) || item.action == #selector(showCheckIn) {
            return StudioFeatures.shared.isOn(.tickets)
        }
        if item.action == #selector(copyScreen) { return Self.focusedSplit != nil }
        if let feature = feature(of: item) { item.state = StudioFeatures.shared.isOn(feature) ? .on : .off }
        if let name = cloud(of: item) { item.state = CloudAccount.shared.environment.name == name ? .on : .off }
        return true
    }

    private func cloud(of item: NSMenuItem) -> CloudEnvironment.Name? {
        guard let text = item.representedObject as? String, text.hasPrefix("cloud.") else { return nil }
        return CloudEnvironment.Name(rawValue: String(text.dropFirst("cloud.".count)))
    }

    private func feature(of item: NSMenuItem) -> Feature? {
        (item.representedObject as? String).flatMap(Feature.init(rawValue:))
    }
}
