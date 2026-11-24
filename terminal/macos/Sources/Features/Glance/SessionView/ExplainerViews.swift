import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

// The native parts around an explainer (spec 2026-11-03-explainer-mode-design.md §4, §5, §7).
// Replica: design-system/glance/prototype/explainermode.css.

/// One action under a reply: quiet, 28pt, brighter on hover.
private struct ReplyActionStyle: ButtonStyle {
    var prominent = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.studio(12.5, .medium))
            .foregroundStyle(prominent ? StudioColors.coralInk : hovering ? StudioColors.ink : StudioColors.muted)
            .padding(.horizontal, 9).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? (prominent ? StudioColors.selection : StudioColors.hover) : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Copy, Listen and, with the feature on, Explain: under the last prose of each finished turn.
struct ReplyActions: View {
    let id: String
    let markdown: String
    var explainers: ExplainerModel?
    @ObservedObject private var voice = ReplyVoice.shared
    @State private var copied = false
    /// Bumped on each copy, so an older "Copied" reset can't clear a newer one.
    @State private var copyCount = 0

    private var reading: Bool { voice.speaking == id }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                copied = true
                copyCount += 1
                let count = copyCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copyCount == count { copied = false } }
            } label: {
                HStack(spacing: 6) {
                    StudioIcon(copied ? .check : .copy, size: 13)
                    Text(copied ? "Copied" : "Copy")
                }
            }
            .buttonStyle(ReplyActionStyle())
            .help("Copy this reply as markdown")
            Button { voice.toggle(id: id, markdown: markdown) } label: {
                HStack(spacing: 6) {
                    StudioIcon(reading ? .pause : .speaker, size: 13)
                    Text(reading ? "Stop" : "Listen")
                }
            }
            .buttonStyle(ReplyActionStyle())
            .help(reading ? "Stop reading this reply" : "Read this reply aloud")
            if let explainers {
                Button { explainers.explain(id) } label: {
                    HStack(spacing: 6) {
                        StudioIcon(.play, size: 13)
                        Text("Explain")
                    }
                }
                .buttonStyle(ReplyActionStyle(prominent: true))
                .help("Turn this reply into a page with pictures and voice")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, -9)
    }
}

/// A finished reply: its markdown, or its explainer when one shows, with what's happening between the two.
struct ExplainableReply<Prose: View>: View {
    let id: String
    let markdown: String
    @ObservedObject var explainers: ExplainerModel
    @ViewBuilder let prose: () -> Prose

    var body: some View {
        let state = explainers.replies[id]
        VStack(alignment: .leading, spacing: 8) {
            if case .ready(let page) = state, explainers.showsPage(id) {
                tabs(page: true)
                ExplainerPageBlock(id: id, page: page, explainers: explainers)
            } else {
                if case .ready = state, explainers.chosen[id] == false { tabs(page: false) }
                prose()
                switch state {
                case .writing(let answer):
                    WritingLine(answer: answer)
                case .failed(let message):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(StudioColors.danger)
                        Text("Couldn't make an explainer").font(.studio(12.5, .medium)).foregroundStyle(StudioColors.body)
                            .help(message)
                        Button("Retry") { explainers.explain(id) }
                            .buttonStyle(ReplyActionStyle(prominent: true))
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 28)
                default:
                    if case .ready = state, explainers.chosen[id] == false {
                        ReplyActions(id: id, markdown: markdown)
                    } else {
                        ReplyActions(id: id, markdown: markdown, explainers: explainers)
                    }
                }
            }
        }
    }

    private func tabs(page: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach([true, false], id: \.self) { isPage in
                Button { explainers.choose(id, page: isPage) } label: {
                    Text(isPage ? "Explainer" : "Reply")
                        .font(.studio(12.5, .medium))
                        .foregroundStyle(isPage == page ? StudioColors.ink : StudioColors.muted)
                        .padding(.horizontal, 11).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isPage == page ? StudioColors.hover : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isPage == page ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
        .padding(.bottom, 6)
    }
}

/// While the page is being written the reply stays readable; the answer sentence shows as soon as it closes.
private struct WritingLine: View {
    let answer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PulseDot()
                Text("Writing the explainer").font(.studio(12.5, .medium)).foregroundStyle(StudioColors.muted)
            }
            .frame(minHeight: 28)
            if let answer {
                Text(answer).font(.studio(15.5, .medium)).foregroundStyle(StudioColors.ink).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Facts, then the page at its reported height. A page out of the live set waits as a placeholder of the same height.
private struct ExplainerPageBlock: View {
    let id: String
    let page: ExplainerPage
    @ObservedObject var explainers: ExplainerModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let facts = explainers.facts(id), !facts.isEmpty { ExplainerFactsStrip(facts: facts) }
            Group {
                if explainers.live.contains(id), let key = explainers.key(id) {
                    ExplainerPageView(key: key, page: page, dark: colorScheme == .dark,
                                      onMessage: { [weak explainers] message in explainers?.received(message, reply: id, page: page) },
                                      onUnavailable: { [weak explainers] reason in explainers?.pageCantShow(id, reason: reason) })
                } else {
                    Color.clear
                }
            }
            .frame(height: explainers.height(id, page: page))
            .accessibilityLabel(page.answer)
            .padding(.bottom, 52) // The voice bar sits over the end of the page.
        }
        .onAppear { explainers.appeared(id) }
        .onDisappear { explainers.disappeared(id) }
    }
}

/// What Glance saw for itself, from the transcript and the proof record. Claude doesn't write these, so they are what to
/// trust if a page simplifies.
private struct ExplainerFactsStrip: View {
    let facts: ExplainerFacts

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { content }
            VStack(alignment: .leading, spacing: 6) { content }
        }
        .font(.studio(12.5))
        .foregroundStyle(StudioColors.body)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        Text("Seen by Glance").font(.studio(11.5, .medium)).foregroundStyle(StudioColors.muted)
        if facts.files > 0 {
            HStack(spacing: 5) {
                Text("\(facts.files) \(facts.files == 1 ? "file" : "files")")
                Text("+\(facts.added)").font(.studioMono(12, .medium)).foregroundStyle(StudioColors.ok)
                Text("−\(facts.removed)").font(.studioMono(12, .medium)).foregroundStyle(StudioColors.danger)
            }
        }
        if facts.commands > 0 {
            Text("\(facts.commands) \(facts.commands == 1 ? "command" : "commands")"
                + (facts.failedCommands > 0 ? ", \(facts.failedCommands) failed" : ""))
                .foregroundStyle(facts.failedCommands > 0 ? StudioColors.amber : StudioColors.body)
        }
        ForEach(Array(facts.checks.enumerated()), id: \.offset) { _, check in
            HStack(spacing: 4) {
                Image(systemName: check.passed ? "checkmark" : "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(check.passed ? StudioColors.ok : StudioColors.danger)
                Text("\(check.name) \(check.passed ? "passed" : "failed")")
            }
        }
    }
}

/// A turn's steps while its explainer shows: one line that opens to them.
struct ExplainerStepsLine: View {
    let line: ExplainerStepsFold.Line
    @ObservedObject var explainers: ExplainerModel

    var body: some View {
        Button { explainers.toggleSteps(line.reply) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(line.open ? 90 : 0))
                Text("\(line.count) \(line.count == 1 ? "step" : "steps")").font(.studio(12.5, .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(StudioColors.muted)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(line.open ? "expanded" : "collapsed")
    }
}

/// Stays in reach at the bottom of the timeline while the page scrolls under it.
struct ExplainerVoiceBar: View {
    @ObservedObject var explainers: ExplainerModel
    let reply: String
    let page: ExplainerPage
    @ObservedObject private var player = ExplainerVoicePlayer.shared

    private var mine: ExplainerVoicePlayer.Playback? {
        guard let current = player.current, current.page == explainers.key(reply) else { return nil }
        return current
    }

    private var unavailable: Bool { player.unavailablePage != nil && player.unavailablePage == explainers.key(reply) }
    private var beat: Int { mine?.beat ?? 0 }

    var body: some View {
        HStack(spacing: 8) {
            barButton(mine?.playing == true ? "pause.fill" : "play.fill", label: mine?.playing == true ? "Pause" : "Play") {
                if mine != nil { player.playPause() } else { explainers.play(reply, page: page) }
            }
            ExplainerOrb(active: mine?.playing == true)
            Group {
                if unavailable {
                    Text("The voice isn't available").foregroundStyle(StudioColors.muted)
                } else if page.beats.indices.contains(beat) {
                    Text("\(beat + 1) of \(page.beats.count) · \(page.beats[beat].title)")
                }
            }
            .font(.studio(13, .medium)).foregroundStyle(StudioColors.ink)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(page.beats.indices, id: \.self) { index in
                    Button { explainers.play(reply, page: page, from: index) } label: {
                        Circle()
                            .fill(mine != nil && index == beat ? StudioColors.coral : mine != nil && index < beat ? StudioColors.muted : StudioColors.line3)
                            .frame(width: 7, height: 7)
                            .frame(width: 18, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play from \(page.beats[index].title)")
                }
            }
            Button {
                player.setSpeed(player.speed == 1 ? 1.25 : player.speed == 1.25 ? 1.5 : 1)
            } label: {
                Text(player.speed == 1 ? "1×" : player.speed == 1.25 ? "1.25×" : "1.5×")
                    .font(.studioMono(11.5, .medium)).foregroundStyle(StudioColors.muted)
                    .frame(minWidth: 30, minHeight: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speed")
            barButton(player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: player.muted ? "Unmute" : "Mute") { player.toggleMute() }
        }
        .padding(.leading, 6).padding(.trailing, 10)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.solid))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(StudioColors.line3, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(StudioColors.ink)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A small coral orb that moves with the voice; still with Reduce Motion, or when nothing is playing.
private struct ExplainerOrb: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if active, !reduceMotion {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in orb(level: ExplainerVoicePlayer.shared.level) }
        } else {
            orb(level: 0)
        }
    }

    private func orb(level: Double) -> some View {
        ZStack {
            Circle().fill(StudioColors.coral.opacity(0.2 + 0.35 * level)).scaleEffect(1.25 + 0.5 * level)
            CoralDot(size: 14).scaleEffect(1 + 0.18 * level)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

// MARK: The side bar

struct ExplainerModeSummary: View {
    @ObservedObject var explainers: ExplainerModel

    var body: some View {
        Text(explainers.modeOn ? "On" : "Off").foregroundStyle(explainers.modeOn ? StudioColors.coralInk : StudioColors.muted)
    }
}

struct ExplainerModeBody: View {
    @ObservedObject var explainers: ExplainerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { explainers.modeOn }, set: { explainers.setMode($0) })) {
                Text("Explain every reply").font(.studio(13, .medium)).foregroundStyle(StudioColors.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch).controlSize(.small)
            Text("Each new reply becomes a page with pictures and voice. Uses extra tokens per reply; short replies are only read aloud.")
                .font(.studio(12.5)).foregroundStyle(StudioColors.muted).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
