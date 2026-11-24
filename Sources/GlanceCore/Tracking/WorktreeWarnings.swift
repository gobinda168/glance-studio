import Foundation

/// A note for Claude about its worktree (spec §2). `items` are what it names; it is told again only when they grow.
public struct WorktreeWarning: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case foreignEdits, sharedWorktree, topics
  }

  public var kind: Kind
  public var items: [String]
  public var text: String

  public init(kind: Kind, items: [String], text: String) {
    self.kind = kind
    self.items = items
    self.text = text
  }
}

public enum WorktreeWarnings {
  public struct Context {
    public var me: String
    public var files: [AttributedFile]
    /// The live sessions in this worktree, this one included.
    public var live: [TrackedSession]
    public var name: (String) -> String

    public init(me: String, files: [AttributedFile], live: [TrackedSession], name: @escaping (String) -> String) {
      self.me = me
      self.files = files
      self.live = live
      self.name = name
    }
  }

  public static let fixes = "Tell the user before going on, and offer: moving this task to its own worktree "
    + "(`glance worktree move --mine --task \"<short task name>\"`), committing only this session's files "
    + "(`glance changes --mine` lists them), or carrying on. Do none of them without the user's OK."

  public static func foreignEdits(_ context: Context) -> WorktreeWarning? {
    let foreign = context.files.filter { $0.author != .session(context.me) }
    guard !foreign.isEmpty else { return nil }
    let lines = groups(foreign, context).map { "- \($0.label): \(list($0.paths))" }
    return WorktreeWarning(
      kind: .foreignEdits, items: foreign.map(\.path),
      text: "Glance: this worktree has uncommitted changes that aren't this session's:\n"
        + lines.joined(separator: "\n") + "\n" + fixes)
  }

  public static func sharedWorktree(_ context: Context) -> WorktreeWarning? {
    let others = context.live.filter { $0.id != context.me }
    guard !others.isEmpty else { return nil }
    let names = others.map { "\(context.name($0.id)) (\(place($0.terminal)))" }
    return WorktreeWarning(
      kind: .sharedWorktree, items: others.map(\.id).sorted(),
      text: "Glance: another Claude session is working in this worktree right now: "
        + names.joined(separator: ", ") + ". Its edits and this session's will mix.\n" + fixes)
  }

  public static func topics(_ context: Context) -> WorktreeWarning? {
    guard !context.files.isEmpty else { return nil }
    let lines = groups(context.files, context).map { "- \($0.label): \(list($0.paths))" }
    return WorktreeWarning(
      kind: .topics, items: context.files.map { "\($0.path)|\(key($0.author))" },
      text: "Glance: this worktree's uncommitted changes, by who made them:\n" + lines.joined(separator: "\n")
        + "\nIf these are separate tasks, tell the user before mixing them (for example in one commit), and offer "
        + "the fixes: moving a task to its own worktree, or committing only one session's files "
        + "(`glance changes --mine`).")
  }

  /// The warnings with items this session wasn't told yet; `told` (kind → items) is updated.
  public static func unseen(_ warnings: [WorktreeWarning], told: inout [String: [String]]) -> [WorktreeWarning] {
    warnings.filter { warning in
      let before = Set(told[warning.kind.rawValue] ?? [])
      guard !Set(warning.items).isSubset(of: before) else { return false }
      told[warning.kind.rawValue] = before.union(warning.items).sorted()
      return true
    }
  }

  /// Whether a Bash command line runs `git commit` (with or without `-C <dir>`).
  public static func isCommit(_ command: String?) -> Bool {
    guard let command else { return false }
    return command.range(of: #"(^|[\s;&|(])git(\s+-C\s+\S+)?\s+commit(\s|$)"#, options: .regularExpression) != nil
  }

  struct Group {
    var label: String
    var paths: [String]
  }

  static func groups(_ files: [AttributedFile], _ context: Context) -> [Group] {
    var order: [Author] = []
    var paths: [Author: [String]] = [:]
    for file in files {
      if paths[file.author] == nil { order.append(file.author) }
      paths[file.author, default: []].append(file.path)
    }
    return order.map { author in
      let label: String = switch author {
      case .session(let id) where id == context.me: "this session"
      case .session(let id): context.name(id)
      case .outside: "changed outside Claude"
      case .ambiguous(let ids): "ambiguous (" + ids.map(context.name).joined(separator: " and ") + " at once)"
      }
      return Group(label: label, paths: paths[author] ?? [])
    }
  }

  static func list(_ paths: [String]) -> String {
    paths.count <= 8 ? paths.joined(separator: ", ")
      : paths.prefix(8).joined(separator: ", ") + " and \(paths.count - 8) more"
  }

  static func key(_ author: Author) -> String {
    switch author {
    case .session(let id): id
    case .outside: "outside"
    case .ambiguous(let ids): ids.joined(separator: "+")
    }
  }

  /// Where a session runs, in words: Glance Studio, Warp, another terminal's name, or "another terminal" when unknown.
  public static func place(_ terminal: String?) -> String {
    guard let terminal else { return "another terminal" }
    if terminal.hasPrefix("studio:") { return "Glance Studio" }
    return terminal == "WarpTerminal" ? "Warp" : terminal
  }
}
