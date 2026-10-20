import Foundation

/// A message from the editor page. The page asks; Swift does the disk work and answers with an `EditorReply`.
public enum EditorRequest: Equatable, Sendable {
  case ready
  /// Which file is active, which open files have unsaved edits, and every open file (in tab order).
  case state(active: String?, dirty: [String], open: [String])
  /// The page's layout and open files, as JSON text, for Swift to keep and send back next time.
  case session(json: String)
  /// A save asked for by Swift (⌘S, close prompt) finished; false when any file failed to save.
  case saveDone(ok: Bool)
  case log(String)
  case read(id: Int, path: String)
  case list(id: Int, path: String)
  case save(id: Int, path: String, text: String, modified: Double?, bom: Bool)
  /// New File / New Folder in the file tree (`FileService.create`).
  case create(id: Int, path: String, directory: Bool)
  case quickOpen(id: Int, query: String)
  case search(id: Int, query: String, options: SearchOptions)
  case replace(id: Int, query: String, options: SearchOptions, replacement: String, paths: [String]?, skip: [String])
  /// The project's uncommitted changes, staged and not (`GitChanges.lists`).
  case changes(id: Int)
  /// A file's text at HEAD, for the diff view.
  case headText(id: Int, path: String)
  /// A file's staged text, for the diff view of an unstaged change.
  case indexText(id: Int, path: String)
  /// The Changes panel's git actions (`GitChanges.stage` and so on); each answers done or git's message.
  case stage(id: Int, paths: [String])
  case unstage(id: Int, paths: [String])
  case discard(id: Int, tracked: [String], untracked: [String])
  case commit(id: Int, message: String)
  /// ✦ in the Changes panel: Claude drafts a commit message (`CommitMessage`), streamed to `editorHost.commitDraft`.
  case draftCommit
  case draftCommitStop
  /// The project's git branch, for the status bar.
  case branch(id: Int)
  /// The branch picker's list (`GitBranches.list`).
  case branches(id: Int)
  /// Switches the checkout: to a branch, a new one (`create`), or a remote one (`remote`, as `origin/x`).
  case switchBranch(id: Int, name: String, create: Bool, remote: Bool)
  /// Format Document: how to format the file. `text` is the text to format (Swift formats it when a command-line tool
  /// or the project's own Prettier does); `range` is the selection, for Format Selection; `onSave` asks only if
  /// formatting on save is turned on.
  case format(id: Int, path: String, text: String?, onSave: Bool, range: Range<Int>?)
  /// Inline Ask: a question about the selected lines, a follow-up in the same box, and closing or stopping it.
  case askStart(InlineAsk.Request)
  case askFollowUp(id: String, question: String)
  case askStop(id: String)
  /// Ask Claude (the editor's right-click menu): the selected text and the file it is in.
  case askClaude(text: String, path: String?)
  /// The selected lines (1-based, inclusive), or nil when nothing is selected: the editor chat's context chip.
  case selection(lines: ClosedRange<Int>?)

  /// `body` is a `WKScriptMessage`'s body. Anything malformed is nil.
  public init?(body: Any) {
    guard let body = body as? [String: Any], let type = body["type"] as? String else { return nil }
    let id = (body["id"] as? NSNumber)?.intValue
    switch type {
    case "askStart":
      guard let request = InlineAsk.Request(object: body) else { return nil }
      self = .askStart(request)
    case "askFollowUp":
      guard let id = body["id"] as? String, let question = body["question"] as? String else { return nil }
      self = .askFollowUp(id: id, question: question)
    case "askClaude":
      guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      self = .askClaude(text: text, path: body["path"] as? String)
    case "askStop":
      guard let id = body["id"] as? String else { return nil }
      self = .askStop(id: id)
    case "changes":
      guard let id else { return nil }
      self = .changes(id: id)
    case "headText":
      guard let id, let path = body["path"] as? String else { return nil }
      self = .headText(id: id, path: path)
    case "indexText":
      guard let id, let path = body["path"] as? String else { return nil }
      self = .indexText(id: id, path: path)
    case "stage", "unstage":
      guard let id, let paths = body["paths"] as? [String], !paths.isEmpty else { return nil }
      self = type == "stage" ? .stage(id: id, paths: paths) : .unstage(id: id, paths: paths)
    case "discard":
      guard let id, let tracked = body["tracked"] as? [String], let untracked = body["untracked"] as? [String],
            !(tracked.isEmpty && untracked.isEmpty) else { return nil }
      self = .discard(id: id, tracked: tracked, untracked: untracked)
    case "commit":
      guard let id, let message = body["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      self = .commit(id: id, message: message)
    case "draftCommit":
      self = .draftCommit
    case "draftCommitStop":
      self = .draftCommitStop
    case "branch":
      guard let id else { return nil }
      self = .branch(id: id)
    case "branches":
      guard let id else { return nil }
      self = .branches(id: id)
    case "switchBranch":
      guard let id, let name = body["name"] as? String, !name.isEmpty else { return nil }
      self = .switchBranch(id: id, name: name, create: body["create"] as? Bool ?? false, remote: body["remote"] as? Bool ?? false)
    case "format":
      guard let id, let path = body["path"] as? String else { return nil }
      var range: Range<Int>?
      if let start = (body["rangeStart"] as? NSNumber)?.intValue, let end = (body["rangeEnd"] as? NSNumber)?.intValue,
         start >= 0, start <= end {
        range = start..<end
      }
      self = .format(id: id, path: path, text: body["text"] as? String, onSave: body["onSave"] as? Bool ?? false, range: range)
    case "selection":
      if let start = (body["start"] as? NSNumber)?.intValue, let end = (body["end"] as? NSNumber)?.intValue,
         start >= 1, start <= end {
        self = .selection(lines: start...end)
      } else {
        self = .selection(lines: nil)
      }
    case "ready":
      self = .ready
    case "state":
      self = .state(active: body["active"] as? String, dirty: body["dirty"] as? [String] ?? [],
                    open: body["open"] as? [String] ?? [])
    case "session":
      guard let json = body["json"] as? String else { return nil }
      self = .session(json: json)
    case "saveDone":
      guard let ok = body["ok"] as? Bool else { return nil }
      self = .saveDone(ok: ok)
    case "log":
      self = .log(body["message"] as? String ?? "")
    case "read":
      guard let id, let path = body["path"] as? String else { return nil }
      self = .read(id: id, path: path)
    case "list":
      guard let id, let path = body["path"] as? String else { return nil }
      self = .list(id: id, path: path)
    case "create":
      guard let id, let path = body["path"] as? String else { return nil }
      self = .create(id: id, path: path, directory: body["dir"] as? Bool ?? false)
    case "quickOpen":
      guard let id, let query = body["query"] as? String else { return nil }
      self = .quickOpen(id: id, query: query)
    case "save":
      guard let id, let path = body["path"] as? String, let text = body["text"] as? String else { return nil }
      self = .save(id: id, path: path, text: text, modified: (body["modified"] as? NSNumber)?.doubleValue,
                   bom: body["bom"] as? Bool ?? false)
    case "search":
      guard let id, let query = body["query"] as? String else { return nil }
      self = .search(id: id, query: query, options: Self.options(body["options"]))
    case "replace":
      guard let id, let query = body["query"] as? String, let replacement = body["replacement"] as? String else { return nil }
      self = .replace(id: id, query: query, options: Self.options(body["options"]), replacement: replacement,
                      paths: body["paths"] as? [String], skip: body["skip"] as? [String] ?? [])
    default:
      return nil
    }
  }

  private static func options(_ value: Any?) -> SearchOptions {
    let dictionary = value as? [String: Any] ?? [:]
    return SearchOptions(caseSensitive: dictionary["caseSensitive"] as? Bool ?? false,
                         wholeWord: dictionary["wholeWord"] as? Bool ?? false,
                         regex: dictionary["regex"] as? Bool ?? false)
  }
}

/// JavaScript the host runs to answer the page. The payload is JSON, which is also valid JavaScript.
public enum EditorReply {
  private static func json(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data("null".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  private static func ok(id: Int, _ result: [String: Any]) -> String {
    "editorHost.reply(\(json(["id": id, "ok": true, "result": result])))"
  }

  public static func opened(id: Int, _ document: FileService.Document) -> String {
    ok(id: id, ["path": document.path, "text": document.text, "modified": document.modified, "bom": document.bom,
                "language": EditorLanguage.id(forPath: document.path), "formatter": formatter(for: document.path)])
  }

  /// Which formatter the page should expect for a file: "prettier", "command" (Swift runs it) or null.
  static func formatter(for path: String) -> Any {
    switch CodeFormatter.plan(for: "/" + path, exists: { _ in false }, read: { _ in nil }) {
    case .prettier: return "prettier"
    case .tools: return "command"
    case nil: return NSNull()
    }
  }

  /// Format Document's answer: Prettier's parser and the project's options (the page formats), or the formatted
  /// text, or (`skip`) nothing to do.
  public static func formatWithPrettier(id: Int, parser: String, options: [String: Any]) -> String {
    ok(id: id, ["prettier": ["parser": parser, "options": options]])
  }
  public static func formatted(id: Int, text: String) -> String { ok(id: id, ["text": text]) }
  public static func formatSkipped(id: Int) -> String { ok(id: id, ["skip": true]) }
  public static func formatFailed(id: Int, _ failure: CodeFormatter.Failure) -> String {
    failed(id: id, code: failure.code, message: failure.message)
  }

  public static func saved(id: Int, modified: Double) -> String { ok(id: id, ["modified": modified]) }

  public static func created(id: Int) -> String { ok(id: id, [:]) }

  public static func paths(id: Int, _ paths: [String]) -> String { ok(id: id, ["paths": paths]) }

  public static func entries(id: Int, _ entries: [FileService.DirectoryEntry]) -> String {
    ok(id: id, ["entries": entries.map { ["name": $0.name, "dir": $0.isDirectory] as [String: Any] }])
  }

  public static func failed(id: Int, _ failure: FileService.Failure) -> String {
    "editorHost.reply(\(json(["id": id, "ok": false, "error": ["code": failure.code, "message": failure.message]])))"
  }

  public static func searchResults(id: Int, _ result: SearchResult) -> String {
    ok(id: id, [
      "matches": result.matches.map { match -> [String: Any] in
        ["path": match.path, "line": match.line, "column": match.column, "length": match.length,
         "preview": match.preview, "previewStart": match.previewStart]
      },
      "truncated": result.truncated,
      "files": result.fileCount,
    ])
  }

  public static func replaced(id: Int, _ result: ReplaceResult) -> String {
    ok(id: id, [
      "replacements": result.replacements,
      "files": result.files,
      "skipped": result.skipped,
      "failed": result.failed.map { ["path": $0.path, "message": $0.message] },
    ])
  }

  /// A failure with an explicit code (search errors).
  public static func failed(id: Int, code: String, message: String) -> String {
    "editorHost.reply(\(json(["id": id, "ok": false, "error": ["code": code, "message": message]])))"
  }

  /// The Changes panel's staged and unstaged lists; nil (not a git repository) fails with `notGit`.
  public static func changes(id: Int, _ lists: GitChanges.Lists?) -> String {
    guard let lists else { return failed(id: id, code: "notGit", message: "Not a git repository") }
    let entries = { (changes: [GitChanges.Change]) in
      changes.map { change -> [String: Any] in
        var entry: [String: Any] = ["path": change.path, "status": change.status.rawValue]
        if let old = change.oldPath { entry["oldPath"] = old }
        return entry
      }
    }
    return ok(id: id, ["staged": entries(lists.staged), "unstaged": entries(lists.unstaged)])
  }

  /// A Changes panel git action: done, or git's message (code `git`).
  public static func gitDone(id: Int, error: String?) -> String {
    guard let error else { return ok(id: id, [:]) }
    return failed(id: id, code: "git", message: error)
  }

  /// A piece of the commit message draft, the cleaned-up whole when it's done, or why it failed.
  public static func commitDraft(_ event: CommitMessage.DraftEvent) -> String {
    let object: [String: Any] = switch event {
    case .text(let text): ["kind": "text", "text": text]
    case .done(let text): ["kind": "done", "text": CommitMessage.clean(text)]
    case .failed(let message): ["kind": "failed", "message": message]
    }
    return "editorHost.commitDraft(\(json(object)))"
  }

  /// The project's branch; null outside a git repository.
  public static func branch(id: Int, _ name: String?) -> String { ok(id: id, ["branch": name ?? NSNull()]) }

  /// The branch picker's list; nil (not a git repository) fails with `notGit`.
  public static func branches(id: Int, _ list: GitBranches.List?) -> String {
    guard let list else { return failed(id: id, code: "notGit", message: "Not a git repository") }
    return ok(id: id, ["current": list.current ?? NSNull(), "local": list.local, "remote": list.remote])
  }

  /// A switch: done, or git's message (code `git`).
  public static func switchedBranch(id: Int, error: String?) -> String {
    guard let error else { return ok(id: id, [:]) }
    return failed(id: id, code: "git", message: error)
  }

  /// A file's text at HEAD; null when it has none (new or untracked).
  public static func headText(id: Int, _ text: String?) -> String { ok(id: id, ["text": text ?? NSNull()]) }

  /// What Claude is doing in an inline box (`InlineAsk.eventObject`).
  public static func askEvent(_ event: InlineAsk.Event, request: InlineAsk.Request) -> String {
    "editorHost.askEvent(\(json(InlineAsk.eventObject(event, for: request))))"
  }

  /// The files Claude edited in the latest session, relative to the root.
  public static func claudeFiles(_ paths: [String]) -> String { "editorHost.claudeFiles(\(json(paths)))" }

  /// The lines Claude changed, by path relative to the project root. Replaces what the page shows.
  public static func claudeChanges(_ marks: [String: [LineMark]]) -> String {
    let object = marks.mapValues { runs in
      runs.map { ["start": $0.start, "end": $0.end, "kind": $0.kind.rawValue] as [String: Any] }
    }
    return "editorHost.claudeChanges(\(json(object)))"
  }

  /// An open file's modification time changed on disk (nil: it is gone).
  public static func externalChange(path: String, modified: Double?) -> String {
    "editorHost.externalChange(\(json(["path": path, "modified": modified.map { $0 as Any } ?? NSNull()])))"
  }

  /// The project folder, for the path bar: its name and absolute path.
  public static func project(root: String) -> String {
    "editorHost.project(\(json(["name": (root as NSString).lastPathComponent, "root": root])))"
  }

  /// Open (or activate) a file, optionally at a line and column.
  public static func open(path: String, line: Int?, column: Int?) -> String {
    "editorHost.open(\(json(["path": path, "line": line.map { $0 as Any } ?? NSNull(), "column": column.map { $0 as Any } ?? NSNull()])))"
  }

  /// Hands a stored session back to the page. Nil unless the text is exactly one JSON object (it is embedded as
  /// JavaScript, so nothing else may ride along).
  public static func restore(sessionJSON: String) -> String? {
    guard let data = sessionJSON.data(using: .utf8),
          (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
    return "editorHost.restore(\(sessionJSON))"
  }
}
