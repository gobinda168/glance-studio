import AppKit
import SwiftUI
import GlanceCore

/// The composer's session controls: model, effort and permission mode, showing what the session runs with now and changing
/// it while it runs. Replica: design-system/glance/prototype/composerctl.css (.gv-cc, .gv-ccmenu).
struct ComposerControls: View {
    @ObservedObject var model: SessionViewModel
    /// A pick the terminal couldn't take: why, for the composer to show.
    let failed: (String) -> Void
    @State private var open: Control?
    @State private var highlighted = 0
    @StateObject private var keys = ControlKeys()

    enum Control: Hashable { case model, effort, mode }

    private static let footerInterval: Duration = .milliseconds(1500)

    /// Typed into a dialog, a command would answer it instead of running.
    private var blocked: Bool { model.prompt != nil }

    var body: some View {
        HStack(spacing: 2) {
            chip(.model, label: "Model", value: model.currentModel ?? "Default model", shortcut: "⇧⌘I")
            chip(.effort, label: "Effort", value: model.currentEffortTitle.map { "\($0) effort" } ?? "Effort", shortcut: nil)
            chip(.mode, label: "Permission mode",
                 value: model.switchingMode ? "Switching…" : model.currentMode?.chip ?? "Permissions", shortcut: "⇧⌘M")
        }
        .task(id: model.surface) {
            while !Task.isCancelled {
                model.readFooter()
                try? await Task.sleep(for: Self.footerInterval)
            }
        }
        .onAppear {
            keys.start(window: { [weak model] in model?.controller?.window }, open: show, isOpen: { open != nil },
                       move: move(by:), accept: { pick(highlighted) }, close: { open = nil })
        }
        .onDisappear { keys.stop() }
        .onChange(of: blocked) { if blocked { open = nil } }
    }

    private func chip(_ control: Control, label: String, value: String, shortcut: String?) -> some View {
        ControlChip(value: value, on: open == control) {
            if open == control { open = nil } else { show(control) }
        }
        .disabled(blocked || model.switchingMode)
        .help(blocked ? "Answer Claude first" : label + (shortcut.map { " (\($0))" } ?? ""))
        .accessibilityLabel("\(label): \(value)")
        .popover(isPresented: Binding(get: { open == control }, set: { if !$0, open == control { open = nil } }), arrowEdge: .top) {
            menu(control, label: label, shortcut: shortcut)
        }
    }

    private func show(_ control: Control) {
        guard !blocked, !model.switchingMode else { return }
        highlighted = rows(control).firstIndex(where: \.current) ?? 0
        open = control
    }

    private func move(by delta: Int) {
        guard let open else { return }
        let count = rows(open).count
        if count > 0 { highlighted = (highlighted + delta + count) % count }
    }

    private func pick(_ index: Int) {
        guard let open else { return }
        let all = rows(open)
        guard all.indices.contains(index), all[index].enabled else { return }
        self.open = nil
        all[index].action()
    }

    private func menu(_ control: Control, label: String, shortcut: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label.uppercased()).font(.studio(10.5, .semibold)).kerning(0.6)
                Spacer()
                if let shortcut { Text(shortcut).font(.studioMono(10.5)) }
            }
            .foregroundStyle(StudioColors.muted)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            ForEach(Array(rows(control).enumerated()), id: \.offset) { index, row in
                ControlRow(row: row, highlighted: index == highlighted) { pick(index) }
                    .onHover { if $0 { highlighted = index } }
            }
            Rectangle().fill(StudioColors.line2).frame(height: 1).padding(.top, 4)
            Text(control == .mode ? "Bypass permissions stays in the terminal." : "Claude Code also saves this as your default for new sessions.")
                .font(.studio(11.5)).foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 28).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 4)
        }
        .padding(6)
        .frame(width: control == .mode ? 332 : 276)
    }

    private func rows(_ control: Control) -> [ControlRow.Row] {
        switch control {
        case .model:
            let family = model.currentModel.flatMap(SessionPicks.family(of:))
            return SessionPicks.models.map { pick in
                .init(title: pick.title, summary: pick.command, mono: true, current: pick.alias == family, enabled: true) {
                    run(pick.command, unchanged: pick.alias == family)
                }
            }
        case .effort:
            let level = model.currentEffort
            return SessionPicks.efforts.map { pick in
                .init(title: pick.title, summary: pick.summary, mono: false, current: pick.level == level, enabled: true) {
                    run(pick.command, unchanged: pick.level == level)
                }
            }
        case .mode:
            return PermissionMode.menu.map { mode in
                let unavailable = mode == .auto && model.footer?.autoUnavailable == true
                return .init(title: mode.title, summary: unavailable ? "Not available for this model" : mode.summary, mono: false,
                             current: mode == model.currentMode, enabled: !unavailable) {
                    if mode != model.currentMode { model.switchMode(to: mode) }
                }
            }
        }
    }

    private func run(_ command: String, unchanged: Bool) {
        if !unchanged, !model.send(command) { failed(model.sendFailure ?? "This terminal is closed") }
    }
}

/// A control in the composer's bottom row.
private struct ControlChip: View {
    let value: String
    let on: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(value).font(.studio(12, .medium)).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioColors.muted)
            }
            .foregroundStyle(on || hovering ? StudioColors.ink : StudioColors.body)
            .padding(.leading, 8).padding(.trailing, 6)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(on || hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 && enabled }
    }
}

/// One choice in a control's menu.
private struct ControlRow: View {
    struct Row {
        let title: String
        let summary: String?
        let mono: Bool
        let current: Bool
        let enabled: Bool
        let action: () -> Void
    }

    let row: Row
    let highlighted: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioColors.coralInk)
                    .opacity(row.current ? 1 : 0)
                    .frame(width: 16)
                Text(row.title).font(.studio(12.5, .medium)).foregroundStyle(StudioColors.ink).fixedSize()
                Spacer(minLength: 8)
                if let summary = row.summary {
                    Text(summary).font(row.mono ? .studioMono(11) : .studio(11.5)).foregroundStyle(StudioColors.muted).lineLimit(1)
                }
            }
            .padding(.leading, 4).padding(.trailing, 8)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(highlighted && row.enabled ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
            .opacity(row.enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!row.enabled)
        .accessibilityAddTraits(row.current ? .isSelected : [])
    }
}

/// How full the session's context is: a ring and its number, so colour isn't the only cue.
struct ContextRing: View {
    let usage: SessionUsage

    var body: some View {
        let level = ContextLevel(percent: usage.contextPercent)
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(StudioColors.line3, lineWidth: 2.5)
                Circle().trim(from: 0, to: CGFloat(level.percent) / 100)
                    .stroke(level.word == nil ? StudioColors.tealInk : level.tone, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            Text("\(level.percent)%").font(.studioMono(11)).monospacedDigit()
                .foregroundStyle(level.word == nil ? StudioColors.muted : level.tone)
        }
        .padding(.horizontal, 4)
        .help("Context \(level.percent)% used")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(level.percent) percent used\(level.word.map { ", " + $0.lowercased() } ?? "")")
    }
}

/// The controls' keys: ⇧⌘I and ⇧⌘M from the composer, and the arrows, Return and Esc while a menu is open. The popover
/// doesn't take the keyboard, so they're watched here.
@MainActor
private final class ControlKeys: ObservableObject {
    nonisolated(unsafe) private var token: Any?
    private var window: (() -> NSWindow?)?
    private var open: ((ComposerControls.Control) -> Void)?
    private var isOpen: (() -> Bool)?
    private var move: ((Int) -> Void)?
    private var accept: (() -> Void)?
    private var close: (() -> Void)?

    func start(window: @escaping () -> NSWindow?, open: @escaping (ComposerControls.Control) -> Void, isOpen: @escaping () -> Bool, move: @escaping (Int) -> Void,
               accept: @escaping () -> Void, close: @escaping () -> Void) {
        self.window = window; self.open = open; self.isOpen = isOpen; self.move = move; self.accept = accept; self.close = close
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit { if let token { NSEvent.removeMonitor(token) } }

    /// True when the key was the controls'.
    private func handle(_ event: NSEvent) -> Bool {
        if isOpen?() == true {
            switch event.keyCode {
            case 125: move?(1)
            case 126: move?(-1)
            case 36, 76: accept?()
            case 53: close?()
            default: return false
            }
            return true
        }
        // Every Glance tab's composer stays mounted and watches too: only the one in the key event's window answers.
        guard let window = event.window, window === self.window?(), window.firstResponder is ComposerNSTextView,
              event.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command, .shift] else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "i": open?(.model)
        case "m": open?(.mode)
        default: return false
        }
        return true
    }
}
