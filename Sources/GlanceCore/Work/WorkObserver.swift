import Foundation

/// The tracking hook's proof work (spec §3 "Seen by Glance"): a Bash call the project's setup counts as a check becomes
/// a check run, and a Glance browser screenshot is copied into the record. No git, no network, a few small file reads.
/// It records only what it saw: a check whose result cannot be told from the exit code or the runner's summary
/// (`ProofMatcher.result`) is not recorded at all, and a record whose lock is busy is skipped without a word.
public struct WorkObserver {
  public static let screenshotTool = "mcp__glance-browser__browser_take_screenshot"
  static let tailLines = 60
  /// Only the end of a command's output is read: a runner's summary is there, and a hook has about 30 ms.
  static let outputBytes = 65_536
  static let commandCharacters = 2_000
  static let lockBudget: TimeInterval = 0.05

  public static let browserToolPrefix = "mcp__glance-browser__"

  public var store: WorkStore
  public var now: () -> Date
  /// Where the Glance browser keeps its files (in `glance-browser/`): the hook's own $TMPDIR.
  public var tmpDir: String
  public init(store: WorkStore = WorkStore(), now: @escaping () -> Date = Date.init,
              tmpDir: String = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()) {
    self.store = store; self.now = now; self.tmpDir = tmpDir
  }

  /// `data` is a PostToolUse or PostToolUseFailure hook payload; anything else is ignored.
  public func observe(_ data: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let session = object["session_id"] as? String, WorkStore.isSessionID(session),
          let cwd = object["cwd"] as? String, let event = object["hook_event_name"] as? String,
          event == "PostToolUse" || event == "PostToolUseFailure", let tool = object["tool_name"] as? String else { return }
    let toolUseID = object["tool_use_id"] as? String
    if tool == "Bash" {
      observeBash(object, session: session, cwd: cwd, failed: event == "PostToolUseFailure", toolUseID: toolUseID)
    } else if tool.hasPrefix(Self.browserToolPrefix), event == "PostToolUse" {
      observeBrowser(object, tool: tool, session: session, cwd: cwd, toolUseID: toolUseID)
    }
  }

  /// Where `cwd` is, from files alone (no git in a hook): the same folder gives the branch and its repository.
  private func place(_ cwd: String) -> (worktree: String, branch: String?, commonDir: String?) {
    (ProjectRoot.find(from: cwd), GitHead.branch(inFolder: cwd), GitCommonDir.find(from: cwd))
  }

  private static func lastBytes(_ text: String) -> String {
    String(decoding: text.utf8.suffix(outputBytes), as: UTF8.self)
  }

  /// A Bash call's exit code as far as the hook says. Claude Code reports a call that exited non-zero as
  /// PostToolUseFailure, whose `error` starts "Exit code N"; any other failure (interrupted, timed out) has none.
  /// A PostToolUse is a call that succeeded, so its exit code is 0 unless the call was interrupted (unknown); a
  /// `tool_response.exit_code`, when a Claude Code version sends one, wins.
  static func exitCode(failed: Bool, error: String, response: [String: Any]?) -> Int? {
    if failed { return ProofMatcher.exitCode(fromError: error) }
    if let code = (response?["exit_code"] as? Int) ?? (response?["exitCode"] as? Int) { return code }
    return response?["interrupted"] as? Bool == true ? nil : 0
  }

  private func observeBash(_ object: [String: Any], session: String, cwd: String, failed: Bool, toolUseID: String?) {
    let input = object["tool_input"] as? [String: Any]
    // A backgrounded call returns at once with an empty response: the check has not run yet, so nothing was seen.
    if input?["run_in_background"] as? Bool == true { return }
    if (object["tool_response"] as? [String: Any])?["backgroundTaskId"] != nil { return }
    guard let command = input?["command"] as? String,
          let setup = ProofSetupFile.load(cwd: cwd).setup,
          let match = ProofMatcher.check(for: command, in: setup) else { return }
    let response = object["tool_response"] as? [String: Any]
    let error = object["error"] as? String ?? ""
    let output: String
    if failed {
      output = Self.lastBytes(error)
    } else {
      output = [response?["stdout"] as? String, response?["stderr"] as? String].compactMap { $0 }
        .filter { !$0.isEmpty }.map(Self.lastBytes).joined(separator: "\n")
    }
    let code = Self.exitCode(failed: failed, error: error, response: response)
    let counts = ProofMatcher.counts(in: output)
    guard let result = ProofMatcher.result(of: match, exitCode: code, counts: counts) else { return }
    // The exit code is stored only when it is the check's own: a pipe's or a later command's belongs to something else.
    let ownExit = match.exitIsReliable && (code == 0 || match.isLastSegment) ? code : nil
    let duration = (object["duration_ms"] as? Double).map { $0 / 1000 }
    let id = toolUseID ?? UUID().uuidString
    let where_ = place(cwd)
    let time = now()
    store.update(session: session, now: time, budget: Self.lockBudget) { record in
      record.place(cwd: cwd, worktree: where_.worktree, branch: where_.branch, commonDir: where_.commonDir)
      guard !record.checks.contains(where: { $0.id == id }) else { return }
      record.checks.append(ProofCheckRun(
        id: id, name: match.name, environment: match.environment, command: String(command.prefix(Self.commandCharacters)),
        exitCode: ownExit, result: result, passed: counts.passed, failed: counts.failed, duration: duration,
        outputTail: ProofMatcher.tail(output, lines: Self.tailLines), at: time))
    }
  }

  /// The text parts of an MCP tool response: `{content: [...]}`, a bare array, or a string.
  static func text(of response: Any?) -> String {
    if let string = response as? String { return string }
    let parts = (response as? [String: Any])?["content"] as? [[String: Any]] ?? response as? [[String: Any]] ?? []
    return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
  }

  /// A Glance browser tool's result: its `Page URL:` is remembered (the screenshot tool's result has none), and a
  /// screenshot is copied into the record with that URL.
  private func observeBrowser(_ object: [String: Any], tool: String, session: String, cwd: String, toolUseID: String?) {
    let text = Self.text(of: object["tool_response"])
    let seen = text.firstMatch(of: /Page URL: (\S+)/).map { String($0.1) }
    let known = store.record(session: session)?.lastBrowserURL
    if tool == Self.screenshotTool {
      observeScreenshot(text, session: session, cwd: cwd, toolUseID: toolUseID, pageURL: seen ?? known)
    } else if let seen, seen != known {
      let where_ = place(cwd)
      let time = now()
      store.update(session: session, now: time, budget: Self.lockBudget) { record in
        record.place(cwd: cwd, worktree: where_.worktree, branch: where_.branch, commonDir: where_.commonDir)
        record.lastBrowserURL = seen
      }
    }
  }

  private func observeScreenshot(_ text: String, session: String, cwd: String, toolUseID: String?, pageURL: String?) {
    guard let found = text.firstMatch(of: /\]\(([^)\s]+\.(?:png|jpe?g|webp))\)/.ignoresCase()) else { return }
    let raw = String(found.1)
    // The path is relative to the browser MCP's folder, which the hook doesn't know (`../../../../var/folders/...`
    // from its own): resolved against the hook's folder first, then looked up in the browser's temp folder.
    let candidates = [raw.hasPrefix("/") ? raw : URL(fileURLWithPath: cwd).appendingPathComponent(raw).standardizedFileURL.path,
                      (tmpDir as NSString).appendingPathComponent("glance-browser/" + (raw as NSString).lastPathComponent)]
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
    let environment = pageURL.flatMap { ProofMatcher.environment(forURL: $0, cwd: cwd) }
    let where_ = place(cwd)
    store.addCapture(session: session, id: toolUseID ?? UUID().uuidString, from: URL(fileURLWithPath: path),
                     kind: .screenshot, url: pageURL, environment: environment, caption: Self.caption(pageURL),
                     purpose: .test, source: .glance, cwd: cwd, worktree: where_.worktree, branch: where_.branch,
                     commonDir: where_.commonDir,
                     now: now(), budget: Self.lockBudget, hashLimit: WorkStore.hookHashLimit)
  }

  /// "localhost:3000/login" from the page URL (no scheme, no query), else "Screenshot".
  static func caption(_ url: String?) -> String {
    guard let url, let c = URLComponents(string: url), let host = c.host else { return "Screenshot" }
    let port = c.port.map { ":\($0)" } ?? ""
    let path = c.path == "/" ? "" : c.path
    return host + port + path
  }
}
