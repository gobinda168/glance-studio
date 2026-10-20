import AVFoundation
import GlanceCore
import GlanceKit
import SwiftUI

/// First Light's window content: the scene full bleed, the word and the way in over it, then a glass card per step on
/// the right while the mark lives on the left (spec 2026-10-10-first-light-onboarding-design.md).
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onLater: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            FirstLightView(scene: model.scene, epoch: model.epoch, level: { model.level })
                .ignoresSafeArea()

            // On lift-off the words and cards leave first; the scene plays on.
            Group {
                switch model.flow.phase {
                case .intro:
                    IntroOverlay(model: model, onLater: onLater)
                        .transition(.opacity)
                case .step(let step):
                    card { StepCard(model: model, step: step) }
                        .id(step)
                        .transition(arrival)
                case .finish:
                    card { FinishCard(model: model) }
                        .transition(arrival)
                }
            }
            .opacity(model.leaving ? 0 : 1)
            .allowsHitTesting(!model.leaving)
            .animation(.easeIn(duration: 0.16), value: model.leaving)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .smooth(duration: 0.42), value: model.flow.phase)
        .frame(minWidth: 860, minHeight: 580)
    }

    /// A card arrives risen and slightly blurred (MASTER `.g-rise`) and leaves faster by fading.
    private var arrival: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: Rise(progress: 0), identity: Rise(progress: 1)),
            removal: .opacity.animation(.easeIn(duration: 0.16)))
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer(minLength: 0)
            content()
                .frame(width: 420)
                .padding(28)
                .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous), solid: StudioColors.solid)
                .overlay(alignment: .top) {
                    // The rim: glass's lit top edge.
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [StudioColors.rim, .clear], startPoint: .top,
                                                     endPoint: .center), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
                .padding(.trailing, 48)
        }
        .frame(maxHeight: .infinity)
    }

    private struct Rise: ViewModifier {
        let progress: Double
        func body(content: Content) -> some View {
            content
                .offset(y: (1 - progress) * 16)
                .scaleEffect(0.97 + 0.03 * progress)
                .blur(radius: (1 - progress) * 4)
                .opacity(progress)
        }
    }
}

// MARK: - The intro

private struct IntroOverlay: View {
    @ObservedObject var model: OnboardingModel
    let onLater: () -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                    .frame(height: geometry.size.height * 0.4 + min(geometry.size.width, geometry.size.height) * 0.25 + 30)
                VStack(spacing: 10) {
                    Text("Glance Studio")
                        .font(.studio(34, .semibold))
                        .tracking(-0.7)
                        .foregroundStyle(StudioColors.ink)
                    Text("Claude Code, made legible and audible.")
                        .font(.studio(15))
                        .foregroundStyle(StudioColors.body)
                }
                .modifier(Beat(shown: model.introStage >= .word))
                VStack(spacing: 12) {
                    HStack(spacing: 14) {
                        GlowPill(title: "Begin", hint: "↩", height: 34) { model.begin() }
                            .keyboardShortcut(.defaultAction)
                        StudioButton(title: "Set up later", hint: "esc", style: .quiet, height: 34, action: onLater)
                            .keyboardShortcut(.cancelAction)
                    }
                    Text("Four short steps, about a minute.")
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                }
                .padding(.top, 26)
                .modifier(Beat(shown: model.introStage >= .actions))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// One entrance each: a rise for the word, the same for the buttons a beat later.
    private struct Beat: ViewModifier {
        let shown: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func body(content: Content) -> some View {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 14)
                .blur(radius: shown || reduceMotion ? 0 : 5)
                .animation(reduceMotion ? .easeOut(duration: 0.16) : .smooth(duration: 0.6), value: shown)
                .allowsHitTesting(shown)
        }
    }
}

// MARK: - The steps

private struct StepCard: View {
    @ObservedObject var model: OnboardingModel
    let step: OnboardingStep

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.studio(23, .semibold))
                .tracking(-0.3)
                .foregroundStyle(StudioColors.ink)
            Text(lead)
                .font(.studio(13.5))
                .lineSpacing(3)
                .foregroundStyle(StudioColors.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 0) {
                switch step {
                case .claude: ClaudeRows(model: model)
                case .permissions: PermissionRows(model: model)
                case .voice: VoicePicker(model: model)
                case .accounts: AccountRows(model: model)
                }
            }
            .padding(.top, 20)
            Footer(model: model, step: step)
                .padding(.top, 24)
        }
    }

    private var title: String {
        switch step {
        case .claude: "Find Claude Code"
        case .permissions: "Let Glance work beside you"
        case .voice: "Pick Glance's voice"
        case .accounts: "Link your accounts"
        }
    }

    private var lead: String {
        switch step {
        case .claude:
            "Glance follows your Claude Code sessions and reads each reply aloud, so it needs the claude command on this Mac."
        case .permissions:
            "macOS asks for each of these once. You can change them any time in System Settings → Privacy & Security."
        case .voice:
            switch model.settings.narration {
            case .kokoro: "This is how Glance reads Claude's replies. Glance Voice runs on this Mac."
            case .cloud: "This is how Glance reads Claude's replies, with the cloud voice set up in Settings → Voice."
            case .mac: "This is how Glance reads Claude's replies, with a voice from macOS."
            }
        case .accounts:
            "Optional. Pull requests use GitHub. Nothing is linked until you choose it."
        }
    }
}

private struct Footer: View {
    @ObservedObject var model: OnboardingModel
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 10) {
            StudioButton(title: "Back", style: .quiet) { model.back() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            if let position = model.flow.position {
                Text("\(position.index) of \(position.count)")
                    .font(.studioMono(11))
                    .foregroundStyle(StudioColors.muted)
                    .accessibilityLabel("Step \(position.index) of \(position.count)")
            }
            Spacer(minLength: 0)
            if !model.flow.done.contains(step) {
                StudioButton(title: "Skip", style: .quiet) { model.next() }
                    .keyboardShortcut(.cancelAction)
            }
            StudioButton(title: step == .accounts ? "Finish" : "Continue", hint: "↩", style: .primary) { model.next() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A row of a step: a status light, what it is, where it stands, and what to do about it.
private struct SetupRow<Actions: View>: View {
    enum Light { case checking, done, todo, off }

    let light: Light
    let title: String
    let detail: String
    var mono = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusLight(light: light)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.studio(13, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Text(detail)
                    .font(mono ? .studioMono(11.5) : .studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions() }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    struct StatusLight: View {
        let light: Light

        var body: some View {
            ZStack {
                switch light {
                case .checking:
                    ProgressView().controlSize(.mini)
                case .done:
                    Circle().fill(StudioColors.ok)
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                case .todo:
                    Circle().strokeBorder(StudioColors.amber, lineWidth: 1.5)
                case .off:
                    Circle().strokeBorder(StudioColors.line3, lineWidth: 1.5)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityLabel(label)
        }

        private var label: String {
            switch light {
            case .checking: "Checking"
            case .done: "Done"
            case .todo: "To do"
            case .off: "Not needed"
            }
        }
    }
}

private extension SetupRow where Actions == EmptyView {
    init(light: Light, title: String, detail: String, mono: Bool = false) {
        self.init(light: light, title: title, detail: detail, mono: mono) { EmptyView() }
    }
}

// MARK: Claude Code

private struct ClaudeRows: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let claude = model.claude
        SetupRow(light: claude.checking ? .checking : claude.found ? .done : .todo,
                 title: "Claude Code",
                 detail: claude.checking ? "Looking on your PATH…" : installedDetail(claude),
                 mono: claude.found) {
            if !claude.checking && !claude.found {
                StudioButton(title: "Copy install command", height: 26) { model.copy(OnboardingModel.installCommand) }
                    .help(OnboardingModel.installCommand)
            }
        }
        SetupRow(light: claude.checking ? .checking : claude.signedIn ? .done : claude.found ? .todo : .off,
                 title: "Signed in",
                 detail: signedInDetail(claude))
        SetupRow(light: claude.checking ? .checking : claude.sessionsFolder ? .done : .off,
                 title: "Your sessions",
                 detail: claude.sessionsFolder ? "Glance follows ~/.claude/projects"
                     : "Appear here after your first Claude Code session")
        if !claude.checking && !(claude.found && claude.signedIn) {
            HStack {
                Spacer()
                StudioButton(title: "Check again", style: .secondary, height: 26) { model.checkClaude() }
            }
            .padding(.top, 10)
        }
    }

    private func installedDetail(_ claude: OnboardingModel.ClaudeStatus) -> String {
        guard let path = claude.path else { return "Not installed. Paste the command into any terminal." }
        let short = path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return [claude.version.map { "v\($0)" }, short].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private func signedInDetail(_ claude: OnboardingModel.ClaudeStatus) -> String {
        if claude.checking { return "Reading Claude Code's settings…" }
        if let account = claude.account { return account.isEmpty ? "Signed in" : account }
        return claude.found ? "Run claude once in a terminal to sign in." : "After Claude Code is installed."
    }
}

// MARK: Permissions

private struct PermissionRows: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        SetupRow(light: model.accessibility ? .done : .todo, title: "Accessibility",
                 detail: "Docks Glance beside other terminals; runs global shortcuts and hold-fn dictation.") {
            if !model.accessibility { StudioButton(title: "Allow", height: 26) { model.allowAccessibility() } }
        }
        SetupRow(light: model.microphone == .authorized ? .done : .todo, title: "Microphone",
                 detail: "For dictation, spoken questions and meeting notes.") {
            if model.microphone != .authorized {
                StudioButton(title: model.microphone == .notDetermined ? "Allow" : "Open Settings", height: 26) {
                    model.allowMicrophone()
                }
            }
        }
        if model.asksForCalendar {
            SetupRow(light: model.calendar == .allowed ? .done : .todo, title: "Calendar",
                     detail: "Nudges you when a meeting is about to start.") {
                if model.calendar != .allowed {
                    StudioButton(title: model.calendar == .notAsked ? "Allow" : "Open Settings", height: 26) {
                        model.allowCalendar()
                    }
                }
            }
        }
    }
}

// MARK: Voice

private struct VoicePicker: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 14) {
            if !settings.voices.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(settings.voices.prefix(8)) { voice in
                        VoiceChip(voice: voice, selected: voice.id == settings.selectedVoice.id,
                                  speaking: model.speaking && voice.id == settings.selectedVoice.id) {
                            model.choose(voice)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                StudioButton(title: model.greeted ? "Say it again" : "Say hello", icon: nil, style: .secondary,
                             busy: model.wakingVoice, height: 28) { model.greet() }
                Text(status)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .animation(.easeOut(duration: 0.16), value: status)
            }
        }
    }

    private var status: String {
        if model.wakingVoice { return "Waking the voice…" }
        if model.speaking { return "Speaking" }
        return model.greeted ? "More voices in Settings → Voice." : "Pick a voice to hear it."
    }
}

private struct VoiceChip: View {
    let voice: VoiceOption
    let selected: Bool
    let speaking: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(selected ? StudioColors.coral : StudioColors.line3)
                    .frame(width: 7, height: 7)
                    .scaleEffect(speaking ? 1.35 : 1)
                    .animation(speaking ? .easeInOut(duration: 0.5).repeatForever() : .easeOut(duration: 0.16),
                               value: speaking)
                VStack(alignment: .leading, spacing: 1) {
                    Text(voice.name).font(.studio(12.5, .semibold)).foregroundStyle(StudioColors.ink)
                    if !voice.detail.isEmpty {
                        Text(voice.detail).font(.studio(11)).foregroundStyle(StudioColors.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? StudioColors.selection : hovering ? StudioColors.hover : StudioColors.field))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel("\(voice.name) voice")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Accounts

private struct AccountRows: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var github = GitHubAccountModel.shared

    var body: some View {
        githubRow
        if model.cloudOffered {
            let user = CloudAccount.shared.user
            SetupRow(light: user == nil ? .todo : .done, title: "Glance account",
                     detail: user.map { _ in "Signed in" } ?? "Keeps your journal and settings across Macs.") {
                if user == nil { CloudSignInButtons(height: 26) { model.accountsChanged() } }
            }
        }
        if model.googleOffered {
            let email = GoogleAccount.shared.email
            SetupRow(light: email == nil ? .todo : .done, title: "Google Calendar",
                     detail: email ?? "Decline a meeting right from its nudge.") {
                if email == nil { StudioButton(title: "Sign in", height: 26) { model.signInToGoogle() } }
            }
        }
    }

    @ViewBuilder private var githubRow: some View {
        switch github.state {
        case .unknown:
            SetupRow(light: .checking, title: "GitHub", detail: "Looking for the GitHub CLI…")
        case .noGh:
            SetupRow(light: .todo, title: "GitHub", detail: "Needs the GitHub CLI: \(OnboardingModel.ghInstallCommand)") {
                StudioButton(title: "Copy", height: 26) { model.copy(OnboardingModel.ghInstallCommand) }
                StudioButton(title: "Check again", height: 26) { github.refresh(force: true) }
            }
        case .signedIn(let login):
            SetupRow(light: .done, title: "GitHub", detail: "@\(login)", mono: true)
        case .signedOut:
            switch github.signIn {
            case .starting:
                SetupRow(light: .checking, title: "GitHub", detail: "Starting the sign-in…")
            case .waiting(let prompt):
                SetupRow(light: .todo, title: "GitHub", detail: "Enter \(prompt.code) in the browser", mono: true) {
                    StudioButton(title: "Copy code & open", style: .primary, height: 26) { github.copyCodeAndOpen() }
                }
            case .failed(let message):
                SetupRow(light: .todo, title: "GitHub", detail: message) {
                    StudioButton(title: "Try again", height: 26) { github.startSignIn() }
                }
            case nil:
                SetupRow(light: .todo, title: "GitHub", detail: "For pull requests in Glance Studio.") {
                    StudioButton(title: "Sign in", height: 26) { github.startSignIn() }
                }
            }
        }
    }
}

// MARK: - The finish

private struct FinishCard: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(OnboardingModel.firstName.map { "You're set, \($0)." } ?? "You're set.")
                .font(.studio(23, .semibold))
                .tracking(-0.3)
                .foregroundStyle(StudioColors.ink)
            Text("Run claude in any tab. When it answers, Glance reads it to you and draws what it explains.")
                .font(.studio(13.5))
                .lineSpacing(3)
                .foregroundStyle(StudioColors.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    let done = model.flow.done.contains(step)
                    SetupRow(light: done ? .done : .off, title: name(step),
                             detail: done ? "Done" : later(step))
                }
            }
            .padding(.top, 16)
            HStack(spacing: 10) {
                StudioButton(title: "Back", style: .quiet) { model.back() }
                Spacer(minLength: 0)
                GlowPill(title: "Open Glance Studio", hint: "↩", height: 34) { model.liftOff() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
    }

    private func name(_ step: OnboardingStep) -> String {
        switch step {
        case .claude: "Claude Code"
        case .permissions: "Permissions"
        case .voice: "Voice"
        case .accounts: "Accounts"
        }
    }

    /// Where an unfinished step can be done later.
    private func later(_ step: OnboardingStep) -> String {
        switch step {
        case .claude: "Later: install it, then run claude in a tab"
        case .permissions: "Later: System Settings → Privacy & Security"
        case .voice: "Later: Settings → Voice"
        case .accounts: "Later: the Pull Requests side bar"
        }
    }
}
