import Foundation
import GlanceCore

/// The capture tools (`todos`, `add_todo`, `notes`…) carried out on CaptureStore, for any session or the orb
/// assistant. `source` is who asked (a session's label, or "Glance"), shown with what they add.
@MainActor
enum CaptureToolRunner {
  static func run(_ call: ChannelCall, source: String) -> (JSONValue, Bool) {
    let store = CaptureStore.shared
    switch call {
    case .todos(let name, let includeDone):
      switch CaptureTools.group(named: name, in: store.groups) {
      case .failure(let failure): return (.string(failure.message), true)
      case .success(let group):
        return (CaptureTools.todoRows(store.todos, groups: store.groups, group: group, includeDone: includeDone), false)
      }
    case .addTodo(let text, let name, let notes):
      let group: UUID?
      switch CaptureTools.group(named: name, in: store.groups) {
      case .failure(let failure): return (.string(failure.message), true)
      case .success(let found): group = found
      }
      do {
        guard let id = try store.addTodo(text, source: source, group: group, notes: notes ?? "") else {
          return ("text is required.", true)
        }
        return (["id": .string(id.uuidString), "added": true], false)
      } catch {
        return (.string("Couldn't save the to-do: \(error.localizedDescription)"), true)
      }
    case .completeTodo(let text):
      switch CaptureTools.id(text, of: "to-do") {
      case .failure(let failure): return (.string(failure.message), true)
      case .success(let id):
        guard store.todo(id) != nil else { return (.string("No to-do with id \(text). Call todos for them."), true) }
        store.setStatus(id, .done)
        return (["id": .string(id.uuidString), "done": true], false)
      }
    case .notes(let query):
      return (CaptureTools.noteRows(store.notes, query: query), false)
    case .addNote(let title, let text):
      do {
        let id = try store.addNote(title: title, text: text, source: source)
        return (["id": .string(id.uuidString), "added": true], false)
      } catch {
        return (.string("Couldn't save the note: \(error.localizedDescription)"), true)
      }
    case .appendToNote(let text, let addition):
      switch CaptureTools.id(text, of: "note") {
      case .failure(let failure): return (.string(failure.message), true)
      case .success(let id):
        guard store.note(id) != nil else { return (.string("No note with id \(text). Call notes for them."), true) }
        do {
          try store.appendToNote(id, text: addition, source: source)
          return (["id": .string(id.uuidString), "appended": true], false)
        } catch {
          return (.string("Couldn't add to the note: \(error.localizedDescription)"), true)
        }
      }
    default:
      return ("Not a to-do or note tool.", true)
    }
  }
}
