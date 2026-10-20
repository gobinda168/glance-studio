import Foundation
import GlanceCore
import GlanceKit

/// The features this build has (GlanceCore's `Feature`): the GA ones, and in a development build the rest too, unless
/// they're switched off in the Develop menu, which remembers the choice (`featureChoices` in Glance's defaults). A
/// release build ignores the choices.
@MainActor
final class StudioFeatures: ObservableObject {
    static let shared = StudioFeatures()

    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard
    private static let choicesKey = "featureChoices"

    /// A development build: the Develop menu shows, and its choices count.
    let isDevelopment: Bool
    @Published private(set) var enabled: Set<Feature>

    private init() {
        let development = AppVersion.current.isDevelopment
        isDevelopment = development
        enabled = Feature.enabled(development: development, choices: Self.savedChoices())
        Prefs.summariesOn = enabled.contains(.summaries)
    }

    func isOn(_ feature: Feature) -> Bool { enabled.contains(feature) }

    /// The Develop menu's switch, saved and applied at once: a side bar whose feature goes off gives way to Terminal's,
    /// the Browser switched on starts its Slack workspaces and Atlassian sites (switched off, they run until Studio quits), Journal and Usage
    /// switched on or off start or stop their timers, and Notifications switched on starts its sources (switched off,
    /// they stop posting), Automations switched on starts its engine (switched off, it stops its triggers and runs),
    /// and the orb channel listens or stops.
    func set(_ feature: Feature, on: Bool) {
        var saved = Self.defaults.dictionary(forKey: Self.choicesKey) ?? [:]
        saved[feature.rawValue] = on
        Self.defaults.set(saved, forKey: Self.choicesKey)
        enabled = Feature.enabled(development: isDevelopment, choices: Self.savedChoices())
        Prefs.summariesOn = isOn(.summaries)
        SidebarModeModel.shared.featuresChanged()
        if feature == .browser && isOn(.browser) { BrowserApps.shared.start() }
        if feature == .journal { isOn(.journal) ? JournalService.shared.start() : JournalService.shared.stop() }
        if feature == .usage { isOn(.usage) ? UsageService.shared.start() : UsageService.shared.stop() }
        if feature == .tickets { isOn(.tickets) ? GlanceTerminalHost.shared.startTickets() : TicketService.shared.stop() }
        if feature == .automations {
            isOn(.automations) ? GlanceTerminalHost.shared.startAutomations() : GlanceTerminalHost.shared.stopAutomations()
        }
        if feature == .meetingNotes {
            MeetingNudger.shared.offersRecording = isOn(.meetingNotes)
            isOn(.meetingNotes) && Prefs.meetingOfferCalls ? CallNudger.shared.start() : CallNudger.shared.stop()
        }
        if feature == .notifications {
            if isOn(.notifications) { GlanceTerminalHost.shared.startNotifications() }
            else { MeetingNudger.shared.postsNotices = false }
        }
        if feature == .orbChannel {
            isOn(.orbChannel) ? OrbChannelStudio.start() : OrbChannelStudio.stop()
            GlanceTerminalHost.shared.refreshFnMonitor()
        }
        if feature == .needsYou { isOn(.needsYou) ? NeedsYouStudio.shared.start() : NeedsYouStudio.shared.stop() }
    }

    private static func savedChoices() -> [Feature: Bool] {
        Feature.choices(saved: defaults.dictionary(forKey: choicesKey) ?? [:])
    }
}
