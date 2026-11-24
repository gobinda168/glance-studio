import Darwin
import Foundation

/// The GitHub CLI with the user's own `gh auth login`: how Glance runs it and reads what went wrong, shared by the Pull
/// requests side bar and the PR pages (spec 2026-10-07-pr-manager-design.md, "GitHub"). `run` and `execute` block until
/// the process ends, so call them off the main thread.
public enum GitHubCLI {
  /// A GraphQL variable: a string goes to gh as `-f` (always a string), a number or flag as `-F` (typed).
  public enum Variable: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
  }

  /// `gh api graphql` for `query`, its variables sorted by name.
  public static func graphQLArguments(_ query: String, variables: [String: Variable] = [:]) -> [String] {
    var arguments = ["api", "graphql", "-f", "query=" + query]
    for (name, value) in variables.sorted(by: { $0.key < $1.key }) {
      switch value {
      case .string(let text): arguments += ["-f", "\(name)=\(text)"]
      case .int(let number): arguments += ["-F", "\(name)=\(number)"]
      case .bool(let flag): arguments += ["-F", "\(name)=\(flag)"]
      }
    }
    return arguments
  }

  /// "owner/name" in two; nil for anything else.
  public static func split(_ repository: String) -> (owner: String, name: String)? {
    let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return (String(parts[0]), String(parts[1]))
  }

  /// What a finished gh means: its output, or why there is none. gh exits 4 when it needs `gh auth login`.
  public static func outcome(status: Int32, output: Data, error: Data) -> Result<Data, PullRequests.Failure> {
    switch status {
    case 0: .success(output)
    case 4: .failure(.signedOut)
    default: .failure(.failed(firstLine(error)))
    }
  }

  /// A GraphQL response's `data`, or its first error.
  public static func graphQLData(_ data: Data) -> Result<[String: Any], PullRequests.Failure> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .failure(.failed("GitHub sent something that isn't JSON"))
    }
    if let errors = object["errors"] as? [[String: Any]], let first = errors.first {
      return .failure(.failed(first["message"] as? String ?? "GitHub refused the query"))
    }
    guard let payload = object["data"] as? [String: Any] else { return .failure(.failed("GitHub sent no data")) }
    return .success(payload)
  }

  /// The environment Glance runs gh in: its own, with prompts, update notices and colour off, and `extra` on top.
  public static func environment(_ extra: [String: String] = [:]) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["GH_PROMPT_DISABLED"] = "1"
    environment["GH_NO_UPDATE_NOTIFIER"] = "1"
    environment["NO_COLOR"] = "1"
    environment.merge(extra) { $1 }
    return environment
  }

  /// Runs gh (`executable`; nil when it isn't installed) with `arguments`. `input` goes to its stdin, `folder` is its
  /// working directory.
  /// `timeout` stops a gh that does not answer, and that counts as a failure.
  public static func run(_ executable: String?, _ arguments: [String], input: Data? = nil, folder: String? = nil,
                         timeout: TimeInterval? = nil) -> Result<Data, PullRequests.Failure> {
    guard let executable, let result = execute(executable, arguments, input: input, folder: folder, timeout: timeout) else {
      return .failure(.notInstalled)
    }
    return outcome(status: result.status, output: result.output, error: result.error)
  }

  /// Runs a program (gh, git) to the end: its exit status, stdout and stderr; nil when it can't start. `environment`
  /// adds to Glance's own (git's GIT_INDEX_FILE, say). A program still running after `timeout` seconds is terminated
  /// (killed two seconds later if it ignores that) and ends with a failing status.
  public static func execute(_ executable: String, _ arguments: [String], input: Data? = nil, folder: String? = nil,
                             environment extra: [String: String] = [:], timeout: TimeInterval? = nil)
    -> (status: Int32, output: Data, error: Data)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
    process.environment = environment(extra)
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    let stdin = input == nil ? nil : Pipe()
    process.standardInput = stdin ?? FileHandle.nullDevice
    if let stdin {
      // A write after the program exits must fail, not end the app with SIGPIPE.
      _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    do { try process.run() } catch { return nil }
    let watchdog = timeout.map { limit in
      let item = DispatchWorkItem {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
          if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit, execute: item)
      return item
    }
    defer { watchdog?.cancel() }
    if let stdin, let input {
      try? stdin.fileHandleForWriting.write(contentsOf: input)
      try? stdin.fileHandleForWriting.close()
    }
    // stderr drains on its own thread, so a chatty program can't fill its pipe while stdout is read. A private queue
    // gets that thread even when every shared one is busy waiting on a run like this (Swift's task threads are).
    let errors = Drain()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue(label: "GitHubCLI.stderr", qos: .utility).async {
      errors.data = stderr.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()
    return (process.terminationStatus, output, errors.data)
  }

  /// A GitHub upload (`AssetLinks.isGitHubAttachment`; anything else is refused) fetched with `gh api -i`, into the file
  /// `destination`, as media only and at most `limit` bytes.
  ///
  /// `-i` makes gh print the final response's status line and headers, a blank line, then the body, so the content type is
  /// known before a byte is kept. The output is read as it arrives: the headers must be a `200` with an `image/*` or
  /// `video/*` type (not SVG) and a length within `limit`; the body goes to a temporary file, and the run ends the moment
  /// it passes `limit` or `timeout`. The file appears only when gh exits 0 and the body is as long as it said.
  ///
  /// The token: gh sends it only to the host it is signed in to. A redirect (an upload is served from another host) does
  /// not carry it along; gh 2.101 was checked against a local server that redirected to a different host name, which
  /// received no `Authorization` header. This still only ever runs for `isGitHubAttachment` URLs. Blocking.
  public static func download(url: URL, to destination: URL, limit: Int64, executable: String? = PullRequests.executable(),
                              timeout: TimeInterval = 120) -> Result<(contentType: String, bytes: Int64), ProofPR.Failure> {
    typealias Failure = ProofPR.Failure
    guard AssetLinks.isGitHubAttachment(url) else { return .failure(Failure("gh only fetches GitHub uploads.")) }
    guard let executable else { return .failure(Failure(PullRequests.Failure.notInstalled.message)) }
    guard let sink = PRMedia.Sink(destination: destination) else { return .failure(Failure("Couldn't start the download.")) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["api", "-i", url.absoluteString]
    process.environment = environment()
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch {
      sink.discard()
      return .failure(Failure(PullRequests.Failure.notInstalled.message))
    }
    // stderr drains on a thread of its own (not a shared queue, which may be busy). After gh is killed it is not waited for
    // for long: a child gh left behind could hold the pipe open.
    let errors = Drain()
    let drained = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      errors.data = stderr.fileHandleForReading.readDataToEndOfFile()
      drained.signal()
    }
    let stop = { if process.isRunning { process.terminate() } }
    let deadline = Date().addingTimeInterval(timeout)
    var timedOut = false

    var pending = Data()
    var headers: PRMedia.Headers?
    var failure: String?
    func keep(_ data: Data) {
      if sink.count + Int64(data.count) > limit { failure = "That file is too big."; return }
      if !sink.write(data) { failure = "Couldn't write the file." }
    }
    // `read(2)`, not `FileHandle.read(upToCount:)`, which waits for the whole count: the headers must be seen as they arrive.
    // `poll` first, a second at a time, so the time limit is kept by this thread and needs no timer.
    let descriptor = stdout.fileHandleForReading.fileDescriptor
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    read: while failure == nil {
      let left = deadline.timeIntervalSinceNow
      if left <= 0 { timedOut = true; break }
      var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&waiting, 1, Int32(min(left, 1) * 1_000) + 1)
      if ready == 0 || (ready < 0 && errno == EINTR) { continue }
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      if count <= 0 { break }
      let chunk = Data(buffer[0..<count])
      if headers != nil { keep(chunk); continue }
      pending.append(chunk)
      switch PRMedia.parseHeaders(pending) {
      case .needMore: continue read
      case .malformed: failure = "GitHub's answer wasn't readable."
      case .headers(let found, let start):
        if found.status != 200 { failure = "GitHub answered \(found.status)." }
        else if PRMedia.mediaType(contentType: found.contentType ?? "") == nil {
          failure = "That isn't an image or video (\((found.contentType ?? "no type").prefix(60)))."
        } else if let length = found.contentLength, length > limit { failure = "That file is too big." }
        else {
          headers = found
          keep(pending.dropFirst(start))
        }
        pending = Data()
      }
    }
    if failure != nil || timedOut { stop() }
    try? stdout.fileHandleForReading.close()
    process.waitUntilExit()
    _ = drained.wait(timeout: .now() + (failure == nil && !timedOut ? 5 : 0.5))

    func abandon(_ message: String) -> Result<(contentType: String, bytes: Int64), Failure> {
      sink.discard()
      return .failure(Failure(message))
    }
    if let failure { return abandon(failure) }
    if timedOut { return abandon("GitHub took too long to send that file.") }
    if process.terminationStatus != 0 {
      return abandon(process.terminationStatus == 4 ? PullRequests.Failure.signedOut.message : firstLine(errors.data))
    }
    guard let headers, let type = headers.contentType else { return abandon("GitHub sent no file.") }
    if let length = headers.contentLength, length != sink.count { return abandon("The download ended early.") }
    let bytes = sink.count
    guard sink.commit() else { return abandon("Couldn't keep the file.") }
    return .success((type, bytes))
  }

  /// The first line a program printed (its error, usually), trimmed; "gh failed" when there's none.
  public static func firstLine(_ data: Data) -> String {
    let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first
    return line.map { $0.trimmingCharacters(in: .whitespaces) } ?? "gh failed"
  }

  private final class Drain: @unchecked Sendable {
    var data = Data()
  }
}
