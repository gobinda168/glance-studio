import AppKit
import GlanceCore
import SwiftUI

/// What the box under a line does: a review comment to GitHub, or a question to Claude.
enum ComposeMode: Equatable {
    case comment, ask
}

/// Comment | Ask Claude, in the line box's header (the Files page's Unified / Split look).
struct ComposeModePicker: View {
    @Binding var mode: ComposeMode
    let canAsk: Bool

    var body: some View {
        HStack(spacing: 0) {
            option(.comment, "Comment", enabled: true)
            option(.ask, "Ask Claude", enabled: canAsk)
                .help(canAsk ? "Ask Claude about these lines (⌘I)" : "Install Claude Code to ask Claude")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(StudioColors.field))
        .animation(.easeOut(duration: 0.24), value: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment or ask Claude")
    }

    private func option(_ value: ComposeMode, _ title: String, enabled: Bool) -> some View {
        let selected = mode == value
        return Button { mode = value } label: {
            Text(title)
                .font(.studio(11.5, selected ? .semibold : .medium))
                .foregroundStyle(selected ? StudioColors.ink : StudioColors.muted)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? StudioColors.solid : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Claude's answer box in a diff (spec, "The answer box"): its questions and streamed answers, what Claude is reading,
/// a follow-up field (Return sends), Stop while a turn runs, and ×.
struct DiffAskBox: View {
    let box: DiffAsks.Box
    let owner: String
    let openLink: (URL) -> Void
    @State private var followUp = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CoralDot(size: 11)
                Text("Claude").font(.studio(12, .semibold)).foregroundStyle(StudioColors.ink)
                Text(box.title).font(.studio(12)).foregroundStyle(StudioColors.muted)
                Spacer(minLength: 4)
                SmallIconButton(icon: .close, label: "Close") { DiffAsks.shared.close(box.id, owner: owner) }
            }
            ForEach(Array(box.turns.enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 6) {
                    Text(turn.question)
                        .font(.studio(13, .semibold))
                        .foregroundStyle(StudioColors.ink)
                        .textSelection(.enabled)
                    if !turn.answer.isEmpty {
                        StudioMarkdownView(markdown: turn.answer, size: 13, color: StudioColors.body, open: openLink)
                    }
                }
            }
            if box.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(box.tool ?? "Claude is thinking…").font(.studio(12)).foregroundStyle(StudioColors.muted)
                }
            }
            if let error = box.error {
                InlineError(message: error) { DiffAsks.shared.retry(box.id, owner: owner) }
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: $followUp)
                    .textFieldStyle(.plain)
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.ink)
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(box.running)
                if box.running {
                    StudioButton(title: "Stop", style: .quiet, height: 26) {
                        DiffAsks.shared.stopTurn(box.id, owner: owner)
                    }
                } else {
                    StudioButton(title: "Ask", hint: "↩",
                                 enabled: !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                 height: 26, action: send)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 720, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
        .onAppear { if box.turns.isEmpty { focused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude's answer about \(box.path), \(box.title)")
    }

    private var placeholder: String {
        guard box.turns.isEmpty else { return "Ask a follow-up" }
        return box.scope == .file ? "Ask about this file" : "Ask about these lines"
    }

    private func send() {
        let question = followUp
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        followUp = ""
        DiffAsks.shared.ask(box.id, owner: owner, question: question)
    }
}
