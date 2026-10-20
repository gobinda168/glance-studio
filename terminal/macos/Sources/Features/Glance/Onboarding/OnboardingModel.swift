import AppKit
import AVFoundation
import Combine
import GlanceCore
import GlanceKit

/// First Light's state and its probes of the real Mac (spec 2026-10-10-first-light-onboarding-design.md): where the
/// flow is, the scene it directs, and for each step what is already true (Claude Code installed and signed in, the
/// permissions, the voice, the linked accounts), read through the same APIs Settings uses.
@MainActor
final class OnboardingModel: ObservableObject {
    struct ClaudeStatus: Equatable {
        var checking = true
        /// Where `claude` is, nil when it isn't installed.
        var path: String?
        var version: String?
        /// The claude.ai account's email ("" signed in without one), nil when not signed in.
        var account: String?
        var sessionsFolder = false

        var found: Bool { path != nil }
        var signedIn: Bool { account != nil }
    }

    /// The intro's beats: nothing yet, the word, the buttons.
    enum IntroStage: Int, Comparable {
        case mark, word, actions
        static func < (a: IntroStage, b: IntroStage) -> Bool { a.rawValue < b.rawValue }
    }

    @Published private(set) var flow = OnboardingFlow()
    @Published private(set) var scene: FirstLightScene
    @Published private(set) var introStage = IntroStage.mark
    @Published private(set) var claude = ClaudeStatus()
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var calendar = CalendarSource.Access.notAsked
    @Published private(set) var speaking = false
    /// A voice was picked and Glance is getting it ready (Glance Voice loads its model on first use).
    @Published private(set) var wakingVoice = false
    @Published private(set) var greeted = false
    /// Lift-off is playing.
    @Published private(set) var leaving = false

    let epoch = Date()
    let settings: SettingsModel
    let github = GitHubAccountModel.shared
    let meetings = MeetingSettingsModel.shared
    private let greeter = GlanceGreeter()
    private var poll: Timer?
    private var observers: Set<AnyCancellable> = []
    private var finished: (() -> Void)?

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    static let ghInstallCommand = "brew install gh"

    init(reduceMotion: Bool, onFinish: @escaping () -> Void) {
        scene = FirstLightScene(reduceMotion: reduceMotion)
        settings = GlanceTerminalHost.shared.settings ?? SettingsModel()
        finished = onFinish
        settings.refreshVoice()
        meetings.reload()
        calendar = meetings.access
        greeter.onSpeakingChange = { [weak self] speaking in
            guard let self else { return }
            self.speaking = speaking
            if speaking { self.wakingVoice = false }
        }
        github.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.accountsChanged() }
        }.store(in: &observers)
        meetings.$access.sink { [weak self] access in self?.calendar = access }.store(in: &observers)

        // The intro's beats follow the mark: the word as the orb settles, then the way in.
        let word = reduceMotion ? 0.2 : 3.3, actions = reduceMotion ? 0.3 : 4.0
        DispatchQueue.main.asyncAfter(deadline: .now() + word) { [weak self] in self?.introStage = .word }
        DispatchQueue.main.asyncAfter(deadline: .now() + actions) { [weak self] in self?.introStage = .actions }
        github.refresh()
    }

    var now: Double { Date().timeIntervalSince(epoch) }
    var level: Double { greeter.level }
    var reduceMotion: Bool { scene.reduceMotion }

    static var firstName: String? { HomeState.greetingName(fullName: NSFullUserName()) }

    // MARK: Moving through

    func begin() {
        introStage = .actions
        flow.begin()
        scene.setLayout(.setup, at: now)
        entered()
    }

    func next() {
        guard !leaving else { return }
        if flow.phase == .finish { return liftOff() }
        flow.next()
        entered()
    }

    func back() {
        guard !leaving else { return }
        flow.back()
        if flow.phase == .intro { scene.setLayout(.intro, at: now) }
        entered()
    }

    /// The step on screen changed: its orb mood, its polling, its probes.
    private func entered() {
        greeter.stop()
        poll?.invalidate()
        poll = nil
        if flow.step == .permissions {
            refreshPermissions()
            poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.refreshPermissions() }
            }
        }
        // Looked for each time the step opens: the orb thinks while it looks.
        if flow.step == .claude { checkClaude() }
        if flow.step == .accounts { github.refresh(force: true) }
        updateMood()
    }

    private func updateMood() {
        let mood = flow.step?.mood(checking: claude.checking) ?? .calm
        if mood != scene.mood { scene.setMood(mood, at: now) }
    }

    private func setDone(_ step: OnboardingStep, _ done: Bool) {
        guard flow.done.contains(step) != done else { return }
        flow.setDone(step, done)
        scene.setLit(step.quarter, done, at: now)
    }

    /// Open Glance Studio: the dial turns, the camera flies into the orb, and the window hands over.
    func liftOff() {
        guard !leaving else { return }
        leaving = true
        greeter.stop()
        poll?.invalidate()
        scene.setMood(.calm, at: now)
        scene.startFinale(at: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + scene.finaleDuration) { [weak self] in
            self?.finished?()
            self?.finished = nil
        }
    }

    /// The window closed or the user chose "Set up later": stop everything that runs.
    func stop() {
        greeter.stop()
        poll?.invalidate()
        poll = nil
        observers.removeAll()
        github.cancelSignIn()
    }

    // MARK: Claude Code

    func checkClaude() {
        claude.checking = true
        updateMood()
        let started = Date()
        ClaudeOneShot.locateWithPath { [weak self] found in
            guard let self else { return }
            guard let found else { return self.claudeChecked(ClaudeStatus(checking: false), since: started) }
            let executable = found.executable, path = found.path
            Task.detached(priority: .userInitiated) {
                let version = Self.run(executable, ["--version"], path: path).flatMap(ClaudeAccount.version(fromOutput:))
                let home = FileManager.default.homeDirectoryForCurrentUser
                let account = (try? Data(contentsOf: home.appendingPathComponent(".claude.json")))
                    .flatMap(ClaudeAccount.signedIn(claudeJSON:))
                let sessions = FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/projects").path)
                await MainActor.run {
                    self.claudeChecked(ClaudeStatus(checking: false, path: executable, version: version,
                                                    account: account, sessionsFolder: sessions), since: started)
                }
            }
        }
    }

    /// Holds a fast answer back a beat, so the thinking orb reads as looking rather than flickering.
    private func claudeChecked(_ status: ClaudeStatus, since started: Date) {
        let wait = max(0, 1.1 - Date().timeIntervalSince(started))
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : wait)) { [weak self] in
            guard let self else { return }
            self.claude = status
            self.setDone(.claude, status.found && status.signedIn)
            // Claude Code may have been installed during this step: set it up for Glance now, not next launch.
            if status.found { ClaudeAutoSetup.run() }
            self.updateMood()
        }
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String], path: String?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let path { environment["PATH"] = path }
        environment["CLAUDECODE"] = nil
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + 5
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Permissions

    var asksForCalendar: Bool { meetings.nudges }

    func refreshPermissions() {
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if calendar != .allowed { meetings.reload() }
        let calendarDone = !asksForCalendar || calendar == .allowed
        setDone(.permissions, accessibility && microphone == .authorized && calendarDone)
    }

    func allowAccessibility() {
        // macOS shows its own dialog pointing at System Settings; the row turns green once it's on.
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            Self.openPrivacy("Privacy_Accessibility")
        }
    }

    func allowMicrophone() {
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { [weak self] in self?.refreshPermissions() }
            }
        } else {
            Self.openPrivacy("Privacy_Microphone")
        }
    }

    func allowCalendar() {
        if calendar == .notAsked { meetings.requestAccess() } else { meetings.openPrivacySettings() }
    }

    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Voice

    /// Picks `voice` and has Glance say hello in it.
    func choose(_ voice: VoiceOption) {
        settings.selectVoice(voice)
        greet()
    }

    func greet() {
        wakingVoice = true
        greeted = true
        greeter.say(OnboardingFlow.greeting(name: Self.firstName))
        setDone(.voice, true)
        // A voice that never starts (no network for a cloud voice, a model that fails to load) stops waiting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.wakingVoice = false }
    }

    // MARK: Accounts

    var cloudOffered: Bool {
        StudioFeatures.shared.isOn(.cloud) && CloudAccount.shared.state != .notSetUp
    }

    var googleOffered: Bool { GoogleAccount.shared.state != .notSetUp }

    var linkedCount: Int {
        var count = github.login == nil ? 0 : 1
        if cloudOffered, CloudAccount.shared.user != nil { count += 1 }
        if googleOffered, GoogleAccount.shared.email != nil { count += 1 }
        return count
    }

    func signInToGoogle() {
        Task {
            _ = try? await GoogleAccount.shared.signIn()
            accountsChanged()
        }
    }

    func accountsChanged() {
        objectWillChange.send()
        scene.setSatellites(linkedCount, at: now)
        setDone(.accounts, linkedCount > 0)
    }
}
