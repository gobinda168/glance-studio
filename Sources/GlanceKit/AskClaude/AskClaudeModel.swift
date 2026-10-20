import AppKit
import Combine
import GlanceCore

/// One Ask Claude panel's state: the selection, Claude's read of it, the drafts the user edits, and what became of each.
@MainActor
final class AskClaudeModel: ObservableObject {
  enum Phase: Equatable { case thinking, ready, failed(String) }

  /// What happened when a draft was saved.
  enum Outcome: Equatable {
    case saved(String, url: URL?)
    case failed(String)
  }

  enum LibraryTab: String, CaseIterable { case todos = "To-dos", notes = "Notes" }

  enum ProjectsState: Equatable { case idle, loading, ready, failed(String) }

  @Published private(set) var selection = ""
  @Published private(set) var source: String?
  @Published private(set) var phase = Phase.thinking
  /// Claude's answer; the question it answers when the user asked one.
  @Published private(set) var answer = ""
  @Published private(set) var asked: String?
  @Published private(set) var recommended: AskSelection.Kind?
  @Published var kind = AskSelection.Kind.todo
  @Published var question = ""

  @Published var ticketTitle = ""
  @Published var ticketDescription = ""
  @Published var todoText = ""
  @Published var noteTitle = ""
  @Published var noteText = ""

  @Published private(set) var outcomes: [AskSelection.Kind: Outcome] = [:]
  @Published private(set) var saving: Set<AskSelection.Kind> = []
  /// The saved to-dos or notes, shown instead of a selection.
  @Published var library: LibraryTab?

  // The ticket's destination: Jira sites Glance is signed in to.
  @Published private(set) var trackers: [Tracker] = []
  @Published var trackerID: String? {
    didSet { if trackerID != oldValue { loadProjects() } }
  }
  @Published private(set) var projects: [JiraREST.Project] = []
  @Published private(set) var projectsState = ProjectsState.idle
  @Published var projectKey: String? {
    didSet {
      guard let trackerID, let projectKey, projectKey != oldValue else { return }
      Self.defaults.set(projectKey, forKey: Self.projectDefault(trackerID))
    }
  }

  private var run: ClaudeOneShot.Run?
  private var projectsTask: Task<Void, Never>?
  private var generation = 0
  private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard

  private static func projectDefault(_ tracker: String) -> String { "askClaude.project.\(tracker)" }

  var tracker: Tracker? { trackers.first { $0.server == trackerID } }

  var siteName: String {
    guard let tracker else { return "Jira" }
    return tracker.siteName ?? tracker.site ?? "Jira"
  }

  var canSaveTicket: Bool {
    guard tracker != nil, projectKey != nil, !ticketTitle.trimmed.isEmpty, !saving.contains(.ticket) else { return false }
    if case .saved? = outcomes[.ticket] { return false }
    return true
  }

  /// The saved to-dos and notes with no selection (File menu): nothing is sent to Claude.
  func openLibrary(_ tab: LibraryTab) {
    cancel()
    selection = ""
    source = nil
    library = tab
  }

  var hasSelection: Bool { !selection.isEmpty }

  // MARK: Asking Claude

  /// A new selection: the panel starts over and Claude reads it.
  func start(selection: String, source: String?) {
    cancel()
    self.selection = selection
    self.source = source
    question = ""
    asked = nil
    outcomes = [:]
    library = nil
    refreshTrackers()
    begin(question: nil)
  }

  /// The question typed in the footer: Claude answers it and drafts again.
  func ask() {
    let text = question.trimmed
    guard !text.isEmpty, phase != .thinking else { return }
    asked = text
    question = ""
    begin(question: text)
  }

  func retry() { begin(question: asked) }

  func cancel() {
    run?.cancel()
    run = nil
    projectsTask?.cancel()
  }

  private func begin(question: String?) {
    run?.cancel()
    generation += 1
    let mine = generation
    phase = .thinking
    answer = ""
    let prompt = AskSelection.prompt(selection: selection, source: source, question: question)
    run = ClaudeOneShot.run(arguments: AskSelection.arguments(), prompt: prompt, folder: nil,
                            timeout: AskSelection.timeout) { [weak self] result in
      guard let self, self.generation == mine else { return }
      self.run = nil
      switch result {
      case .success(let text):
        guard let reply = AskSelection.parse(text) else {
          // Claude answered in prose: show it as the answer and let the user write the item.
          self.answer = text.trimmed
          self.phase = .ready
          self.fillDefaults()
          return
        }
        self.apply(reply)
      case .failure(let failure):
        self.phase = .failed(failure.message)
      }
    }
  }

  private func apply(_ reply: AskSelection.Reply) {
    fillDefaults()
    answer = reply.answer
    recommended = reply.drafts.first?.kind
    for draft in reply.drafts {
      switch draft.kind {
      case .ticket: ticketTitle = draft.title; ticketDescription = draft.detail
      case .todo: todoText = draft.title
      case .note: noteTitle = draft.title; noteText = draft.detail
      }
    }
    if let first = reply.drafts.first { kind = first.kind }
    phase = .ready
  }

  /// Drafts Claude didn't write start from the selection itself.
  private func fillDefaults() {
    let first = selection.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmed ?? ""
    let title = String(first.prefix(80))
    ticketTitle = title
    ticketDescription = selection.trimmed
    todoText = title
    noteTitle = title
    noteText = selection.trimmed
    recommended = nil
    outcomes = [:]
  }

  // MARK: Saving

  func save(_ kind: AskSelection.Kind) {
    guard !saving.contains(kind) else { return }
    switch kind {
    case .todo:
      do {
        try CaptureStore.shared.addTodo(todoText, source: source)
        outcomes[.todo] = .saved("Added to your to-dos.", url: nil)
      } catch {
        outcomes[.todo] = .failed("Couldn't save the to-do: \(error.localizedDescription)")
      }
    case .note:
      do {
        try CaptureStore.shared.addNote(title: noteTitle, text: noteText, source: source)
        outcomes[.note] = .saved("Added to your notes.", url: nil)
      } catch {
        outcomes[.note] = .failed("Couldn't save the note: \(error.localizedDescription)")
      }
    case .ticket:
      createTicket()
    }
  }

  private func createTicket() {
    guard let direct = TicketService.shared.direct, let tracker, let projectKey else { return }
    let title = ticketTitle.trimmed
    let description = ticketDescription.trimmed
    guard !title.isEmpty else { return }
    saving.insert(.ticket)
    outcomes[.ticket] = nil
    Task { [weak self] in
      let result = await direct.create(tracker, project: projectKey, summary: title, description: description)
      guard let self else { return }
      self.saving.remove(.ticket)
      switch result {
      case .success(let created):
        self.outcomes[.ticket] = .saved("Created \(created.key).", url: created.url)
      case .failure(let failure):
        self.outcomes[.ticket] = .failed(failure.message)
      }
    }
  }

  // MARK: Where tickets go

  private func refreshTrackers() {
    trackers = TicketService.shared.direct?.trackers ?? []
    if trackerID == nil || !trackers.contains(where: { $0.server == trackerID }) {
      trackerID = trackers.first?.server
    }
  }

  private func loadProjects() {
    projectsTask?.cancel()
    projects = []
    projectKey = nil
    guard let direct = TicketService.shared.direct, let tracker else {
      projectsState = .idle
      return
    }
    projectsState = .loading
    projectsTask = Task { [weak self] in
      let result = await direct.projects(tracker)
      guard let self, !Task.isCancelled, self.trackerID == tracker.server else { return }
      switch result {
      case .success(let list):
        self.projects = list
        self.projectsState = .ready
        let remembered = Self.defaults.string(forKey: Self.projectDefault(tracker.server))
        self.projectKey = list.first { $0.key == remembered }?.key ?? list.first?.key
      case .failure(let failure):
        self.projectsState = .failed(failure.message)
      }
    }
  }

  /// The ticket as plain text, for a user with no Jira site to create it in.
  var ticketText: String {
    let body = ticketDescription.trimmed
    return body.isEmpty ? ticketTitle.trimmed : ticketTitle.trimmed + "\n\n" + body
  }
}

extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
