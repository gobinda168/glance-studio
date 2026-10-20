import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Claude's notes: the overview, then decisions, action items (the user's marked "You") and open questions.
struct MeetingNotesCard: View {
    let summary: MeetingSummary
    let record: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(summary.overview)
                .font(.studio(14))
                .foregroundStyle(StudioColors.ink)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !summary.decisions.isEmpty {
                section("Decisions") {
                    ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, decision in
                        bullet(decision)
                    }
                }
            }
            if !summary.actionItems.isEmpty {
                section("Action items") {
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            ActionBox()
                            (Text(item.owner.map { "\($0)  " } ?? "").font(.studio(13, .semibold))
                                + Text(item.task).font(.studio(13)))
                                .foregroundStyle(StudioColors.ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if item.mine {
                                Text("You")
                                    .font(.studio(10.5, .semibold))
                                    .foregroundStyle(StudioColors.onCoral)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(StudioColors.coral))
                                    .accessibilityLabel("Yours")
                            }
                        }
                    }
                }
            }
            if !summary.openQuestions.isEmpty {
                section("Open questions") {
                    ForEach(Array(summary.openQuestions.enumerated()), id: \.offset) { _, question in
                        bullet(question)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Caption(title)
            content()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().fill(StudioColors.muted).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            Text(text)
                .font(.studio(13))
                .foregroundStyle(StudioColors.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Ask about the meeting (MASTER's inline box): the questions so far with Claude's answers, and a field. Live, it's
/// about the transcript so far.
struct MeetingAskBox: View {
    let record: MeetingRecord
    let live: Bool
    let busy: Bool
    let ask: (String) -> Void
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(record.asks.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 5) {
                    Text("› \(item.question)")
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.muted)
                    Text(LocalizedStringKey(item.answer))
                        .font(.studio(13.5))
                        .foregroundStyle(StudioColors.ink)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(StudioColors.coral).frame(width: 3)
                }
            }
            HStack(alignment: .center, spacing: 10) {
                TextField(live ? "Ask about the meeting so far: what did they decide? what should I say?"
                               : "Ask about this meeting", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Claude is answering…")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                }
                StudioButton(title: "Ask", style: .secondary,
                             enabled: !busy && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 && !record.lines.isEmpty, action: send)
                    .help(record.lines.isEmpty ? "Ask once something has been transcribed" : "Ask Claude (↩)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? StudioColors.coral : StudioColors.line, lineWidth: 1))
        }
    }

    private func send() {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !busy, !record.lines.isEmpty else { return }
        ask(asked)
        question = ""
    }
}

/// The transcript: the speakers (a saved meeting's can be named), then each turn with its time.
struct MeetingTranscriptView: View {
    let record: MeetingRecord
    let live: Bool
    let backlog: Int
    /// Speakers can be renamed (not while the meeting is still being finished).
    let editable: Bool

    var body: some View {
        let turns = MeetingTranscript.merged(record.lines)
        let you = MeetingNotesWriter.you
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Caption("Transcript")
                if live && backlog > 1 {
                    Text("catching up · \(backlog) pieces")
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                }
                Spacer(minLength: 0)
                ForEach(record.speakers, id: \.self) { speaker in
                    SpeakerChip(record: record, speaker: speaker, editable: editable && speaker != TranscriptLine.you)
                }
            }
            if turns.isEmpty {
                Text(live ? "Words show here a few seconds after they're said." : "Nothing was transcribed.")
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.muted)
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(MeetingTranscript.clock(turn.start))
                            .font(.studioMono(11))
                            .foregroundStyle(StudioColors.muted)
                            .frame(width: 44, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name(of: turn.speaker, you: you))
                                .font(.studio(12.5, .semibold))
                                .foregroundStyle(StudioColors.ink)
                            Text(turn.text)
                                .font(.studio(13.5))
                                .foregroundStyle(StudioColors.body)
                                .lineSpacing(2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// A speaker's name; a click names them for this meeting ("Speaker 2" → "Priya").
private struct SpeakerChip: View {
    let record: MeetingRecord
    let speaker: String
    let editable: Bool
    @State private var editing = false
    @State private var name = ""

    var body: some View {
        let title = record.name(of: speaker, you: MeetingNotesWriter.you)
        Button {
            name = record.speakerNames[speaker] ?? ""
            editing = true
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.studio(11.5, .medium))
                    .foregroundStyle(StudioColors.ink)
                if editable {
                    StudioIcon(.pencil, size: 10)
                        .foregroundStyle(StudioColors.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(StudioColors.chip))
        }
        .buttonStyle(.plain)
        .disabled(!editable)
        .help(editable ? "Name this speaker" : title)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                TextField(record.name(of: speaker), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(save)
                StudioButton(title: "Save", style: .primary, height: 26, action: save)
            }
            .padding(12)
        }
    }

    private func save() {
        MeetingNotesLibrary.shared.renameSpeaker(speaker, to: name, in: record.id)
        editing = false
    }
}
