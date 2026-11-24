import AppKit
import SwiftUI
import GlanceCore

/// The Glance view of a tab's Claude session, over the (still running) terminal: an optional rail of the other
/// sessions, the timeline with its header and composer, and a side panel. Layout and values from the signed-off
/// replica (design-system/glance/prototype/sessionview.css).
struct SessionView: View {
    /// Owned by the tab's controller, so it outlives Glance mode (the view is torn down whenever the tab shows its terminal).
    @ObservedObject var model: SessionViewModel
    @State private var showRail = false
    @State private var panelPref = true
    @State private var width: CGFloat = 1400

    private static let railMinWidth: CGFloat = 1240
    private static let panelMinWidth: CGFloat = 1100

    private var railVisible: Bool { showRail && width >= Self.railMinWidth }
    private var panelVisible: Bool { panelPref && width >= Self.panelMinWidth && hasPanel }
    /// A session has a panel, and so has a finished worktree's recap.
    private var hasPanel: Bool { model.link != nil || model.recap != nil }

    var body: some View {
        HStack(spacing: 0) {
            if railVisible {
                SessionRail(model: model)
                    .frame(width: 220)
                    .overlay(alignment: .trailing) { StudioColors.line2.frame(width: 1) }
            }
            VStack(spacing: 0) {
                SessionHeader(model: model, canShowRail: width >= Self.railMinWidth, showRail: $showRail,
                              canShowPanel: width >= Self.panelMinWidth && hasPanel, showPanel: $panelPref)
                content
            }
            .frame(maxWidth: .infinity)
            if panelVisible {
                SessionPanelView(model: model)
                    .frame(width: 300)
                    .background(StudioColors.bar)
                    .overlay(alignment: .leading) { StudioColors.line2.frame(width: 1) }
            }
        }
        .background(StudioColors.background)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in width = new }
        })
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .noClaude:
            StartState(model: model, title: "Start a Claude session",
                       message: model.queued.isEmpty
                           ? "Ask anything. Claude starts in \(model.folderName) with your message."
                           : "Claude hasn't started. Check the terminal.",
                       placeholder: "Ask Claude to…", startClaude: true)
        case .starting:
            StartState(model: model, title: "Starting Claude…",
                       message: "Type your first message now. It goes in as soon as Claude is ready.",
                       placeholder: "Ask Claude to…", spinner: true)
        case .ready:
            StartState(model: model, title: "What should Claude work on?",
                       message: "A new session in \(model.folderName)" + (model.branch.map { " on \($0)" } ?? "") + ".",
                       placeholder: "Ask Claude, or type / for commands")
        case .sent:
            StartState(model: model, title: "Claude is on it…",
                       message: "The conversation shows here as soon as Claude replies.",
                       placeholder: "Ask Claude, or type / for commands", spinner: true)
        case .recap:
            if let recap = model.recap { RecapView(model: model, recap: recap) }
        case .timeline:
            VStack(spacing: 0) {
                if model.newSession { NewSessionDivider(model: model).sessionColumn() }
                SessionTimelineView(model: model).sessionColumn()
                ComposerView(model: model).sessionColumn()
            }
        }
    }
}

extension View {
    /// The centre column: 720 wide at most, centred, 28 in from the edges.
    func sessionColumn() -> some View {
        padding(.horizontal, 28).frame(maxWidth: 720 + 56).frame(maxWidth: .infinity)
    }
}

// MARK: Header

private struct SessionHeader: View {
    @ObservedObject var model: SessionViewModel
    let canShowRail: Bool
    @Binding var showRail: Bool
    let canShowPanel: Bool
    @Binding var showPanel: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(model.phase == .recap ? (model.recap?.title ?? "Claude") : model.link == nil ? "Claude" : model.title)
                        .font(.studio(14, .semibold)).foregroundStyle(StudioColors.ink)
                        .lineLimit(1).truncationMode(.tail)
                    if model.phase == .timeline, StudioFeatures.shared.isOn(.commandCenter) {
                        HeaderProofPill(proof: model.proof).layoutPriority(1)
                    }
                }
                if model.cwd != nil {
                    HStack(spacing: 5) {
                        Text(model.folderName).font(.studio(11.5)).lineLimit(1)
                        if let branch = model.branch {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                            Text(branch).font(.studioMono(11)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .foregroundStyle(StudioColors.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if model.link != nil, !model.timeline.rows.isEmpty { LiveLine(live: model.timeline.live) }
            NewSessionMenu(model: model)
            if canShowRail {
                HeaderButton(symbol: "square.stack", label: "All sessions", on: showRail) { showRail.toggle() }
            }
            if canShowPanel {
                HeaderButton(symbol: "sidebar.right", label: "Session panel", on: showPanel) { showPanel.toggle() }
            }
        }
        .padding(.leading, 28).padding(.trailing, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { StudioColors.line2.frame(height: 1) }
    }
}

/// The proof verdict beside the title. Its own view so it redraws when the proof changes (the header watches the session).
private struct HeaderProofPill: View {
    @ObservedObject var proof: ProofModel
    var body: some View { ProofPillView(pill: proof.pill) }
}

private struct HeaderButton: View {
    let symbol: String
    let label: String
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
                .foregroundStyle(on || hovering ? StudioColors.ink : StudioColors.muted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering || on ? StudioColors.hover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// "Working · Bash" with a pulsing teal dot, or "Idle": the dot's shape is the cue, not only its colour.
private struct LiveLine: View {
    let live: SessionLive
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(working: live.working)
            Text(text).font(.studio(11.5, .medium)).foregroundStyle(live.working ? StudioColors.tealInk : StudioColors.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        guard live.working else { return "Idle" }
        return live.tool.map { "Working · \($0.name)" } ?? "Working"
    }
}

/// Teal and pulsing while Claude works, a muted dot otherwise; static with Reduce Motion.
private struct StatusDot: View {
    let working: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(working ? StudioColors.tealInk : StudioColors.muted.opacity(0.7))
            .frame(width: 8, height: 8)
            .background(
                Circle().stroke(StudioColors.tealInk.opacity(working && !reduceMotion && pulse ? 0 : 0.5), lineWidth: 2)
                    .scaleEffect(working && !reduceMotion && pulse ? 2 : 1)
            )
            .onAppear { restart() }
            .onChange(of: working) { restart() }
    }

    private func restart() {
        pulse = false
        guard working, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
    }
}

// MARK: Rail

private struct SessionRail: View {
    @ObservedObject var model: SessionViewModel
    /// Redraw when tabs, titles or Claude's status change.
    @ObservedObject private var rows = TabSidebarModel.shared.rowsChange

    var body: some View {
        let sessions = model.otherSessions()
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Sessions").font(.studio(11, .semibold)).foregroundStyle(StudioColors.muted)
                    Spacer()
                    Text("\(sessions.count + 1)").font(.studioMono(11, .medium)).foregroundStyle(StudioColors.muted)
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
                RailRow(title: model.link == nil ? "Claude" : model.title, branch: model.branch,
                        working: model.timeline.live.working, current: true) {}
                ForEach(sessions, id: \.surface) { other in
                    RailRow(title: other.title, branch: other.branch, working: other.working, current: false) { open(other) }
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 8)
        }
        .background(StudioColors.bar)
    }

    private func open(_ other: SessionViewModel.Other) {
        guard let window = other.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKey()
        if let target = GlanceMode.controller(window) { GlanceMode.set(true, in: target) }
    }
}

private struct RailRow: View {
    let title: String
    let branch: String?
    let working: Bool
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(working: working).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.studio(12.5, .medium)).foregroundStyle(StudioColors.ink)
                        .lineLimit(1).truncationMode(.tail)
                    if let branch {
                        Text(branch).font(.studioMono(11)).foregroundStyle(StudioColors.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(current ? StudioColors.selection : hovering ? StudioColors.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(working ? "working" : "idle")
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

// MARK: New session, start states

/// The header's new-session control: a new tab in this folder, or (in a conversation) a fresh one in this tab.
private struct NewSessionMenu: View {
    @ObservedObject var model: SessionViewModel
    @State private var hovering = false

    var body: some View {
        if model.phase == .timeline {
            Menu {
                Button("New Session in a New Tab") { model.newSessionTab() }
                Button("New Session in This Tab") { model.clearSession() }
                    .disabled(model.timeline.live.working)
            } label: {
                icon
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
            .help("New session")
            .accessibilityLabel("New session")
        } else {
            HeaderButton(symbol: "square.and.pencil", label: "New session in a new tab", on: false) { model.newSessionTab() }
        }
    }

    private var icon: some View {
        Image(systemName: "square.and.pencil").font(.system(size: 14))
            .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? StudioColors.hover : .clear))
    }
}

private struct NewSessionDivider: View {
    @ObservedObject var model: SessionViewModel

    var body: some View {
        Button { model.dismissNewSession() } label: {
            HStack(spacing: 10) {
                StudioColors.line.frame(height: 1)
                Text(label).font(.studio(11, .medium)).foregroundStyle(StudioColors.muted).fixedSize()
                StudioColors.line.frame(height: 1)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("New session. Dismiss")
    }

    private var label: String {
        guard let at = model.newSessionAt else { return "New session" }
        return "New session · " + at.formatted(date: .omitted, time: .shortened)
    }
}

/// A tab without a conversation yet: the orb, what's going on, and the composer, so the first message is typed here
/// (it starts Claude when there is none). Show Terminal under it for anything the terminal does better.
private struct StartState: View {
    @ObservedObject var model: SessionViewModel
    let title: String
    let message: String
    let placeholder: String
    var spinner = false
    /// Offers Start Claude (no message) beside Show Terminal.
    var startClaude = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(spacing: 0) {
                Circle()
                    .fill(RadialGradient(colors: [StudioColors.coralInk, StudioColors.coral, StudioColors.coral.opacity(0.7)],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 30))
                    .frame(width: 44, height: 44)
                    .shadow(color: StudioColors.coral.opacity(0.35), radius: 14)
                    .padding(.bottom, 20)
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    if spinner { ProgressView().controlSize(.small) }
                    Text(title).font(.studio(19, .bold)).foregroundStyle(StudioColors.ink)
                }
                .padding(.bottom, 8)
                Text(message).font(.studio(14)).lineSpacing(14 * 0.6 - 4).foregroundStyle(StudioColors.body)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 460)
            .padding(.bottom, 16)
            .accessibilityElement(children: .combine)
            ComposerView(model: model, placeholder: placeholder).sessionColumn()
            HStack(spacing: 8) {
                if startClaude {
                    Button("Start Claude without a message") { model.startClaude() }
                        .buttonStyle(EmptyButtonStyle(primary: false))
                }
                Button("Show Terminal") { model.showTerminal() }.buttonStyle(EmptyButtonStyle(primary: false))
            }
            Spacer(minLength: 40)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.studio(12.5, primary ? .semibold : .medium))
            .foregroundStyle(primary ? StudioColors.onCoral : StudioColors.ink)
            .padding(.horizontal, 12).frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(primary ? StudioColors.coral : StudioColors.chip))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(primary ? .clear : StudioColors.line, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
