import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// One meeting (spec 2026-10-09-meeting-notes-design.md). While it records: the clock, both channels' levels, the
/// model's download, problems, the notice to paste in the chat, Ask, and the transcript as it arrives. After: the
/// notes, the Q&A, the transcript with renamable speakers, and Copy Notes / Regenerate / Transcribe / Delete.
struct MeetingView: View {
    let record: MeetingRecord
    /// It's the recorder's meeting (recording or finishing).
    let current: Bool
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var library = MeetingNotesLibrary.shared
    @State private var window: NSWindow?
    @State private var confirmDelete = false
    @State private var noticeHidden = false
    @State private var copied: String?

    private var recording: Bool { current && recorder.isRecording }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if recording { live } else if current, case .finishing(let what) = recorder.phase {
                        progressLine(what)
                    }
                    if !current { problem }
                    if let summary = record.summary { MeetingNotesCard(summary: summary, record: record) }
                    MeetingAskBox(record: record, live: recording,
                                  busy: current ? recorder.asking : library.working.contains(record.id)) { question in
                        if current { recorder.ask(question) } else { library.ask(question, in: record.id) }
                    }
                    MeetingTranscriptView(record: record, live: recording, backlog: current ? recorder.backlog : 0,
                                          editable: !current)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: record.lines.count) {
                guard recording else { return }
                withAnimation(.easeOut(duration: 0.24)) { scroller.scrollTo("end", anchor: .bottom) }
            }
        }
        .background(WindowAccessor { window = $0 })
        .confirmationDialog("Delete “\(record.title)”?", isPresented: $confirmDelete) {
            Button("Delete Meeting", role: .destructive) {
                library.delete(record.id)
                MeetingsNavigation.shared.show(.start)
            }
        } message: {
            Text("Its transcript, notes and any kept audio are removed from this Mac.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                MeetingTitleField(record: record, editable: !current)
                Text(subtitle)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
            }
            Spacer(minLength: 0)
            if recording {
                StudioButton(title: "Stop", style: .primary) { recorder.stop() }
                    .help("Stop recording; the notes follow in a minute")
            } else if !current {
                StudioButton(title: copied == "notes" ? "Copied" : "Copy Notes", icon: .copy, style: .secondary,
                             enabled: !record.lines.isEmpty) { copy(MeetingMarkdown.notes(record, you: you), "notes") }
                    .help("Markdown for Slack, Confluence or an email")
                moreMenu
            }
        }
    }

    private var subtitle: String {
        var parts = [MeetingsFormat.long(record.start)]
        if !recording { parts.append(MeetingsFormat.length(record.duration())) }
        let speakers = record.speakers.count
        if speakers > 0 { parts.append("\(speakers) speaker\(speakers == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var moreMenu: some View {
        Menu {
            Button("Copy Transcript") { copy(MeetingTranscript.text(record, you: you), "transcript") }
                .disabled(record.lines.isEmpty)
            Button("Regenerate Notes") { library.regenerate(record.id) }
                .disabled(record.lines.isEmpty || library.working.contains(record.id) || recorder.isBusy)
            if record.hasAudio {
                Button("Transcribe Again") { recorder.transcribe(record) }
                    .disabled(recorder.isBusy)
                Button("Show Audio in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([library.audioFolder(record.id)])
                }
            }
            Divider()
            Button("Delete Meeting…", role: .destructive) { confirmDelete = true }
        } label: {
            StudioIcon(.chevronDown, size: 14)
                .foregroundStyle(StudioColors.ink)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line3))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
    }

    // MARK: Live

    private var live: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                HStack(spacing: 18) {
                    HStack(spacing: 8) {
                        RecordingDot()
                        Text(MeetingsFormat.clock(record.duration(now: context.date)))
                            .font(.studioMono(15, .medium))
                            .foregroundStyle(StudioColors.ink)
                            .monospacedDigit()
                    }
                    LevelMeter(label: "You", level: recorder.micLevel)
                    LevelMeter(label: "Call", level: recorder.callLevel)
                    Spacer(minLength: 0)
                }
            }
            modelLine
            if let problem = recorder.micProblem { banner(problem, settings: "Privacy_Microphone") }
            if let problem = recorder.callProblem { banner(problem, settings: "Privacy_ScreenCapture") }
            if !noticeHidden {
                HStack(spacing: 10) {
                    Text("Let people know you're taking notes.")
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.body)
                    Spacer(minLength: 0)
                    StudioButton(title: copied == "notice" ? "Copied" : "Copy Notice", style: .quiet, height: 26) {
                        copy(MeetingNotesPrompt.notice, "notice")
                    }
                    .help(MeetingNotesPrompt.notice)
                    StudioButton(title: "Hide", style: .quiet, height: 26) { noticeHidden = true }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.chip))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }

    @ViewBuilder private var modelLine: some View {
        switch recorder.model {
        case .downloading(let fraction, let what):
            VStack(alignment: .leading, spacing: 6) {
                Text("\(what) \(Int(fraction * 100))% · recording meanwhile")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(StudioColors.coral)
                    .frame(maxWidth: 320)
            }
        case .loading:
            progressLine("Loading the transcription model…")
        case .failed(let reason):
            HStack(spacing: 10) {
                Text("The transcription model didn't load: \(reason). Recording goes on; it's transcribed later.")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.danger)
                    .fixedSize(horizontal: false, vertical: true)
                StudioButton(title: "Retry", style: .secondary, height: 26) { recorder.retryModel() }
            }
        case .ready, .idle:
            EmptyView()
        }
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.studio(12.5)).foregroundStyle(StudioColors.muted)
        }
    }

    private func banner(_ text: String, settings pane: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StudioIcon(.alert, size: 15)
                .foregroundStyle(StudioColors.amber)
            Text(text)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            StudioButton(title: "Open Privacy Settings", style: .quiet, height: 26) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.chip))
    }

    // MARK: A saved meeting's problem

    @ViewBuilder private var problem: some View {
        if let problem = record.problem {
            HStack(alignment: .top, spacing: 10) {
                StudioIcon(.alert, size: 15)
                    .foregroundStyle(StudioColors.amber)
                Text(problem)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if record.status == .interrupted && record.hasAudio {
                    StudioButton(title: "Transcribe", style: .secondary, enabled: !recorder.isBusy, height: 26) {
                        recorder.transcribe(record)
                    }
                } else if record.summary == nil && !record.lines.isEmpty {
                    StudioButton(title: "Regenerate Notes", style: .secondary,
                                 busy: library.working.contains(record.id), height: 26) {
                        library.regenerate(record.id)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.chip))
        } else if library.working.contains(record.id) && record.summary == nil {
            progressLine("Claude is writing the notes…")
        }
    }

    // MARK: Helpers

    private var you: String { MeetingNotesWriter.you }

    private func copy(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == what { copied = nil } }
    }
}

/// The meeting's title; a saved meeting's can be renamed in place.
private struct MeetingTitleField: View {
    let record: MeetingRecord
    let editable: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editable {
                TextField("Title", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { MeetingNotesLibrary.shared.rename(record.id, title: text) }
                    .onChange(of: focused) { if !focused { MeetingNotesLibrary.shared.rename(record.id, title: text) } }
                    .onAppear { text = record.title }
                    .onChange(of: record.id) { text = record.title }
                    .help("Click to rename")
            } else {
                Text(record.title)
            }
        }
        .font(.studio(22, .bold))
        .tracking(-0.22)
        .foregroundStyle(StudioColors.ink)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A channel's level: five bars lit by loudness (−50…−10 dB), with its name.
struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        let db = 20 * log10(max(Double(level), 0.000_01))
        let lit = Int(((db + 50) / 40 * 5).rounded(.down))
        HStack(spacing: 6) {
            Text(label)
                .font(.studio(11.5, .medium))
                .foregroundStyle(StudioColors.muted)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(index < lit ? StudioColors.ok : StudioColors.line3)
                        .frame(width: 3, height: 6 + CGFloat(index) * 2)
                }
            }
            .frame(height: 14, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue(lit > 0 ? "hearing sound" : "quiet")
    }
}
