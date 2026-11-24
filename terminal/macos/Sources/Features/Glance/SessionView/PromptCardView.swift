import AppKit
import SwiftUI
import GlanceCore

/// What Claude is waiting on, as a card at the end of the timeline: the question, the change a permission approves,
/// and the dialog's numbered options as buttons. Replica: design-system/glance/prototype/sessionview.css (.gv-prompt).
struct PromptCardView: View {
    let prompt: PendingPrompt
    /// The answer was given (the owner keeps it, so a card the lazy timeline recreates still shows it).
    var answered = false
    let answer: (PromptAnswer) -> Void
    let showTerminal: () -> Void
    /// The session the number keys answer for, while the card is on screen.
    var model: SessionViewModel?

    @State private var showAllLines = false
    @StateObject private var keys = PromptKeyMonitor()

    private static let diffCap = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.studio(14, .semibold)).foregroundStyle(StudioColors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            PromptDetailView(detail: PromptDetail.of(prompt, session: model?.link?.sessionID), cap: Self.diffCap, showAll: $showAllLines)
            if PromptDetail.showsOnlyTheEnd(prompt, session: model?.link?.sessionID) {
                Text("This is only the end of something longer. To see all of it, use Answer in terminal.")
                    .font(.studio(12, .medium)).foregroundStyle(StudioColors.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4).padding(.top, 8)
            }
            if answered {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    Text("Answered").font(.studio(12.5, .medium))
                }
                .foregroundStyle(StudioColors.ok)
                .frame(minHeight: 28).padding(.leading, 4).padding(.top, 8)
                .accessibilityElement(children: .combine)
            } else if !prompt.screen.options.isEmpty {
                VStack(spacing: 4) {
                    ForEach(prompt.screen.options, id: \.number) { option in
                        OptionRow(option: option) { pick(option) }
                    }
                    if isMultiSelect {
                        Button { answer(.submit) } label: {
                            Text("Submit").font(.studio(13, .semibold)).foregroundStyle(StudioColors.onCoral)
                                .padding(.horizontal, 16).frame(minHeight: 34)
                                .background(RoundedRectangle(cornerRadius: 8).fill(StudioColors.coral))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 4)
                    }
                }
                .padding(.top, 12)
            }
            Button(action: showTerminal) {
                Text("Answer in terminal").font(.studio(12, .medium)).foregroundStyle(StudioColors.muted)
                    .padding(.horizontal, 4).frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietLink())
            .padding(.top, 6)
        }
        .padding(.top, 14).padding(.horizontal, 14).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(StudioColors.card))
        .overlay(alignment: .leading) {
            Rectangle().fill(StudioColors.amber).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioColors.amber.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .onAppear { if let model { keys.start(model: model) } }
        .onDisappear { keys.stop() }
    }

    private var isMultiSelect: Bool { prompt.screen.options.contains { $0.checked != nil } }

    private var title: String { BoardModel.promptTitle(prompt) }

    private func pick(_ option: PromptOption) { Self.pick(option, answer: answer, showTerminal: showTerminal) }

    /// A click or a number key on an option: a free-text one is typed in the terminal, a multi-select one toggles.
    static func pick(_ option: PromptOption, answer: (PromptAnswer) -> Void, showTerminal: () -> Void) {
        if PromptScreen.isFreeText(option.label) { showTerminal(); return }
        answer(option.checked != nil ? .toggle(option.number) : .option(option.number))
    }
}

/// The number keys for a prompt card: a local key monitor that lives only while the card is on screen (and goes with
/// the card), and takes a digit only when this session's composer has the keyboard and is empty. It reads the current
/// prompt at key time and holds the model weakly.
@MainActor
final class PromptKeyMonitor: ObservableObject {
    nonisolated(unsafe) private var token: Any?
    private weak var model: SessionViewModel?

    func start(model: SessionViewModel) {
        self.model = model
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

    /// True when the key was a prompt answer.
    private func handle(_ event: NSEvent) -> Bool {
        guard let model, let prompt = model.prompt, model.answeredCall != prompt.call.id,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let digit = event.characters.flatMap({ $0.count == 1 ? Int($0) : nil }), digit >= 1,
              let field = event.window?.firstResponder as? ComposerNSTextView,
              field.surfaceID == model.surface.uuidString, field.string.isEmpty, !field.hasMarkedText(),
              let option = prompt.screen.options.first(where: { $0.number == digit }) else { return false }
        PromptCardView.pick(option, answer: { model.answer($0) }, showTerminal: { model.showTerminal() })
        return true
    }
}

private struct OptionRow: View {
    let option: PromptOption
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let checked = option.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: 13))
                        .foregroundStyle(checked ? StudioColors.coralInk : StudioColors.muted)
                }
                Text("\(option.number)")
                    .font(.studioMono(11, .semibold)).foregroundStyle(StudioColors.body)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(StudioColors.chip))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(StudioColors.line3, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.studio(13, .medium)).foregroundStyle(StudioColors.ink)
                        .multilineTextAlignment(.leading)
                    if let note = option.note, !note.isEmpty {
                        Text(note).font(.studio(12)).foregroundStyle(StudioColors.muted).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? StudioColors.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(hovering ? StudioColors.line3 : StudioColors.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(option.number). \(option.label)")
    }
}

private struct QuietLink: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.underline(configuration.isPressed).opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: What a permission approves

/// The command or the change a permission approves, drawn the same on the Glance view's prompt card and the board's card.
/// Each says which detail it shows (`PromptDetail`).
struct PromptDetailView: View {
    let detail: PromptDetail
    let cap: Int
    @Binding var showAll: Bool
    var top: CGFloat = 12

    var body: some View {
        switch detail {
        case .change(let change):
            ChangeView(change: change, cap: cap, showAll: $showAll).padding(.top, top)
        case .dialog(let lines):
            Text(lines.joined(separator: "\n"))
                .font(.studioMono(12)).foregroundStyle(StudioColors.body)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(StudioColors.chip))
                .padding(.top, top)
        case .none:
            EmptyView()
        }
    }
}

private struct ChangeView: View {
    let change: PromptChange
    let cap: Int
    @Binding var showAll: Bool

    var body: some View {
        let added = change.lines.filter { $0.mark == .added }.count
        let removed = change.lines.filter { $0.mark == .removed }.count
        let shown = showAll ? change.lines : Array(change.lines.prefix(cap))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let path = change.path {
                    Text(path).font(.studioMono(12)).foregroundStyle(StudioColors.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text("+\(added)").font(.studioMono(12, .medium)).foregroundStyle(StudioColors.ok)
                Text("−\(removed)").font(.studioMono(12, .medium)).foregroundStyle(StudioColors.danger)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(sign(line.mark)).frame(width: 26)
                            .foregroundStyle(line.mark == .added ? StudioColors.ok
                                             : line.mark == .removed ? StudioColors.danger : StudioColors.muted)
                        Text(line.text.isEmpty ? " " : line.text).foregroundStyle(StudioColors.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(.studioMono(12))
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.mark == .added ? StudioColors.okFill
                                : line.mark == .removed ? StudioColors.dangerFill : Color.clear)
                }
                if change.lines.count > cap {
                    Button { showAll.toggle() } label: {
                        Text(showAll ? "Show fewer lines" : "Show all \(change.lines.count) lines")
                            .font(.studio(12, .medium)).foregroundStyle(StudioColors.coralInk)
                            .padding(.horizontal, 10).frame(minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(StudioColors.chip))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColors.line, lineWidth: 1))
            .textSelection(.enabled)
        }
    }

    private func sign(_ mark: DiffLine.Mark) -> String {
        switch mark {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }
}
