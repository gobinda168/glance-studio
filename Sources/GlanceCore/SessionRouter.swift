import Foundation

/// Decides what Glance Studio's pane does as Claude sessions take turns and focus moves. A terminal whose `claude`
/// reported its session (SessionLink) shows that session only, so two terminals in one folder never mix (spec
/// 2026-10-11-humanize-summaries-design.md, "Session isolation"). A terminal without a link (Claude started before
/// Glance's hook) falls back to its folder's latest unlinked session. Editors show no terminal replies. Anything else
/// (Home, PR pages) follows its folder as before. Only the followed session thinks and speaks.
public struct SessionRouter {
  public enum Action: Equatable {
    case none
    case thinking(cwd: String)
    case show(file: String, cwd: String, narrate: Bool)
    /// Nothing to show here yet.
    case clear
  }

  public enum Focus: Equatable {
    case terminal(surface: UUID, pwd: String?)
    case editor(root: String?)
    case folder(String?)
  }

  private let home: String
  private var current: Focus?
  private var links: [UUID: SessionLink] = [:]
  /// Transcripts with at least one finished turn.
  private var finished: Set<String> = []
  /// The latest finished turn's transcript, by normalised folder: any session, and sessions no terminal links.
  private var replies: [String: String] = [:]
  private var unlinkedReplies: [String: String] = [:]

  public init(home: String = NSHomeDirectory()) {
    self.home = home
  }

  /// The focused folder (a terminal's, an editor's root, or a page's).
  public var focusedPwd: String? {
    switch current {
    case .terminal(_, let pwd), .editor(let pwd), .folder(let pwd): pwd.map { SessionMatch.normalize($0, home: home) }
    case nil: nil
    }
  }

  public var focusedSurface: UUID? {
    if case .terminal(let surface, _) = current { return surface }
    return nil
  }

  public func link(for surface: UUID) -> SessionLink? { links[surface] }

  public func surface(forTranscript path: String) -> UUID? {
    links.first { $0.value.transcriptPath == path }?.key
  }

  /// The older entry point: a folder took focus.
  public mutating func focus(pwd: String?) -> Action { focus(.folder(pwd)) }

  public mutating func focus(_ focus: Focus) -> Action {
    let focus = normalized(focus)
    guard focus != current else { return .none }
    current = focus
    return shown()
  }

  /// The terminals' sessions changed. Only a change for the focused terminal changes the pane.
  public mutating func setLinks(_ newLinks: [UUID: SessionLink]) -> Action {
    let before = focusedSurface.flatMap { links[$0] }
    links = newLinks
    let after = focusedSurface.flatMap { links[$0] }
    return before == after ? .none : shown()
  }

  /// A Claude session in `cwd` sent a prompt or finished a turn; `file` is its transcript.
  public mutating func turn(_ kind: TurnEvent.Kind, cwd: String?, file: String) -> Action {
    guard let cwd else { return .none }
    let folder = SessionMatch.normalize(cwd, home: home)
    let followed = follows(file: file, folder: folder)
    switch kind {
    case .prompt:
      return followed ? .thinking(cwd: folder) : .none
    case .done:
      finished.insert(file)
      replies[folder] = file
      if surface(forTranscript: file) == nil { unlinkedReplies[folder] = file }
      return followed ? .show(file: file, cwd: folder, narrate: true) : .none
    }
  }

  /// The same folder written two ways ("~/x", "/Users/me/x/") is one focus.
  private func normalized(_ focus: Focus) -> Focus {
    let normalize = { (pwd: String?) in pwd.map { SessionMatch.normalize($0, home: home) } }
    switch focus {
    case .terminal(let surface, let pwd): return .terminal(surface: surface, pwd: normalize(pwd))
    case .editor(let root): return .editor(root: normalize(root))
    case .folder(let pwd): return .folder(normalize(pwd))
    }
  }

  private func follows(file: String, folder: String) -> Bool {
    switch current {
    case .terminal(let focused, _):
      if let linked = links[focused] { return linked.transcriptPath == file }
      return folder == focusedPwd && surface(forTranscript: file) == nil
    case .editor, nil:
      return false
    case .folder:
      return folder == focusedPwd
    }
  }

  private func shown() -> Action {
    switch current {
    case .terminal(let focused, _):
      if let linked = links[focused] {
        guard finished.contains(linked.transcriptPath) else { return .clear }
        let cwd = (linked.cwd ?? focusedPwd).map { SessionMatch.normalize($0, home: home) } ?? ""
        return .show(file: linked.transcriptPath, cwd: cwd, narrate: false)
      }
      guard let folder = focusedPwd, let file = unlinkedReplies[folder] else { return .clear }
      return .show(file: file, cwd: folder, narrate: false)
    case .editor, nil:
      return .clear
    case .folder:
      guard let folder = focusedPwd, let file = replies[folder] else { return .clear }
      return .show(file: file, cwd: folder, narrate: false)
    }
  }
}
