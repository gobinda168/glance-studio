import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The To-dos & Notes page: the to-dos (board or list, with details), or a note in its document-and-diagrams editor.
struct CapturesPage: View {
    @ObservedObject private var captures = CaptureStore.shared
    @ObservedObject private var navigation = CapturesNavigation.shared

    var body: some View {
        switch navigation.page {
        case .todos:
            TodosPage()
        case .notes(let id):
            if let note = id.flatMap({ captures.note($0) }) ?? captures.notes.first {
                NoteEditorPage(noteID: note.id).id(note.id)
            } else {
                NotesEmptyPage()
            }
        }
    }
}
