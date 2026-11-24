import Foundation

/// What the capture tools (`todos`, `add_todo`, `notes`…) read back and how they find a group or an item. The app's
/// CaptureStore does the writing.
public enum CaptureTools {
  /// The most rows a list returns.
  static let todoLimit = 50
  static let noteLimit = 20
  static let previewLimit = 300

  /// The group a name means, in any case; nil for no name. An unknown name fails with the groups there are.
  public static func group(named name: String?, in groups: [Captures.TodoGroup]) -> Result<UUID?, ChannelTools.Failure> {
    guard let name else { return .success(nil) }
    if let group = groups.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
      return .success(group.id)
    }
    let known = groups.isEmpty ? "There are no groups." : "The groups are \(groups.map(\.name).joined(separator: ", "))."
    return .failure(.init("There's no to-do group named \(name). \(known)"))
  }

  /// To-dos in `group` (nil: all), open ones first, newest first.
  public static func todoRows(_ todos: [Captures.Todo], groups: [Captures.TodoGroup], group: UUID?,
                              includeDone: Bool) -> JSONValue {
    let names = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let rows = Captures.ordered(Captures.inGroup(todos, group))
      .filter { includeDone || !$0.done }
      .prefix(todoLimit)
      .map { todo -> JSONValue in
        ["id": .string(todo.id.uuidString), "text": .string(todo.text), "status": .string(todo.status.rawValue),
         "group": todo.group.flatMap { names[$0] }.map(JSONValue.string) ?? .null]
      }
    return .array(Array(rows))
  }

  /// Notes newest first; with a query, those whose title or text holds it (in any case).
  public static func noteRows(_ notes: [NoteDoc], query: String?) -> JSONValue {
    let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let dates = ISO8601DateFormatter()
    let rows = notes
      .filter { needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle)
        || $0.body.localizedCaseInsensitiveContains(needle) }
      .sorted { $0.updated > $1.updated }
      .prefix(noteLimit)
      .map { note -> JSONValue in
        ["id": .string(note.id.uuidString), "title": .string(note.displayTitle),
         "updated": .string(dates.string(from: note.updated)),
         "preview": .string(AskSelection.preview(note.body, limit: previewLimit))]
      }
    return .array(Array(rows))
  }

  /// An id the tools gave out. `what` is "to-do" or "note".
  public static func id(_ text: String, of what: String) -> Result<UUID, ChannelTools.Failure> {
    if let id = UUID(uuidString: text) { return .success(id) }
    let list = what == "note" ? "notes" : "todos"
    return .failure(.init("\(text) isn't a \(what) id; use the id that \(list)() gives."))
  }
}
