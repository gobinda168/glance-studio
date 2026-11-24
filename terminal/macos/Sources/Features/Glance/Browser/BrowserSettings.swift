import GlanceCore
import GlanceKit
import SwiftUI

/// Settings → Browser (spec 2026-10-10-browser-design.md, "Settings → Browser"): the search engine, dev servers in the
/// Browser, clearing history and site data, then the Jira and Confluence sites.
struct BrowserSettings: View {
    @State private var engine = BrowserData.searchEngine
    @State private var devServers = BrowserData.opensDevServers
    @State private var floatsMobile = BrowserData.floatsMobileSite
    @State private var capturesLogs = BrowserData.capturesLogs
    @State private var masksSecrets = BrowserData.masksLogSecrets
    @State private var showsAgent = BrowserData.showsAgentBrowser
    @State private var agentTests = BrowserData.testsInAgentBrowser
    @State private var agentIdle = BrowserData.agentBrowserQuitsWhenIdle
    @State private var agentEngine = BrowserData.agentBrowserEngine
    @State private var recordsClips = ClipSettings.recordClips
    @ObservedObject private var features = StudioFeatures.shared
    @State private var confirmHistory = false
    @State private var confirmData = false
    /// What Clear old media can free and what the session records hold, read off the main thread; nil until read.
    @State private var mediaBytes: Int64?
    @State private var confirmMedia = false
    @State private var clearingMedia = false

    private nonisolated static let mediaDays = 14

    private var mediaSize: String {
        guard let mediaBytes else { return "Measuring…" }
        return ByteCountFormatter.string(fromByteCount: mediaBytes, countStyle: .file)
    }

    private func measureMedia() {
        Task.detached(priority: .utility) {
            let size = WorkStore().mediaSize()
            await MainActor.run { mediaBytes = size }
        }
    }

    private func clearOldMedia() {
        clearingMedia = true
        Task.detached(priority: .utility) {
            let store = WorkStore()
            store.clearOldMedia(olderThan: Self.mediaDays, liveSessions: WorkStore.liveSessions(), now: Date())
            let size = store.mediaSize()
            await MainActor.run {
                mediaBytes = size
                clearingMedia = false
            }
        }
    }

    private var agentPorts: String {
        let idle = "When nothing uses it and it has no page open."
        guard let ports = AgentBrowserBroker.shared.ports else { return idle }
        return idle + " Playwright clients connect on port \(ports.client), Claude's MCP on \(ports.cdp)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Browsing") {
                SettingsRow(id: "browser.search", name: "Search engine",
                            detail: "What the address field searches when you type words instead of an address.") {
                    SettingsMenu(label: "Search engine", title: engine.title,
                                 options: SearchEngine.allCases.map { SegmentItem(value: $0, title: $0.title, count: nil) },
                                 selection: engine) { choice in
                        engine = choice
                        BrowserData.searchEngine = choice
                    }
                }
                SettingsRow(id: "browser.devServers", name: "Open dev servers in Glance Browser",
                            detail: "A localhost page from a terminal, a link you click or a dev server opening its "
                                + "page, opens in a Browser tab. Off, it opens in your default browser. Switched on, "
                                + "dev servers in terminals opened after that use it.") {
                    SettingsSwitch(label: "Open dev servers in Glance Browser", isOn: Binding(get: { devServers }, set: {
                        devServers = $0
                        BrowserData.opensDevServers = $0
                    }))
                }
                SettingsRow(id: "browser.floatMobile", name: "Mobile site in the floating window",
                            detail: "A page you float with the PiP button switches to its mobile site, made for a small "
                                + "window, and back to the desktop site when it goes back to its tab. A call or a "
                                + "playing video stays as it is; the window's top strip switches any time.") {
                    SettingsSwitch(label: "Mobile site in the floating window", isOn: Binding(get: { floatsMobile }, set: {
                        floatsMobile = $0
                        BrowserData.floatsMobileSite = $0
                    }))
                }
                SettingsRow(id: "browser.history", name: "History",
                            detail: "The pages you visited, kept on this Mac for the address field's suggestions.") {
                    StudioButton(title: "Clear History…") { confirmHistory = true }
                }
                SettingsRow(id: "browser.siteData", name: "Site data",
                            detail: "Cookies and storage for every site in the Browser, Slack, Jira and Confluence too. "
                                + "Clearing it signs you out of all of them.") {
                    StudioButton(title: "Clear Site Data…") { confirmData = true }
                }
            }
            SettingsGroup(title: "Developer") {
                SettingsRow(id: "browser.logs", name: "Console and network in the terminal",
                            detail: "Records each tab's console messages and fetch and XHR requests, so "
                                + "glance-browser can show them in a terminal and Claude Code can read them. The "
                                + "log is deleted when the tab closes. Applies to tabs opened after you change it.") {
                    SettingsSwitch(label: "Console and network in the terminal", isOn: Binding(get: { capturesLogs }, set: {
                        capturesLogs = $0
                        BrowserData.capturesLogs = $0
                    }))
                }
                SettingsRow(id: "browser.logSecrets", name: "Mask passwords and tokens in logs",
                            detail: "Authorization and cookie headers, passwords, tokens and keys in addresses and "
                                + "bodies are replaced with [masked] before anything is written.") {
                    SettingsSwitch(label: "Mask passwords and tokens in logs", isOn: Binding(get: { masksSecrets }, set: {
                        masksSecrets = $0
                        BrowserData.masksLogSecrets = $0
                    }))
                }
            }
            SettingsGroup(title: "Glance browser") {
                SettingsRow(id: "browser.agentEngine", name: "Claude's browser",
                            detail: "Chromium opens a real window you can watch, sign in to and inspect. Lightpanda is a "
                                + "fast headless browser: no window and no screenshots, and some sites won't work in it. "
                                + "It downloads the first time. Playwright tests always run on Chromium.") {
                    SettingsMenu(label: "Claude's browser", title: agentEngine.title,
                                 options: AgentBrowserEngine.allCases.map { SegmentItem(value: $0, title: $0.title, count: nil) },
                                 selection: agentEngine) { choice in
                        agentEngine = choice
                        BrowserData.agentBrowserEngine = choice
                        AgentBrowserBroker.shared.engine = choice
                        AgentBrowserSessions.shared.updateOptions() // Lightpanda has no windows to give each session
                    }
                }
                if features.isOn(.commandCenter), agentEngine == .chromium {
                    SettingsRow(id: "browser.clips", name: "Record clips of what Claude does in the browser",
                                detail: "Up to 3 minutes per page visit, kept with the session's proof. Tabs you open "
                                    + "yourself aren't recorded.") {
                        SettingsSwitch(label: "Record clips of what Claude does in the browser", isOn: Binding(get: { recordsClips }, set: {
                            recordsClips = $0
                            ClipSettings.recordClips = $0
                        }))
                    }
                }
                SettingsRow(id: "browser.agentShow", name: "Bring the Glance browser forward when it opens a page",
                            detail: "Claude Code and Playwright tests use their own Chromium window, separate from your "
                                + "browsers: sign in there once and it remembers. Its window rises without taking focus; "
                                + "View → Glance Browser (⌥⌘B) brings it to the front any time.") {
                    SettingsSwitch(label: "Bring the Glance browser forward when it opens a page", isOn: Binding(get: { showsAgent }, set: {
                        showsAgent = $0
                        BrowserData.showsAgentBrowser = $0
                    }))
                }
                SettingsRow(id: "browser.agentTests", name: "Run Playwright tests in the Glance browser",
                            detail: "Terminals get PW_TEST_CONNECT_WS_ENDPOINT, so `npx playwright test` runs in visible "
                                + "Chromium windows (Chromium projects only). Terminals opened after a change use it.") {
                    SettingsSwitch(label: "Run Playwright tests in the Glance browser", isOn: Binding(get: { agentTests }, set: {
                        agentTests = $0
                        BrowserData.testsInAgentBrowser = $0
                    }))
                }
                SettingsRow(id: "browser.agentIdle", name: "Quit the browser after 5 minutes idle",
                            detail: agentPorts) {
                    SettingsSwitch(label: "Quit the browser after 5 minutes idle", isOn: Binding(get: { agentIdle }, set: {
                        agentIdle = $0
                        BrowserData.agentBrowserQuitsWhenIdle = $0
                        AgentBrowserBroker.shared.quitsWhenIdle = $0
                    }))
                }
            }
            if features.isOn(.commandCenter) {
                SettingsGroup(title: "Work folder") {
                    SettingsRow(id: "browser.workMedia", name: "Screenshots, clips and downloaded images",
                                detail: "\(mediaSize) kept with your sessions' proof. Clearing removes the media of "
                                    + "sessions untouched for \(Self.mediaDays) days or more; their notes and checks "
                                    + "stay, and their captures show as missing. A session that is still running is "
                                    + "never cleared.") {
                        StudioButton(title: clearingMedia ? "Clearing…" : "Clear Old Media…") { confirmMedia = true }
                            .disabled(clearingMedia || mediaBytes == nil)
                    }
                }
            }
            SettingsGroup(title: "Jira and Confluence") {
                SettingsRow(id: "browser.jira", name: "Jira and Confluence sites",
                            detail: "Your company's sites, and Claude's Atlassian connector, are in Settings → Connectors.") {
                    StudioButton(title: "Open Connectors") { SettingsNavigation.shared.show(.connectors) }
                }
            }
        }
        .onAppear { if features.isOn(.commandCenter) { measureMedia() } }
        .alert("Clear old media?", isPresented: $confirmMedia) {
            Button("Clear Old Media", role: .destructive) { clearOldMedia() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Work folder holds \(mediaSize). The screenshots, clips and downloaded images of sessions untouched for \(Self.mediaDays) days or more are deleted; what is in use stays. Notes and check results are kept.")
        }
        .alert("Clear your Browser history?", isPresented: $confirmHistory) {
            Button("Clear History", role: .destructive) { BrowserData.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The address field stops suggesting pages you visited. Your apps and open tabs stay.")
        }
        .alert("Clear all site data?", isPresented: $confirmData) {
            Button("Clear Site Data", role: .destructive) { BrowserData.clearSiteData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll be signed out of every site in the Browser, including Slack, Jira and Confluence.")
        }
    }
}
