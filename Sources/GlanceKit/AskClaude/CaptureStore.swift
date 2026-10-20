import AppKit
import Combine
import UniformTypeIdentifiers
import GlanceCore

/// Ask Claude's to-dos (`todos.json`) and their groups (`groups.json`), and notes (`Notes/<id>.json`, one per note), in
/// `~/Library/Application Support/Glance/Captures`. A note's edits are written a moment after the typing stops.
@MainActor
public final class CaptureStore: ObservableObject {
  public static let shared = CaptureStore()

  @Published public private(set) var todos: [Captures.Todo]
  /// Work, Personal…, in the order the side bar lists them.
  @Published public private(set) var groups: [Captures.TodoGroup]
  /// Newest first.
  @Published public private(set) var notes: [NoteDoc]

  /// Studio: opens a note (nil: the notes) in the To-dos & Notes tab. Unset, there is nowhere to open it.
  public var onOpenNote: ((UUID?) -> Void)?

  private static var folderURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance/Captures", isDirectory: true)
  }
  private static var notesFolder: URL { folderURL.appendingPathComponent("Notes", isDirectory: true) }
  private var todosURL: URL { Self.folderURL.appendingPathComponent("todos.json") }
  private static var groupsURL: URL { folderURL.appendingPathComponent("groups.json") }
  private var pendingWrites: [UUID: DispatchWorkItem] = [:]
  private var pendingTodosWrite: DispatchWorkItem?

  private init() {
    let url = Self.folderURL.appendingPathComponent("todos.json")
    todos = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode([Captures.Todo].self, from: $0) } ?? []
    groups = (try? Data(contentsOf: Self.groupsURL))
      .flatMap { try? Self.decoder.decode([Captures.TodoGroup].self, from: $0) } ?? []
    notes = []
    notes = loadNotes()
    // The first time: Work and Personal to start with.
    if !FileManager.default.fileExists(atPath: Self.groupsURL.path) { try? saveGroups(Captures.TodoGroup.defaults()) }
  }

  public var openCount: Int { todos.filter { !$0.done }.count }

  /// Open to-dos in `group`; nil: all.
  public func openCount(in group: UUID?) -> Int { Captures.inGroup(todos, group).filter { !$0.done }.count }

  // MARK: To-dos

  public func todo(_ id: UUID) -> Captures.Todo? { todos.first { $0.id == id } }

  /// A new to-do at the top of `status`'s column (at its end with `atEnd`: a column's "+ Add"), in `group`.
  @discardableResult
  public func addTodo(_ text: String, source: String?, status: Captures.Todo.Status = .todo,
                      atEnd: Bool = false, group: UUID? = nil) throws -> UUID? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let order = atEnd ? Captures.endOrder(todos, status) : Captures.topOrder(todos, status)
    var todo = Captures.Todo(text: trimmed, status: status, source: source, order: order)
    todo.group = group
    try save(todos + [todo])
    return todo.id
  }

  /// Ticking: open → Done, Done → To do.
  public func toggle(_ todo: Captures.Todo) {
    guard let current = self.todo(todo.id) else { return }
    setStatus(current.id, Captures.toggled(current.status))
  }

  /// To the top of `status`'s column.
  public func setStatus(_ id: UUID, _ status: Captures.Todo.Status) {
    move(id, to: status, index: 0)
  }

  /// `index` counts only `group`'s cards when the board shows one group.
  public func move(_ id: UUID, to status: Captures.Todo.Status, index: Int, group: UUID? = nil) {
    try? save(Captures.moving(todos, id: id, to: status, index: index, group: group))
  }

  // MARK: Groups

  public func group(_ id: UUID?) -> Captures.TodoGroup? { id.flatMap { id in groups.first { $0.id == id } } }

  /// A new group at the end of the list; an empty name makes none.
  @discardableResult
  public func addGroup(_ name: String) -> UUID? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let group = Captures.TodoGroup(name: trimmed)
    try? saveGroups(groups + [group])
    return group.id
  }

  /// An empty name keeps the old one.
  public func renameGroup(_ id: UUID, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
    var next = groups
    next[index].name = trimmed
    try? saveGroups(next)
  }

  /// The group goes; its to-dos stay, in no group.
  public func deleteGroup(_ id: UUID) {
    try? saveGroups(groups.filter { $0.id != id })
    if todos.contains(where: { $0.group == id }) { try? save(Captures.ungrouping(todos, id)) }
  }

  /// Puts a to-do in `group` (nil: none).
  public func setGroup(_ id: UUID, _ group: UUID?) {
    guard let index = todos.firstIndex(where: { $0.id == id }), todos[index].group != group else { return }
    var next = todos
    next[index].group = group
    try? save(next)
  }

  private func saveGroups(_ next: [Captures.TodoGroup]) throws {
    try FileManager.default.createDirectory(at: Self.folderURL, withIntermediateDirectories: true)
    try Self.encoder.encode(next).write(to: Self.groupsURL, options: .atomic)
    groups = next
  }

  /// Changes a to-do in place (the details panel); the file follows once the edits pause.
  public func update(_ id: UUID, _ change: (inout Captures.Todo) -> Void) {
    guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
    var todo = todos[index]
    change(&todo)
    guard todo != todos[index] else { return }
    todos[index] = todo
    pendingTodosWrite?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.pendingTodosWrite = nil
        try? self.writeTodos(self.todos)
      }
    }
    pendingTodosWrite = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  public func remove(_ todo: Captures.Todo) {
    try? save(todos.filter { $0.id != todo.id })
  }

  private func save(_ next: [Captures.Todo]) throws {
    pendingTodosWrite?.cancel()
    pendingTodosWrite = nil
    try writeTodos(next)
    todos = next
  }

  private func writeTodos(_ list: [Captures.Todo]) throws {
    try FileManager.default.createDirectory(at: Self.folderURL, withIntermediateDirectories: true)
    try Self.encoder.encode(list).write(to: todosURL, options: .atomic)
  }

  // MARK: Notes

  public func note(_ id: UUID) -> NoteDoc? { notes.first { $0.id == id } }

  /// Ask Claude's "Add to notes": a new note with the drafted title and text.
  public func addNote(title: String, text: String, source: String?) throws {
    let note = NoteDoc(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                       body: text.trimmingCharacters(in: .whitespacesAndNewlines), source: source)
    try write(note)
    notes.insert(note, at: 0)
  }

  /// Quick note's Add to: `text` at the end of the note, under a time-and-app line. Written straight away, with any
  /// edits of the note's still waiting.
  public func appendToNote(_ id: UUID, text: String, source: String?) throws {
    guard let index = notes.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
    var note = notes[index]
    note.body = NoteDoc.appending(text, to: note.body, source: source)
    note.updated = Date()
    pendingWrites[id]?.cancel()
    pendingWrites[id] = nil
    try write(note)
    notes[index] = note
  }

  /// A blank note, first in the list.
  @discardableResult
  public func newNote() -> NoteDoc {
    let note = NoteDoc()
    notes.insert(note, at: 0)
    try? write(note)
    return note
  }

  /// Changes a note in place; the file follows once the edits pause.
  public func update(_ id: UUID, _ change: (inout NoteDoc) -> Void) {
    guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
    var note = notes[index]
    change(&note)
    guard note != notes[index] else { return }
    note.updated = Date()
    notes[index] = note
    pendingWrites[id]?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let current = self.note(id) else { return }
        self.pendingWrites[id] = nil
        try? self.write(current)
      }
    }
    pendingWrites[id] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  public func deleteNote(_ id: UUID) {
    pendingWrites[id]?.cancel()
    pendingWrites[id] = nil
    notes.removeAll { $0.id == id }
    try? FileManager.default.removeItem(at: Self.url(of: id))
  }

  /// Writes every note and the to-dos with edits still waiting (the app is quitting).
  public func flush() {
    for (id, work) in pendingWrites {
      work.cancel()
      if let note = note(id) { try? write(note) }
    }
    if let work = pendingTodosWrite {
      work.cancel()
      pendingTodosWrite = nil
      try? writeTodos(todos)
    }
    pendingWrites.removeAll()
  }

  /// Saves the note as Markdown (its diagrams as ```mermaid blocks) where the user picks.
  public func export(_ id: UUID) {
    guard let note = note(id) else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = note.displayTitle.replacingOccurrences(of: "/", with: "-") + ".md"
    panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? note.markdown.write(to: url, atomically: true, encoding: .utf8)
  }

  private static func url(of id: UUID) -> URL { notesFolder.appendingPathComponent("\(id.uuidString).json") }

  private func write(_ note: NoteDoc) throws {
    try FileManager.default.createDirectory(at: Self.notesFolder, withIntermediateDirectories: true)
    try Self.encoder.encode(note).write(to: Self.url(of: note.id), options: .atomic)
  }

  /// The notes on disk, newest first. The first time, the old single Notes.md becomes one note per entry and is
  /// renamed so it isn't read again.
  private func loadNotes() -> [NoteDoc] {
    let fm = FileManager.default
    let legacy = Self.folderURL.appendingPathComponent("Notes.md")
    if fm.fileExists(atPath: legacy.path), let text = try? String(contentsOf: legacy, encoding: .utf8) {
      for note in NoteDoc.imported(from: text) { try? write(note) }
      try? fm.moveItem(at: legacy, to: Self.folderURL.appendingPathComponent("Notes (imported).md"))
    }
    let files = (try? fm.contentsOfDirectory(at: Self.notesFolder, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }
      .compactMap { (try? Data(contentsOf: $0)).flatMap { try? Self.decoder.decode(NoteDoc.self, from: $0) } }
      .sorted { $0.created > $1.created }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
