import Foundation

/// What Ask Claude saves inside Glance: a to-do list and a Markdown notes file. Nothing here leaves the Mac.
public enum Captures {
  public struct Todo: Codable, Equatable, Identifiable, Sendable {
    /// The board's columns.
    public enum Status: String, Codable, CaseIterable, Sendable {
      case todo, doing, done

      public var title: String {
        switch self {
        case .todo: "To do"
        case .doing: "Doing"
        case .done: "Done"
        }
      }
    }

    public enum Priority: String, Codable, CaseIterable, Sendable {
      case none, low, medium, high

      public var title: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
      }
    }

    /// One line of a to-do's checklist.
    public struct Subitem: Codable, Equatable, Identifiable, Sendable {
      public var id: UUID
      public var text: String
      public var done: Bool

      public init(id: UUID = UUID(), text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
      }
    }

    public var id: UUID
    public var text: String
    public var status: Status
    public var created: Date
    /// Where the text was selected ("Terminal", "Safari"), when known.
    public var source: String?
    /// Markdown.
    public var notes: String
    public var due: Date?
    public var priority: Priority
    public var tags: [String]
    /// A URL or a file path.
    public var link: String?
    public var subitems: [Subitem]
    /// Its place in its column, smallest first.
    public var order: Double
    /// The `TodoGroup` it is in (Work, Personal…); nil: none, so it shows only under All.
    public var group: UUID?

    public var done: Bool { status == .done }

    public var progress: (done: Int, total: Int) { (subitems.filter(\.done).count, subitems.count) }

    public init(id: UUID = UUID(), text: String, status: Status = .todo, created: Date = Date(), source: String? = nil,
                order: Double? = nil) {
      self.id = id
      self.text = text
      self.status = status
      self.created = created
      self.source = source
      notes = ""
      due = nil
      priority = .none
      tags = []
      link = nil
      subitems = []
      self.order = order ?? -created.timeIntervalSince1970
      group = nil
    }

    private enum CodingKeys: String, CodingKey {
      case id, text, status, done, created, source, notes, due, priority, tags, link, subitems, order, group
    }

    /// Files written before the board have `done` and none of the newer fields.
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(UUID.self, forKey: .id)
      text = try c.decode(String.self, forKey: .text)
      created = try c.decode(Date.self, forKey: .created)
      source = try c.decodeIfPresent(String.self, forKey: .source)
      if let status = try c.decodeIfPresent(Status.self, forKey: .status) {
        self.status = status
      } else {
        status = try c.decodeIfPresent(Bool.self, forKey: .done) == true ? .done : .todo
      }
      notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
      due = try c.decodeIfPresent(Date.self, forKey: .due)
      priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .none
      tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
      link = try c.decodeIfPresent(String.self, forKey: .link)
      subitems = try c.decodeIfPresent([Subitem].self, forKey: .subitems) ?? []
      order = try c.decodeIfPresent(Double.self, forKey: .order) ?? -created.timeIntervalSince1970
      group = try c.decodeIfPresent(UUID.self, forKey: .group)
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(text, forKey: .text)
      try c.encode(status, forKey: .status)
      try c.encode(created, forKey: .created)
      try c.encodeIfPresent(source, forKey: .source)
      try c.encode(notes, forKey: .notes)
      try c.encodeIfPresent(due, forKey: .due)
      try c.encode(priority, forKey: .priority)
      try c.encode(tags, forKey: .tags)
      try c.encodeIfPresent(link, forKey: .link)
      try c.encode(subitems, forKey: .subitems)
      try c.encode(order, forKey: .order)
      try c.encodeIfPresent(group, forKey: .group)
    }

    // MARK: Sub-items and tags

    public mutating func addSubitem(_ text: String) {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      subitems.append(Subitem(text: trimmed))
    }

    public mutating func toggleSubitem(_ id: UUID) {
      guard let index = subitems.firstIndex(where: { $0.id == id }) else { return }
      subitems[index].done.toggle()
    }

    /// An empty name keeps the old one.
    public mutating func renameSubitem(_ id: UUID, to text: String) {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, let index = subitems.firstIndex(where: { $0.id == id }) else { return }
      subitems[index].text = trimmed
    }

    public mutating func removeSubitem(_ id: UUID) {
      subitems.removeAll { $0.id == id }
    }

    public mutating func moveSubitems(fromOffsets source: IndexSet, toOffset destination: Int) {
      let moving = source.sorted().map { subitems[$0] }
      var rest = subitems.enumerated().filter { !source.contains($0.offset) }.map(\.element)
      let at = destination - source.filter { $0 < destination }.count
      rest.insert(contentsOf: moving, at: min(max(at, 0), rest.count))
      subitems = rest
    }

    public mutating func addTag(_ tag: String) {
      let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
      tags.append(trimmed)
    }

    public mutating func removeTag(_ tag: String) {
      tags.removeAll { $0 == tag }
    }
  }

  /// A named list of to-dos (Work, Personal). A to-do is in one group or none.
  public struct TodoGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
      self.id = id
      self.name = name
    }

    /// The groups a Mac starts with.
    public static func defaults() -> [TodoGroup] { [TodoGroup(name: "Work"), TodoGroup(name: "Personal")] }
  }

  /// The to-dos in `group`; nil: all of them.
  public static func inGroup(_ todos: [Todo], _ group: UUID?) -> [Todo] {
    guard let group else { return todos }
    return todos.filter { $0.group == group }
  }

  /// `todos` with no one left in `group` (it was deleted): they stay, under All.
  public static func ungrouping(_ todos: [Todo], _ group: UUID) -> [Todo] {
    todos.map { todo in
      var todo = todo
      if todo.group == group { todo.group = nil }
      return todo
    }
  }

  // MARK: The board

  /// A column's to-dos, in their order.
  public static func column(_ todos: [Todo], _ status: Todo.Status) -> [Todo] {
    todos.filter { $0.status == status }.sorted { $0.order < $1.order }
  }

  /// The order that puts a new card at the top of `status`'s column.
  public static func topOrder(_ todos: [Todo], _ status: Todo.Status) -> Double {
    (column(todos, status).first?.order).map { $0 - 1 } ?? 0
  }

  /// The order that puts a new card at the end of `status`'s column (a column's "+ Add").
  public static func endOrder(_ todos: [Todo], _ status: Todo.Status) -> Double {
    (column(todos, status).last?.order).map { $0 + 1 } ?? 0
  }

  /// `todos` with `id` moved to `status` at `index` (counted without it), its order between its new neighbours. With
  /// `group`, the index counts only that group's cards (the board shows one group).
  public static func moving(_ todos: [Todo], id: UUID, to status: Todo.Status, index: Int,
                            group: UUID? = nil) -> [Todo] {
    guard let from = todos.firstIndex(where: { $0.id == id }) else { return todos }
    let others = column(inGroup(todos, group), status).filter { $0.id != id }
    let at = min(max(index, 0), others.count)
    let before = at > 0 ? others[at - 1].order : nil
    let after = at < others.count ? others[at].order : nil
    let order: Double = switch (before, after) {
    case (nil, nil): 0
    case (nil, let after?): after - 1
    case (let before?, nil): before + 1
    case (let before?, let after?): (before + after) / 2
    }
    var next = todos
    next[from].status = status
    next[from].order = order
    return next
  }

  /// Ticking: anything open goes to Done; a done one goes back to To do.
  public static func toggled(_ status: Todo.Status) -> Todo.Status { status == .done ? .todo : .done }

  /// Due before today and not done.
  public static func isOverdue(_ todo: Todo, now: Date, calendar: Calendar = .current) -> Bool {
    guard let due = todo.due, !todo.done else { return false }
    return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
  }

  /// "Today", "Tomorrow", or the day ("Fri 17 Oct").
  public static func dueLabel(_ due: Date, now: Date, calendar: Calendar = .current) -> String {
    if calendar.isDate(due, inSameDayAs: now) { return "Today" }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: tomorrow) {
      return "Tomorrow"
    }
    var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
    style.timeZone = calendar.timeZone
    return due.formatted(style)
  }

  /// Every tag in use, once each, A to Z.
  public static func allTags(_ todos: [Todo]) -> [String] {
    Array(Set(todos.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  /// The list as shown: open to-dos newest first, then done ones.
  public static func ordered(_ todos: [Todo]) -> [Todo] {
    todos.filter { !$0.done }.sorted { $0.created > $1.created } + todos.filter(\.done).sorted { $0.created > $1.created }
  }

  /// One entry of the notes file: a heading with the date, the note, and where it is from.
  public static func noteEntry(title: String, text: String, source: String?, date: Date) -> String {
    let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var entry = "## \(heading.isEmpty ? "Note" : heading)\n"
    var meta = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
    if let source = source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty { meta += " · from \(source)" }
    entry += "_\(meta)_\n"
    if !body.isEmpty { entry += "\n\(body)\n" }
    return entry
  }

  /// The notes file with `entry` added at the top, under its title.
  public static func prepending(_ entry: String, to notes: String) -> String {
    let title = "# Notes\n\n"
    let existing = notes.hasPrefix(title) ? String(notes.dropFirst(title.count)) : notes
    let rest = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    return title + entry + (rest.isEmpty ? "" : "\n" + rest + "\n")
  }

  /// One saved note, as read back from the notes file.
  public struct NoteEntry: Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    /// The date and source line ("Mon, 13 Oct 2026 at 9:41 AM · from Safari").
    public let meta: String
    public let text: String

    public init(id: Int, title: String, meta: String, text: String) {
      self.id = id
      self.title = title
      self.meta = meta
      self.text = text
    }
  }

  /// The notes file's entries, newest first (as written): each "## " section is a title, an italic meta line and a body.
  public static func entries(in notes: String) -> [NoteEntry] {
    var result: [NoteEntry] = []
    var title: String?
    var lines: [String] = []
    func flush() {
      guard let title else { return }
      var body = lines
      var meta = ""
      if let first = body.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
         first.hasPrefix("_"), first.hasSuffix("_"), first.count > 1 {
        meta = String(first.dropFirst().dropLast())
        body.remove(at: body.firstIndex(of: first)!)
      }
      let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      result.append(NoteEntry(id: result.count, title: title, meta: meta, text: text))
    }
    for line in notes.components(separatedBy: "\n") {
      if line.hasPrefix("## ") {
        flush()
        title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        lines = []
      } else if title != nil {
        lines.append(line)
      }
    }
    flush()
    return result
  }
}
