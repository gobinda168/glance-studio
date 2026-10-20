import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Settings → Orb Channel (spec 2026-10-09-orb-channel-design.md, "Setup and Settings").
struct OrbChannelSettings: View {
    @ObservedObject private var hub = OrbChannelHub.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @State private var enabled = Prefs.orbChannelEnabled
    @State private var speak = Prefs.orbChannelSessionsSpeak
    @State private var readQuestions = Prefs.orbChannelReadQuestions
    @State private var launchFlag = Prefs.orbChannelLaunchFlag
    @State private var approvals = Prefs.orbChannelApprovals
    @State private var needsYou = Prefs.needsYouOpen
    @State private var assistant = Prefs.orbAssistantEnabled
    @State private var modifier = Prefs.orbAssistantModifier
    @State private var registration = OrbChannelStudio.mcpRegistration()
    @State private var setupMessage: String?
    @State private var settingUp = false
    @State private var downloaded = MeetingSpeechModels.isDownloaded
    @State private var downloading = false
    @State private var progress = 0.0
    @State private var downloadFailure: String?

    var body: some View {
        SettingsGroup(title: "Claude Code") {
            SettingsRow(id: "orbChannel.enabled", name: "Claude sessions can reach you",
                        detail: registrationLine) {
                HStack(spacing: 10) {
                    if !isRegistered {
                        StudioButton(title: "Set Up", busy: settingUp) { register() }
                    }
                    SettingsSwitch(label: "Claude sessions can reach you", isOn: Binding(get: { enabled }, set: {
                        enabled = $0
                        Prefs.orbChannelEnabled = $0
                        if $0 { OrbChannelStudio.start() } else { OrbChannelStudio.stop() }
                        GlanceTerminalHost.shared.refreshFnMonitor()
                    }))
                }
            }
            SettingsRow(id: "orbChannel.launchFlag", name: "Start Claude with its channel",
                        detail: "Claude started from Studio gets Glance's channel, so you can message it and approve "
                            + "its tools from the orb. Claude asks you to confirm \"local development\" each time it "
                            + "starts.", dimmed: !enabled) {
                SettingsSwitch(label: "Start Claude with its channel", isOn: Binding(get: { launchFlag }, set: {
                    launchFlag = $0; Prefs.orbChannelLaunchFlag = $0 }))
            }
            SettingsRow(id: "orbChannel.sessions", name: "Connected sessions", detail: sessionsLine,
                        dimmed: !enabled) { EmptyView() }
        }
        SettingsGroup(title: "Voice") {
            SettingsRow(id: "orbChannel.speech", name: "Sessions speaking aloud",
                        detail: "Sessions can say short things out loud, and questions are read when they arrive. "
                            + "Never during a meeting or Do not disturb.", dimmed: !enabled) {
                VStack(alignment: .trailing, spacing: 8) {
                    Toggle("Sessions may speak", isOn: Binding(get: { speak }, set: {
                        speak = $0; Prefs.orbChannelSessionsSpeak = $0 })).toggleStyle(.checkbox)
                    Toggle("Read questions aloud", isOn: Binding(get: { readQuestions }, set: {
                        readQuestions = $0; Prefs.orbChannelReadQuestions = $0 })).toggleStyle(.checkbox)
                }
            }
            SettingsRow(id: "orbChannel.voice", name: "Voice answers",
                        detail: voiceLine, dimmed: !enabled) {
                if downloading {
                    ProgressView().controlSize(.small)
                } else if !downloaded {
                    StudioButton(title: "Download", enabled: !recorder.isBusy) { download() }
                }
            }
        }
        if StudioFeatures.shared.isOn(.needsYou) {
            SettingsGroup(title: "When Claude needs you") {
                SettingsRow(id: "orbChannel.needsYou", name: "When Claude needs you",
                            detail: "A permission, question or plan in a Studio split makes the orb glow. Click it to "
                                + "answer from any app, or let the card open by itself.", dimmed: false) {
                    SettingsMenu(label: "When Claude needs you", title: needsYou.title,
                                 options: NeedsYouOpen.allCases.map {
                                     SegmentItem(value: $0.rawValue, title: $0.title, count: nil)
                                 },
                                 selection: needsYou.rawValue, width: 260) { value in
                        needsYou = NeedsYouOpen(rawValue: value) ?? .glow
                        Prefs.needsYouOpen = needsYou
                    }
                }
            }
        }
        SettingsGroup(title: "Approvals and the assistant") {
            SettingsRow(id: "orbChannel.approvals", name: "Approvals from the orb",
                        detail: "A session's permission prompt also shows as a card you can answer with a click, "
                            + "⌥Y / ⌥N, or by voice. The terminal's own prompt still works.", dimmed: !enabled) {
                SettingsSwitch(label: "Approvals from the orb", isOn: Binding(get: { approvals }, set: {
                    approvals = $0; Prefs.orbChannelApprovals = $0 }))
            }
            SettingsRow(id: "orbChannel.assistant", name: "Orb assistant",
                        detail: "Hold fn with the pointer on the orb, or hold the key below with fn anywhere, and "
                            + "talk to Claude. It asks before it sends or changes anything.", dimmed: !enabled) {
                HStack(spacing: 10) {
                    StudioButton(title: "New conversation", enabled: assistant) {
                        OrbAssistant.shared.newConversation()
                    }
                    SettingsMenu(label: "Talk to the assistant with", title: Self.modifierTitle(modifier),
                                 options: [SegmentItem(value: "control", title: "⌃ + fn", count: nil),
                                           SegmentItem(value: "option", title: "⌥ + fn", count: nil),
                                           SegmentItem(value: "shift", title: "⇧ + fn", count: nil)],
                                 selection: modifier, width: 120) { value in
                        modifier = value
                        Prefs.orbAssistantModifier = value
                    }
                    SettingsSwitch(label: "Orb assistant", isOn: Binding(get: { assistant }, set: {
                        assistant = $0
                        Prefs.orbAssistantEnabled = $0
                        if !$0 { OrbAssistant.shared.end() }
                    }))
                }
            }
        }
        .onAppear {
            registration = OrbChannelStudio.mcpRegistration()
            downloaded = MeetingSpeechModels.isDownloaded
        }
    }

    private var isRegistered: Bool {
        if case .registered = registration { true } else { false }
    }

    private static func modifierTitle(_ value: String) -> String {
        switch value {
        case "option": "⌥ + fn"
        case "shift": "⇧ + fn"
        default: "⌃ + fn"
        }
    }

    private var registrationLine: String {
        if let setupMessage { return setupMessage }
        if enabled, let failure = hub.failure { return "Glance couldn't listen: \(failure)" }
        switch registration {
        case .registered: return "Claude Code has Glance's MCP server, so sessions can nudge you, ask you things "
            + "and speak. Sessions started from Studio can also be messaged from the orb."
        case .missing: return "Set up adds Glance's MCP server to Claude Code (claude mcp add-json --scope user glance)."
        case .other(let command): return "Claude Code has another server named \"glance\" (\(command)). Set Up replaces it."
        }
    }

    private var sessionsLine: String {
        let sessions = hub.book.sessions.values.sorted { $0.label < $1.label }
        guard !sessions.isEmpty else { return "None right now." }
        return sessions.map { session in
            [session.label, session.caption, session.channel ? "can be messaged" : nil].compactMap { $0 }
                .joined(separator: " · ")
        }.joined(separator: "\n")
    }

    private var voiceLine: String {
        if downloading { return "Downloading the speech model… \(Int(progress * 100))%" }
        if let downloadFailure { return "Couldn't download the speech model: \(downloadFailure)" }
        return downloaded
            ? "Hold fn while a card is showing and say your answer. It's turned into text on this Mac."
            : "Hold fn while a card is showing and say your answer. Download the speech model to do this on this "
                + "Mac; until then your ElevenLabs key is used, if you've added one."
    }

    /// Downloads and compiles Parakeet (as Meeting Notes does), then lets it go: it loads when an answer is spoken.
    private func download() {
        guard !downloading else { return }
        downloading = true
        downloadFailure = nil
        progress = 0
        Task { @MainActor in
            do {
                try await MeetingSpeechModels.shared.loadTranscription { fraction, _ in
                    Task { @MainActor in progress = fraction }
                }
                await MeetingSpeechModels.shared.releaseTranscription()
            } catch {
                downloadFailure = error.localizedDescription
            }
            downloading = false
            downloaded = MeetingSpeechModels.isDownloaded
        }
    }

    /// The same `claude mcp` calls `glance setup` makes, after asking.
    private func register() {
        let alert = NSAlert()
        alert.messageText = "Add Glance to Claude Code?"
        alert.informativeText = "Glance runs claude mcp add-json --scope user glance, so every Claude Code session can "
            + "reach you through Glance."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard !settingUp, alert.runModal() == .alertFirstButtonReturn else { return }
        settingUp = true
        setupMessage = nil
        let glance = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/glance").path
        // `claude` found as the rest of Glance finds it: the login shell's PATH and the usual install places.
        ClaudeOneShot.locateWithPath { found in
            guard let found else {
                setupMessage = "Couldn't find Claude Code. Install it, or run glance setup in a terminal."
                settingUp = false
                return
            }
            Task.detached {
                _ = ClaudeSetup.runClaude(found.executable, path: found.path, MCPSetup.removeArguments)
                let (status, output) = ClaudeSetup.runClaude(found.executable, path: found.path,
                                                              MCPSetup.addArguments(glancePath: glance))
                await MainActor.run {
                    setupMessage = status == 0 ? nil : "Couldn't add it: \(output)"
                    registration = OrbChannelStudio.mcpRegistration()
                    settingUp = false
                }
            }
        }
    }
}
