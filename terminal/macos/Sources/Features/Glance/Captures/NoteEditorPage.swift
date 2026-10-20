import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// A note laid out like Eraser: the document on the left (Markdown rendered as it's typed, as on the PR pages) and its
/// diagrams on the right, each one Mermaid code with Claude's explanation under it. Document · Both · Diagrams picks
/// what shows. Claude draws a diagram from the note on request, redraws one, or fixes one Mermaid can't render.
struct NoteEditorPage: View {
    let noteID: UUID
    @ObservedObject private var captures = CaptureStore.shared
    @AppStorage("captures.noteLayout") private var layout = NoteLayout.both
    @State private var confirmDelete = false
    @State private var editor = MarkdownEditorHandle()

    var body: some View {
        if let note = captures.note(noteID) {
            VStack(spacing: 0) {
                toolbar(note)
                Rectangle().fill(StudioColors.line).frame(height: 1)
                switch layout {
                case .document:
                    NoteDocumentPane(noteID: noteID, editor: editor)
                case .diagrams:
                    NoteDiagramsPane(noteID: noteID)
                case .both:
                    HSplitView {
                        NoteDocumentPane(noteID: noteID, editor: editor)
                            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                        NoteDiagramsPane(noteID: noteID)
                            .frame(minWidth: 340, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                            .background(StudioColors.bar)
                    }
                }
            }
            .confirmationDialog("Delete “\(note.displayTitle)”?", isPresented: $confirmDelete) {
                Button("Delete Note", role: .destructive) {
                    captures.deleteNote(noteID)
                    CapturesNavigation.shared.show(.notes(nil))
                }
            } message: {
                Text("Its document and diagrams go too. This can't be undone.")
            }
        } else {
            NotesEmptyPage()
        }
    }

    private func toolbar(_ note: NoteDoc) -> some View {
        HStack(spacing: 12) {
            Text(note.updated.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                .font(.studio(11.5))
                .foregroundStyle(StudioColors.muted)
                .help("Last edited")
            if let source = note.source {
                Text("from \(source)").font(.studio(11.5)).foregroundStyle(StudioColors.muted)
            }
            Spacer(minLength: 8)
            if layout != .diagrams {
                Button { editor.toggleChecklist() } label: {
                    StudioIcon(.checklist, size: 16)
                        .foregroundStyle(StudioColors.body)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("To-do: turn the line into a checkbox, or add one")
                .accessibilityLabel("To-do")
            }
            SegmentedTabs(items: NoteLayout.allCases.map { SegmentItem(value: $0, title: $0.title, count: nil) },
                          selection: $layout)
            Menu {
                Button("Export as Markdown…") { captures.export(noteID) }
                Button("Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.markdown, forType: .string)
                }
                Divider()
                Button("Delete Note…", role: .destructive) { confirmDelete = true }
            } label: {
                StudioIcon(.more, size: 16)
                    .foregroundStyle(StudioColors.body)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
    }
}

enum NoteLayout: String, CaseIterable {
    case document, both, diagrams

    var title: String {
        switch self {
        case .document: "Document"
        case .both: "Both"
        case .diagrams: "Diagrams"
        }
    }
}

/// No note to show: the first one is a click away.
struct NotesEmptyPage: View {
    var body: some View {
        VStack(spacing: 14) {
            StudioIcon(.notes, size: 34).foregroundStyle(StudioColors.coral)
            Text("Notes with diagrams")
                .font(.studio(20, .bold))
                .foregroundStyle(StudioColors.ink)
            Text("Write on the left and ask Claude to draw it on the right, or select text anywhere and right-click → Ask Glance… to start a note from it.")
                .font(.studio(13))
                .foregroundStyle(StudioColors.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            StudioButton(title: "New note", icon: .plus, style: .primary) {
                let note = CaptureStore.shared.newNote()
                CapturesNavigation.shared.show(.notes(note.id))
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The document

/// The title as a page heading, and the body rendered as it's typed.
private struct NoteDocumentPane: View {
    let noteID: UUID
    let editor: MarkdownEditorHandle
    @ObservedObject private var captures = CaptureStore.shared

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Untitled", text: binding(\.title), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.studio(28, .bold))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1...3)
                    .padding(.horizontal, 14)
                    .accessibilityLabel("Title")
                LiveMarkdownEditor(placeholder: "Write, paste or think out loud. Markdown works: # headings, - lists, - [ ] to-dos, **bold**, `code`.",
                                   text: binding(\.body), minHeight: 360,
                                   background: StudioColors.background, preview: true,
                                   handle: editor) { NSWorkspace.shared.open($0) }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(StudioColors.background)
    }

    private func binding(_ path: WritableKeyPath<NoteDoc, String>) -> Binding<String> {
        Binding(get: { captures.note(noteID)?[keyPath: path] ?? "" },
                set: { value in captures.update(noteID) { $0[keyPath: path] = value } })
    }
}

// MARK: - The diagrams

/// Ask Claude for a diagram at the top, then the note's diagrams, newest first.
private struct NoteDiagramsPane: View {
    let noteID: UUID
    @ObservedObject private var captures = CaptureStore.shared
    @ObservedObject private var drawing = NoteDiagrams.shared
    @State private var ask = ""
    @FocusState private var askFocused: Bool

    var body: some View {
        let note = captures.note(noteID)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Caption("Diagrams")
                    Spacer(minLength: 0)
                    Button {
                        captures.update(noteID) {
                            $0.diagrams.insert(.init(title: "Untitled diagram", code: "flowchart TD\n  A[Start] --> B[Next]"),
                                               at: 0)
                        }
                    } label: {
                        Text("+ Blank").font(.studio(11.5, .medium)).foregroundStyle(StudioColors.muted)
                    }
                    .buttonStyle(.plain)
                    .help("A blank diagram to write as code")
                }
                askField
                if let working = drawing.working[noteID] {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(working).font(.studio(12.5)).foregroundStyle(StudioColors.body)
                        Spacer(minLength: 0)
                        Button("Stop") { drawing.cancel(noteID: noteID) }
                            .buttonStyle(.plain)
                            .font(.studio(12, .semibold))
                            .foregroundStyle(StudioColors.coralInk)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.tealFill))
                    .transition(.opacity)
                }
                if let failure = drawing.failures[noteID] {
                    InlineError(message: failure) { draw(ask) }
                }
                if let note, note.diagrams.isEmpty, drawing.working[noteID] == nil {
                    empty
                }
                ForEach(note?.diagrams ?? []) { diagram in
                    DiagramCard(noteID: noteID, diagram: diagram)
                }
            }
            .padding(18)
            .animation(.easeOut(duration: 0.2), value: drawing.working[noteID])
        }
    }

    private var askField: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(StudioColors.coralInk)
                .accessibilityHidden(true)
            TextField("Ask Claude to draw… e.g. the login flow as a sequence", text: $ask)
                .textFieldStyle(.plain)
                .font(.studio(13))
                .foregroundStyle(StudioColors.ink)
                .focused($askFocused)
                .onSubmit { draw(ask) }
                .accessibilityLabel("Ask Claude to draw a diagram")
            StudioButton(title: "Draw", style: .primary, busy: drawing.working[noteID] != nil,
                         enabled: drawing.working[noteID] == nil, height: 26) { draw(ask) }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(askFocused ? StudioColors.coral.opacity(0.6) : StudioColors.line))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Turn this note into a diagram")
                .font(.studio(14, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text("Claude reads the document and draws it, with an explanation. You can edit the diagram's code after.")
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)
            FlowRow(spacing: 6) {
                ForEach(NoteDiagramPrompt.suggestions, id: \.self) { suggestion in
                    Button { draw(suggestion) } label: {
                        Text(suggestion)
                            .font(.studio(12, .medium))
                            .foregroundStyle(StudioColors.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(StudioColors.chip))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StudioColors.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func draw(_ request: String) {
        guard drawing.working[noteID] == nil else { return }
        drawing.draw(noteID: noteID, request: request)
        ask = ""
    }
}

/// One diagram: its title, the drawing (or its code, Eraser's diagram-as-code), Mermaid's error with a fix, Claude's
/// explanation, and a field to have Claude change it.
private struct DiagramCard: View {
    let noteID: UUID
    let diagram: NoteDoc.Diagram
    @ObservedObject private var captures = CaptureStore.shared
    @ObservedObject private var drawing = NoteDiagrams.shared
    @State private var showCode = false
    @State private var renderError: String?
    @State private var changing = false
    @State private var change = ""

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(StudioColors.line).frame(height: 1)
                if showCode {
                    StudioTextEditor(placeholder: "flowchart TD\n  A --> B", text: binding(\.code), minHeight: 160,
                                     mono: true)
                        .background(StudioColors.field)
                    Rectangle().fill(StudioColors.line).frame(height: 1)
                }
                MermaidView(code: diagram.code) { renderError = $0 }
                    .opacity(renderError == nil ? 1 : 0.35)
                if let renderError {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        InlineError(message: "Mermaid can't draw this: \(renderError)")
                        StudioButton(title: "Fix with Claude", style: .secondary, height: 26) {
                            drawing.draw(noteID: noteID, request: "Fix it so it renders.", revising: diagram,
                                         renderError: renderError)
                        }
                        .fixedSize()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                if !diagram.explanation.isEmpty {
                    Rectangle().fill(StudioColors.line).frame(height: 1)
                    StudioMarkdownView(markdown: diagram.explanation, size: 12.5) { NSWorkspace.shared.open($0) }
                        .padding(14)
                }
                if changing {
                    Rectangle().fill(StudioColors.line).frame(height: 1)
                    HStack(spacing: 8) {
                        TextField("What should change? e.g. add the retry path", text: $change)
                            .textFieldStyle(.plain)
                            .font(.studio(12.5))
                            .onSubmit(redraw)
                        StudioButton(title: "Redraw", style: .primary, enabled: drawing.working[noteID] == nil,
                                     height: 26, action: redraw)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(StudioColors.tealInk).frame(width: 7, height: 7).accessibilityHidden(true)
            TextField("Diagram", text: binding(\.title))
                .textFieldStyle(.plain)
                .font(.studio(13, .semibold))
                .foregroundStyle(StudioColors.ink)
            Spacer(minLength: 4)
            Button { withAnimation(.easeOut(duration: 0.18)) { showCode.toggle() } } label: {
                Text(showCode ? "Hide code" : "Code")
                    .font(.studioMono(11))
                    .foregroundStyle(showCode ? StudioColors.coralInk : StudioColors.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(showCode ? StudioColors.selection : StudioColors.field))
            }
            .buttonStyle(.plain)
            .help("Edit the diagram as Mermaid code")
            Menu {
                Button("Change with Claude…") { changing = true }
                Button("Redraw from the Note") {
                    drawing.draw(noteID: noteID, request: diagram.prompt ?? "", revising: diagram)
                }
                Divider()
                Button("Copy Mermaid Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagram.code, forType: .string)
                }
                Divider()
                Button("Delete Diagram", role: .destructive) {
                    captures.update(noteID) { $0.diagrams.removeAll { $0.id == diagram.id } }
                }
            } label: {
                StudioIcon(.more, size: 14)
                    .foregroundStyle(StudioColors.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func redraw() {
        let text = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, drawing.working[noteID] == nil else { return }
        drawing.draw(noteID: noteID, request: text, revising: diagram)
        change = ""
        changing = false
    }

    private func binding(_ path: WritableKeyPath<NoteDoc.Diagram, String>) -> Binding<String> {
        Binding(get: { captures.note(noteID)?.diagrams.first { $0.id == diagram.id }?[keyPath: path] ?? "" },
                set: { value in
                    captures.update(noteID) { note in
                        guard let index = note.diagrams.firstIndex(where: { $0.id == diagram.id }) else { return }
                        note.diagrams[index][keyPath: path] = value
                    }
                })
    }
}
