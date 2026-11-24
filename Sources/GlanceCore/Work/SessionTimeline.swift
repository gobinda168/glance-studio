import Foundation

/// One Claude Code session's transcript as rows for the Glance view (spec 2026-11-01-command-center-design.md §2),
/// built a line at a time so a growing transcript is parsed once. Unknown entry types and malformed lines are skipped.
public struct SessionTimeline: Equatable, Sendable {
  public private(set) var rows: [TimelineRow] = []
  public private(set) var live = SessionLive(working: false, tool: nil, lastActivity: nil)
  public private(set) var usage = SessionUsage(model: nil, contextTokens: 0, cost: 0)
  /// The model, effort and permission mode the transcript says the session runs with.
  public private(set) var settings = SessionSettings()
  /// The prose rows that ended a turn with Claude's own stop_reason. An interrupted turn's last prose isn't here.
  public private(set) var endedTurns: Set<String> = []
  /// The start of the transcript was skipped (very large files).
  public var truncated = false

  private let root: String?
  private var toolIndex: [String: Int] = [:]
  private var messageCosts: [String: Double] = [:]
  private var openTasks: [String] = []
  private var lastTask: String?

  public init(root: String?) { self.root = root }

  public mutating func ingest<S: Sequence>(lines: S) where S.Element == String {
    for line in lines { ingest(line: line) }
  }

  public mutating func ingest(line: String) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
    let time = (entry["timestamp"] as? String).flatMap(Self.date)
    if let time { live.lastActivity = time }
    let isSidechain = entry["isSidechain"] as? Bool == true
    let uuid = entry["uuid"] as? String ?? UUID().uuidString
    switch entry["type"] as? String {
    case "system" where entry["subtype"] as? String == "compact_boundary":
      append(.compact, id: uuid, time: time, parent: nil)
    case "permission-mode":
      if let mode = (entry["permissionMode"] as? String).flatMap(PermissionMode.init(transcript:)) { settings.permissionMode = mode }
    case "user": user(entry, uuid: uuid, time: time, isSidechain: isSidechain)
    case "assistant": assistant(entry, uuid: uuid, time: time, isSidechain: isSidechain)
    default: break
    }
  }

  // MARK: user entries: prompts, slash-command echoes, tool results

  private mutating func user(_ entry: [String: Any], uuid: String, time: Date?, isSidechain: Bool) {
    guard let message = entry["message"] as? [String: Any], entry["isCompactSummary"] as? Bool != true else { return }
    var text: [String] = [], images: [TimelineImage] = []
    var hasToolResult = false
    if let plain = message["content"] as? String { text = [plain] }
    for block in message["content"] as? [[String: Any]] ?? [] {
      switch block["type"] as? String {
      case "tool_result":
        hasToolResult = true
        settle(block, extra: entry["toolUseResult"] as? [String: Any])
      case "text": text.append(block["text"] as? String ?? "")
      case "image": if let image = Self.image(block) { images.append(image) }
      default: break
      }
    }
    guard !isSidechain, entry["isMeta"] as? Bool != true else { return }
    let joined = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

    // Skip user rows if entry contains tool_result (those are not prompts)
    guard !hasToolResult else { return }

    // Handle user interrupts
    if joined.hasPrefix("[Request interrupted by user") {
      live.working = false
      live.tool = nil
      return
    }

    // A background task's result, which Claude Code hands Claude as a user message. The user didn't say it, and it
    // doesn't mean Claude is working: after a resume nothing may answer it. An `origin` settles it, so a prompt that
    // merely quotes the tag stays a prompt.
    let origin = (entry["origin"] as? [String: Any])?["kind"] as? String
    if origin == "task-notification" || (origin == nil && joined.hasPrefix("<task-notification>")) { return }

    // A `!` command the user ran from Claude's prompt, then its output.
    if let command = Self.between(joined, "<bash-input>", "</bash-input>") {
      append(.command(name: "! " + command, output: nil), id: uuid, time: time, parent: nil)
      return
    }
    if joined.hasPrefix("<bash-stdout>") || joined.hasPrefix("<bash-stderr>") {
      let streams = [Self.between(joined, "<bash-stdout>", "</bash-stdout>"), Self.between(joined, "<bash-stderr>", "</bash-stderr>")]
      let output = streams.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
      if let last = rows.indices.last, case .command(let name, nil) = rows[last].kind {
        rows[last].kind = .command(name: name, output: output.isEmpty ? nil : output)
      }
      return
    }

    if let name = Self.between(joined, "<command-name>", "</command-name>") {
      append(.command(name: name, output: nil), id: uuid, time: time, parent: nil)
      return
    }
    if let output = Self.between(joined, "<local-command-stdout>", "</local-command-stdout>") {
      if let last = rows.indices.last, case .command(let name, nil) = rows[last].kind {
        rows[last].kind = .command(name: name, output: output.isEmpty ? nil : output)
        settings.commandFinished(name, output: output)
      }
      return
    }
    guard !joined.isEmpty || !images.isEmpty else { return }
    live.working = true
    append(.user(text: joined, images: images), id: uuid, time: time, parent: nil)
  }

  private mutating func settle(_ block: [String: Any], extra: [String: Any]?) {
    guard let id = block["tool_use_id"] as? String, let index = toolIndex[id],
          case .tool(let name, let kind, _, _) = rows[index].kind else { return }
    let isError = block["is_error"] as? Bool == true
    var output = "", images: [TimelineImage] = []
    if let s = block["content"] as? String { output = s }
    for part in block["content"] as? [[String: Any]] ?? [] {
      if part["type"] as? String == "text" { output += (output.isEmpty ? "" : "\n") + (part["text"] as? String ?? "") }
      if let image = Self.image(part) { images.append(image) }
    }
    // Check denial on original output BEFORE replacing with streams
    let denied = isError && ChatTranscript.isDenial(output)
    var exitCode: Int?
    if case .bash = kind {
      let streams = [extra?["stdout"] as? String ?? "", extra?["stderr"] as? String ?? ""].filter { !$0.isEmpty }
      exitCode = Self.exitCode(output, isError: isError)
      if !streams.isEmpty { output = streams.joined(separator: "\n") }
    }
    rows[index].kind = .tool(name: name, kind: kind,
                             result: ToolResult(output: output, isError: isError, exitCode: exitCode, images: images),
                             denied: denied)
    if live.tool?.id == id { live.tool = nil }
    if let idx = openTasks.firstIndex(of: id) {
      openTasks.remove(at: idx)
      lastTask = id  // Track the most recently settled Task
    }
  }

  // MARK: assistant entries: prose, tool calls, usage

  private mutating func assistant(_ entry: [String: Any], uuid: String, time: Date?, isSidechain: Bool) {
    guard let message = entry["message"] as? [String: Any] else { return }
    count(message, sidechain: isSidechain, time: time)
    if !isSidechain, let effort = entry["effort"] as? String { settings.effort = effort }
    // For sidechain rows: use open Task, else use last settled Task; if neither exist, skip prose/tools
    let parent: String? = isSidechain ? (openTasks.last ?? lastTask) : nil
    let shouldAddSidechain = !isSidechain || parent != nil  // Skip sidechain if no Task context
    for (i, block) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
      switch block["type"] as? String {
      case "text":
        let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && shouldAddSidechain {
          append(.prose(markdown: text), id: "\(uuid)-\(i)", time: time, parent: parent)
        }
      case "tool_use":
        guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
        let kind = Self.kind(name, block["input"] as? [String: Any] ?? [:], root: root)
        if shouldAddSidechain {
          append(.tool(name: name, kind: kind, result: nil, denied: false), id: id, time: time, parent: parent)
          toolIndex[id] = rows.count - 1
          if !isSidechain {
            live.tool = RunningTool(id: id, name: name, detail: Self.detail(kind), since: time)
            if name == "Task" || name == "Agent" { openTasks.append(id) }
          }
        }
      default: break
      }
    }
    if !isSidechain, let stop = message["stop_reason"] as? String, stop != "tool_use", stop != "pause_turn" {
      live.working = false
      live.tool = nil
      if let last = rows.reversed().prefix(while: { !ExplainerTurns.isBoundary($0) }).first(where: \.isReply) { endedTurns.insert(last.id) }
    }
  }

  private mutating func count(_ message: [String: Any], sidechain: Bool, time: Date?) {
    guard let u = message["usage"] as? [String: Any] else { return }
    let model = message["model"] as? String
    let input = u["input_tokens"] as? Int ?? 0, read = u["cache_read_input_tokens"] as? Int ?? 0
    let write = u["cache_creation_input_tokens"] as? Int ?? 0, output = u["output_tokens"] as? Int ?? 0
    if !sidechain {
      usage.contextTokens = input + read + write
      if let model, model != "<synthetic>" { usage.model = model; settings.model = model }
    }
    guard let id = message["id"] as? String, let model else { return }
    let record = UsageRecord(messageID: id, time: time ?? Date(), model: model, sessionID: "", project: "",
                             subagent: sidechain, fast: false, input: input, output: output,
                             cacheWrite5m: write, cacheWrite1h: 0, cacheRead: read)
    let cost = UsagePricing.cost(record) ?? 0
    usage.cost += cost - (messageCosts[id] ?? 0)   // a message repeated across lines counts once (its last figures)
    messageCosts[id] = cost
  }

  private mutating func append(_ kind: TimelineRow.Kind, id: String, time: Date?, parent: String?) {
    rows.append(TimelineRow(id: id, kind: kind, time: time, parent: parent))
  }

  // MARK: helpers

  static func kind(_ name: String, _ input: [String: Any], root: String?) -> ToolKind {
    let rel = { (p: String?) in p.map { relative($0, root: root) } }
    let path = rel(input["file_path"] as? String ?? input["notebook_path"] as? String) ?? ""
    switch name {
    case "Read": return .read(path: path)
    case "Grep", "Glob": return .search(pattern: input["pattern"] as? String ?? "", path: rel(input["path"] as? String))
    case "Edit": return .edit(path: path, diff: TextDiff.lines(old: input["old_string"] as? String ?? "", new: input["new_string"] as? String ?? ""))
    case "MultiEdit":
      let edits = input["edits"] as? [[String: Any]] ?? []
      return .edit(path: path, diff: edits.flatMap { TextDiff.lines(old: $0["old_string"] as? String ?? "", new: $0["new_string"] as? String ?? "") })
    case "Write": return .write(path: path, lines: (input["content"] as? String ?? "").components(separatedBy: "\n").count)
    case "Bash": return .bash(command: input["command"] as? String ?? "", summary: input["description"] as? String)
    case "Task", "Agent": return .task(summary: input["description"] as? String ?? input["subagent_type"] as? String ?? "Subagent")
    case "WebFetch": return .web(input["url"] as? String ?? "")
    case "WebSearch": return .web(input["query"] as? String ?? "")
    default: return .other(detail: path.isEmpty ? (input.values.compactMap { $0 as? String }.first ?? "") : path)
    }
  }

  static func detail(_ kind: ToolKind) -> String {
    switch kind {
    case .read(let p), .edit(let p, _), .write(let p, _): p
    case .search(let pattern, _): pattern
    case .bash(let command, _): command
    case .task(let s), .web(let s), .other(let s): s
    }
  }

  static func relative(_ path: String, root: String?) -> String {
    guard let root, path.hasPrefix(root + "/") else { return path }
    return String(path.dropFirst(root.count + 1))
  }

  static func exitCode(_ output: String, isError: Bool) -> Int {
    if let range = output.range(of: #"Exit code (\d+)"#, options: .regularExpression),
       let n = Int(output[range].split(separator: " ").last ?? "") { return n }
    return isError ? 1 : 0
  }

  static func image(_ block: [String: Any]) -> TimelineImage? {
    guard block["type"] as? String == "image", let source = block["source"] as? [String: Any],
          let b64 = source["data"] as? String, let data = Data(base64Encoded: b64) else { return nil }
    return TimelineImage(mediaType: source["media_type"] as? String ?? "image/png", data: data)
  }

  static func between(_ text: String, _ open: String, _ close: String) -> String? {
    guard let a = text.range(of: open), let b = text.range(of: close, range: a.upperBound..<text.endIndex) else { return nil }
    return String(text[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func date(_ s: String) -> Date? {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s))
  }
}
