import AppKit
import AVFoundation
import GlanceCore
import GlanceKit
import SwiftUI

/// Voice (spec 2026-10-08-settings-design.md, "Sections"): who reads Claude's replies aloud, the keys, the voices and
/// models, and the Mac voice. The words are the old Settings window's.
struct VoiceSettings: View {
    let model: SettingsModel
    @State private var macVoices: [AVSpeechSynthesisVoice] = []

    private static let providers: [SegmentItem<String>] =
        ProviderID.allCases.map { SegmentItem(value: $0.rawValue, title: $0.displayName, count: nil) } + [
            SegmentItem(value: NarrationVoice.kokoro.preference, title: "Glance Voice", count: nil),
            SegmentItem(value: NarrationVoice.mac.preference, title: "Mac voice", count: nil),
        ]

    var body: some View {
        SettingsGroup(title: "Narration") {
            SettingsRow(id: "voice.voice", name: "Voice", detail: voiceDetail, stacked: true) {
                SegmentedTabs(items: Self.providers,
                              selection: Binding(get: { model.narration.preference }, set: { model.setNarration($0) }))
            }
        }
        .onAppear { macVoices = MacVoices.english() }
        SettingsGroup(title: "Keys") {
            SettingsRow(id: "voice.elevenLabsKey", name: "ElevenLabs key",
                        detail: "Stored in your macOS Keychain. Used for dictation and, when ElevenLabs is the voice, "
                            + "for narration.",
                        stacked: true) {
                SettingsKeyField(model: model.elevenLabsKey)
            }
            if model.voiceProvider == .miniMax {
                SettingsRow(id: "voice.miniMaxKey", name: "MiniMax key",
                            detail: "Stored in your macOS Keychain. Used when MiniMax is the voice.", stacked: true) {
                    SettingsKeyField(model: model.miniMaxKey)
                }
            }
        }
        switch model.narration {
        case .cloud(let provider): cloud(provider)
        case .kokoro: kokoro
        case .mac: mac
        }
    }

    private var voiceDetail: String {
        switch model.narration {
        case .cloud(let id): "Uses the \(id.displayName) key below."
        case .kokoro: "Runs on this Mac: no key, no cost."
        case .mac: "The voices installed on this Mac: no key, no cost."
        }
    }

    // MARK: A cloud voice

    @ViewBuilder private func cloud(_ provider: ProviderID) -> some View {
        SettingsGroup(title: "\(provider.displayName) voices") {
            SettingsRow(id: "voice.list", name: "Voices", detail: "Click a voice to use it; ▶ plays it.", stacked: true) {
                VoiceList(model: model)
            }
            SettingsRow(id: "voice.model", name: "Model", detail: "Faster models answer sooner; the others read longer text "
                + "more steadily.") {
                SettingsMenu(label: "Model", title: modelTitle(provider),
                             options: provider.models.map { SegmentItem(value: $0.id, title: "\($0.name) · \($0.detail)", count: nil) },
                             selection: model.selectedModel) { model.selectModel($0) }
            }
            SettingsRow(id: "voice.preview", name: "Preview",
                        detail: ["Reads one sentence with this voice and model (about 60 characters).", model.usageText]
                            .compactMap { $0 }.joined(separator: "\n")) {
                StudioButton(title: "Preview", icon: .play, busy: model.previewState == .loading,
                             enabled: VoicePreview.canPreview(model), height: 28) { model.preview() }
                    .help("Preview uses ~60 characters")
            }
            if case .failed(let message) = model.previewState {
                InlineError(message: message).padding(.vertical, 10)
            }
            SettingsRow(id: "voice.fallback", name: "Glance Voice fallback",
                        detail: "Reads on this Mac when \(provider.displayName) can't.") {
                HStack(spacing: 8) {
                    SettingsMenu(label: "Glance Voice fallback", title: "\(model.kokoroVoice.name) · Glance Voice",
                                 options: KokoroVoices.all.map { SegmentItem(value: $0.id, title: "\($0.name) · Glance Voice", count: nil) },
                                 selection: model.kokoroVoice.id, width: 200) { model.selectKokoroFallback($0) }
                    SettingsIconButton(icon: .play, label: "Preview the Glance Voice") { model.previewKokoro(model.kokoroVoice) }
                }
            }
        }
    }

    private func modelTitle(_ provider: ProviderID) -> String {
        provider.models.first { $0.id == model.selectedModel }.map { "\($0.name) · \($0.detail)" } ?? model.selectedModel
    }

    // MARK: Kokoro

    @ViewBuilder private var kokoro: some View {
        SettingsGroup(title: "Glance Voice") {
            SettingsRow(id: "voice.list", name: "Voices", detail: "Runs on this Mac. The first preview also loads the model.",
                        stacked: true) {
                VoiceList(model: model)
            }
            if case .failed(let message) = model.previewState {
                InlineError(message: message).padding(.vertical, 10)
            }
        }
    }

    // MARK: The Mac voice

    @ViewBuilder private var mac: some View {
        SettingsGroup(title: "Mac voice") {
            SettingsRow(id: "voice.macVoice", name: "Mac voice", detail: "English voices on this Mac, best first.") {
                HStack(spacing: 8) {
                    SettingsMenu(label: "Mac voice", title: macVoiceTitle,
                                 options: macVoices.map { voice in
                                     SegmentItem(value: voice.identifier,
                                                 title: "\(voice.name) · \(MacVoices.qualityLabel(voice))", count: nil)
                                 },
                                 selection: model.macVoiceID, width: 200) { model.selectMacVoice($0) }
                    SettingsIconButton(icon: .play, label: "Preview the Mac voice") { model.previewMacVoice() }
                }
            }
            if !macVoices.contains(where: { $0.quality == .premium }) {
                SettingsRow(id: "voice.premium", name: "Premium voices",
                            detail: "No Premium Mac voice installed. System Settings → Accessibility → Spoken Content → "
                                + "System voice → Manage Voices… has better ones.") {
                    StudioButton(title: "Open", height: 26) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension")!)
                    }
                }
            }
        }
    }

    private var macVoiceTitle: String {
        macVoices.first { $0.identifier == model.macVoiceID }
            .map { "\($0.name) · \(MacVoices.qualityLabel($0))" } ?? "Choose a voice"
    }
}

/// The provider's voices (a cloud provider, Kokoro): the chosen one selected, ▶ on each; loading and failure above.
private struct VoiceList: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.voicesState {
            case .idle:
                EmptyView()
            case .loading:
                HStack(spacing: 6) {
                    Spinner(size: 13)
                    Text("Loading voices…").font(.studio(12)).foregroundStyle(StudioColors.muted)
                }
            case .failed(let message):
                InlineError(message: message)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(model.voices) { voice in
                            VoiceListRow(voice: voice, selected: voice.id == model.selectedVoice.id, hint: hint(voice),
                                         play: { model.playSample(voice) }, select: { model.selectVoice(voice) })
                                .id(voice.id)
                        }
                    }
                    .padding(4)
                }
                .onAppear { proxy.scrollTo(model.selectedVoice.id, anchor: .center) }
                .onChange(of: model.voices.count) { proxy.scrollTo(model.selectedVoice.id, anchor: .center) }
            }
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
        }
    }

    /// Kokoro runs locally, so its ▶ says nothing about cost; a cloud preview spends characters unless it's a hosted
    /// sample.
    private func hint(_ voice: VoiceOption) -> String {
        if model.narration == .kokoro { return "Play a sample" }
        return voice.sampleURL != nil ? "Play a sample (free)" : "Preview (about 60 characters)"
    }
}

private struct VoiceListRow: View {
    let voice: VoiceOption
    let selected: Bool
    let hint: String
    let play: () -> Void
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(selected ? StudioColors.coral : StudioColors.line3)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(voice.name)
                            .font(.studio(13, selected ? .semibold : .medium))
                            .foregroundStyle(StudioColors.ink)
                        if !voice.detail.isEmpty {
                            Text(voice.detail)
                                .font(.studio(11.5))
                                .foregroundStyle(StudioColors.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voice.detail.isEmpty ? voice.name : "\(voice.name), \(voice.detail)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            SettingsIconButton(icon: .play, label: hint, size: 26, action: play)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background { SettingsRowPlate(selected: selected, hovering: hovering) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// The Voice preview: Glance's orb, the sample sentence and the voice that reads it, and ▶ Preview. The orb thinks
/// while a preview loads and ripples while a sample plays.
struct VoicePreview: View {
    let model: SettingsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PreviewCard {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 14) {
                    SettingsOrb(mode: mode, size: 56)
                    words(.center)
                    button
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 18) {
                    SettingsOrb(mode: mode, size: 44)
                    VStack(alignment: .leading, spacing: 10) {
                        words(.leading)
                        button
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var mode: SettingsOrb.Mode {
        if model.previewState == .loading { return .thinking }
        return model.samplePlaying ? .speaking : .idle
    }

    private func words(_ alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text("“\(SettingsModel.previewSentence)”")
                .font(.studio(14))
                .foregroundStyle(StudioColors.body)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
            ZStack {
                Text(voiceName)
                    .font(.studio(11.5, .medium))
                    .foregroundStyle(StudioColors.muted)
                    .id(voiceName)
                    .transition(BlurSwap.transition(reduceMotion: reduceMotion))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .easeOut(duration: 0.24), value: voiceName)
    }

    private var button: some View {
        StudioButton(title: "Preview", icon: .play, style: .primary, busy: model.previewState == .loading,
                     enabled: Self.canPreview(model), height: 28, action: play)
            .help(Self.canPreview(model) ? "Read the sentence with this voice" : "Add the key first")
    }

    private var voiceName: String {
        switch model.narration {
        case .cloud(let id): "\(model.selectedVoice.name) · \(id.displayName)"
        case .kokoro: "\(model.kokoroVoice.name) · Glance Voice"
        case .mac: AVSpeechSynthesisVoice(identifier: model.macVoiceID ?? "").map { "\($0.name) · Mac voice" } ?? "Mac voice"
        }
    }

    private func play() {
        switch model.narration {
        case .cloud: model.preview()
        case .kokoro: model.previewKokoro(model.kokoroVoice)
        case .mac: model.previewMacVoice()
        }
    }

    /// A cloud voice needs its key; Kokoro and the Mac voice need nothing.
    static func canPreview(_ model: SettingsModel) -> Bool {
        switch model.voiceProvider {
        case .elevenLabs?: model.elevenLabsKey.hasSavedKey
        case .miniMax?: model.miniMaxKey.hasSavedKey
        case nil: true
        }
    }
}

/// Glance's orb (MASTER §7.2) for the Voice preview: coral and still while idle, teal and breathing while a preview
/// loads, coral with ripples while a sample plays. Still under Reduce Motion.
struct SettingsOrb: View {
    enum Mode { case idle, thinking, speaking }

    let mode: Mode
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Tones {
        let hi: Color, mid: Color, lo: Color
    }

    private static let coral = Tones(hi: rgb(0xFFB99E), mid: rgb(0xE8643C), lo: rgb(0x8E2F12))
    private static let teal = Tones(hi: rgb(0xA6E6E9), mid: rgb(0x2A8F94), lo: rgb(0x0F4448))

    var body: some View {
        let moving = !reduceMotion && mode != .idle
        let tones = mode == .thinking ? Self.teal : Self.coral
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let breath = mode == .thinking && moving ? 0.5 - 0.5 * cos(2 * .pi * time / 1.4) : 0
            ZStack {
                if mode == .speaking && moving {
                    ForEach(0..<3, id: \.self) { index in
                        let phase = (time / 1.8 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .strokeBorder(tones.mid.opacity(0.55 * (1 - phase)), lineWidth: 1.5)
                            .frame(width: size * (1 + 0.85 * phase), height: size * (1 + 0.85 * phase))
                    }
                }
                Circle()
                    .fill(RadialGradient(colors: [tones.mid.opacity(0.45), .clear], center: .center, startRadius: 0,
                                         endRadius: size * 0.9))
                    .frame(width: size * 1.8, height: size * 1.8)
                    .scaleEffect(1 - 0.08 * breath)
                    .opacity(1 - 0.45 * breath)
                Circle()
                    .fill(RadialGradient(colors: [tones.hi, tones.mid, tones.lo], center: UnitPoint(x: 0.36, y: 0.3),
                                         startRadius: 0, endRadius: size * 0.62))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                    .overlay(alignment: .topLeading) {
                        Ellipse()
                            .fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .center, startRadius: 0,
                                                 endRadius: size * 0.2))
                            .frame(width: size * 0.4, height: size * 0.26)
                            .offset(x: size * 0.18, y: size * 0.1)
                    }
                    .frame(width: size, height: size)
            }
            .frame(width: size * 1.9, height: size * 1.9)
        }
        .animation(.easeInOut(duration: 0.4), value: mode)
        .accessibilityHidden(true)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
