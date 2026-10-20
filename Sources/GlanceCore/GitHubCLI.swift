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
  public static func run(_ executable: String?, _ arguments: [String], input: Data? = nil, folder: String? = nil)
    -> Result<Data, PullRequests.Failure> {
    guard let executable, let result = execute(executable, arguments, input: input, folder: folder) else {
      return .failure(.notInstalled)
    }
    return outcome(status: result.status, output: result.output, error: result.error)
  }

  /// Runs a program (gh, git) to the end: its exit status, stdout and stderr; nil when it can't start. `environment`
  /// adds to Glance's own (git's GIT_INDEX_FILE, say).
  public static func execute(_ executable: String, _ arguments: [String], input: Data? = nil, folder: String? = nil,
                             environment extra: [String: String] = [:]) -> (status: Int32, output: Data, error: Data)? {
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

  /// The first line a program printed (its error, usually), trimmed; "gh failed" when there's none.
  public static func firstLine(_ data: Data) -> String {
    let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first
    return line.map { $0.trimmingCharacters(in: .whitespaces) } ?? "gh failed"
  }

  private final class Drain: @unchecked Sendable {
    var data = Data()
  }
}
