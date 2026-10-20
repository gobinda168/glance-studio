import Foundation
import GlanceCore

/// Claude drawing and redrawing a note's diagrams (`NoteDiagramPrompt`), one run per note at a time. A new diagram
/// goes first in the note's list; a revision replaces the diagram it revised.
@MainActor
public final class NoteDiagrams: ObservableObject {
  public static let shared = NoteDiagrams()

  /// Note id → what Claude is doing for it ("Drawing…"), while it runs.
  @Published public private(set) var working: [UUID: String] = [:]
  /// Note id → why the last run failed.
  @Published public private(set) var failures: [UUID: String] = [:]

  private var runs: [UUID: ClaudeOneShot.Run] = [:]

  private init() {}

  /// `revising`: the diagram to change (nil: a new one). `renderError`: Mermaid's error, to have Claude fix it.
  public func draw(noteID: UUID, request: String, revising: NoteDoc.Diagram? = nil, renderError: String? = nil) {
    guard let note = CaptureStore.shared.note(noteID) else { return }
    runs[noteID]?.cancel()
    failures[noteID] = nil
    working[noteID] = renderError != nil ? "Fixing the diagram…" : revising != nil ? "Redrawing…" : "Drawing…"
    let prompt = NoteDiagramPrompt.prompt(note: note, request: request, revising: revising, renderError: renderError)
    let ask = request.trimmingCharacters(in: .whitespacesAndNewlines)
    runs[noteID] = ClaudeOneShot.run(arguments: NoteDiagramPrompt.arguments(), prompt: prompt, folder: nil,
                                     timeout: NoteDiagramPrompt.timeout) { [weak self] result in
      guard let self else { return }
      self.runs[noteID] = nil
      self.working[noteID] = nil
      switch result {
      case .success(let text):
        guard let drawn = NoteDiagramPrompt.parse(text) else {
          self.failures[noteID] = "Claude's answer had no diagram in it. Try asking again."
          return
        }
        CaptureStore.shared.update(noteID) { note in
          if let revising, let index = note.diagrams.firstIndex(where: { $0.id == revising.id }) {
            note.diagrams[index].title = drawn.title
            note.diagrams[index].code = drawn.code
            note.diagrams[index].explanation = drawn.explanation
            if !ask.isEmpty { note.diagrams[index].prompt = ask }
          } else {
            note.diagrams.insert(.init(title: drawn.title, code: drawn.code, explanation: drawn.explanation,
                                       prompt: ask.isEmpty ? nil : ask), at: 0)
          }
        }
      case .failure(let failure):
        self.failures[noteID] = failure.message
      }
    }
  }

  public func cancel(noteID: UUID) {
    runs[noteID]?.cancel()
    runs[noteID] = nil
    working[noteID] = nil
  }

  public func dismissFailure(noteID: UUID) { failures[noteID] = nil }
}
