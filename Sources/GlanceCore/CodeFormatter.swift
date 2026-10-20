import Foundation

/// Format Document in Razor Code: which formatter a file gets, where the project's tools are, and running one on the
/// editor's text. Web languages go to Prettier in the page; the others to the project's own command-line formatter.
public enum CodeFormatter {
  public enum Plan: Equatable, Sendable {
    /// Prettier, in the page, with this parser.
    case prettier(parser: String)
    /// The first of these tools that is installed, fed the text on stdin.
    case tools([Tool])
  }

  /// A command-line formatter that reads the text on stdin and writes the formatted text to stdout.
  public struct Tool: Equatable, Sendable {
    public let name: String
    public let arguments: [String]

    public init(name: String, arguments: [String]) {
      self.name = name
      self.arguments = arguments
    }
  }

  public enum Failure: Error, Equatable {
    /// No formatter for this kind of file, or none of its tools is installed.
    case noFormatter(String)
    /// The formatter ran and refused (usually a syntax error), timed out, or couldn't start.
    case failed(String)

    public var code: String {
      switch self {
      case .noFormatter: return "noFormatter"
      case .failed: return "formatFailed"
      }
    }

    public var message: String {
      switch self {
      case .noFormatter(let message), .failed(let message): return message
      }
    }
  }

  private static let prettierParsers: [String: String] = [
    "js": "babel", "jsx": "babel", "mjs": "babel", "cjs": "babel",
    "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
    "json": "json", "jsonc": "json", "json5": "json5",
    "css": "css", "scss": "scss", "less": "less",
    "html": "html", "htm": "html", "vue": "vue",
    "md": "markdown", "markdown": "markdown", "mdx": "mdx",
    "yaml": "yaml", "yml": "yaml", "graphql": "graphql", "gql": "graphql",
  ]

  /// What formats the file at `path` (absolute; command-line tools get it to find their config). Nil: nothing does.
  /// `exists` answers whether a file exists, for the configs that pick between two Swift formatters and Rust's edition.
  public static func plan(for path: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                          read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Plan? {
    let name = (path as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension.lowercased()
    if ["package.json", "package-lock.json", "composer.json"].contains(name) { return .prettier(parser: "json-stringify") }
    if let parser = prettierParsers[ext] { return .prettier(parser: parser) }
    switch ext {
    case "py", "pyi":
      return .tools([Tool(name: "ruff", arguments: ["format", "--stdin-filename", path, "-"]),
                     Tool(name: "black", arguments: ["-q", "--stdin-filename", path, "-"])])
    case "swift":
      let swiftFormat = Tool(name: "swift-format", arguments: ["format", "--assume-filename", path, "-"])
      let swiftformat = Tool(name: "swiftformat", arguments: ["stdin", "--stdinpath", path, "--quiet"])
      // A project with a `.swiftformat` file uses Nick Lockwood's SwiftFormat; otherwise Apple's swift-format first.
      let nick = nearest(".swiftformat", above: path, exists: exists) != nil
      return .tools(nick ? [swiftformat, swiftFormat] : [swiftFormat, swiftformat])
    case "go":
      return .tools([Tool(name: "gofmt", arguments: [])])
    case "rs":
      return .tools([Tool(name: "rustfmt", arguments: ["--emit", "stdout", "--edition", rustEdition(above: path, exists: exists, read: read)])])
    case "sh", "bash":
      return .tools([Tool(name: "shfmt", arguments: ["--filename", path])])
    default:
      return nil
    }
  }

  /// "Python", "Swift"…, for messages.
  public static func languageName(for path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "py", "pyi": return "Python"
    case "swift": return "Swift"
    case "go": return "Go"
    case "rs": return "Rust"
    case "sh", "bash": return "shell"
    default: return ext.isEmpty ? "this" : "." + ext
    }
  }

  /// What to say when none of the tools is installed.
  public static func missing(_ tools: [Tool], for path: String) -> Failure {
    let names = tools.map(\.name)
    let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " or " + names.last! : names.joined()
    return .noFormatter("No formatter for \(languageName(for: path)) files: install \(list).")
  }

  private static func rustEdition(above path: String, exists: (String) -> Bool, read: (String) -> String?) -> String {
    guard let cargo = nearest("Cargo.toml", above: path, exists: exists), let text = read(cargo),
          let regex = try? NSRegularExpression(pattern: #"(?m)^\s*edition\s*=\s*"(\d{4})""#),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return "2021" }
    return String(text[range])
  }

  /// The nearest file called `name` in the file's folder or above it.
  static func nearest(_ name: String, above path: String, exists: (String) -> Bool) -> String? {
    var folder = (path as NSString).deletingLastPathComponent
    while !folder.isEmpty {
      let candidate = (folder as NSString).appendingPathComponent(name)
      if exists(candidate) { return candidate }
      let parent = (folder as NSString).deletingLastPathComponent
      if parent == folder { return nil }
      folder = parent
    }
    return nil
  }

  // MARK: Finding and running a tool

  /// Where to look for a tool, in order: the project's own installs from the file's folder up to the root
  /// (`node_modules/.bin`, a virtualenv), then the login shell's PATH, then the usual install places.
  public static func searchFolders(file: String, root: String, loginPath: String?, home: String) -> [String] {
    var folders: [String] = []
    let rootPrefix = root.hasSuffix("/") ? root : root + "/"
    var folder = (file as NSString).deletingLastPathComponent
    while folder == root || folder.hasPrefix(rootPrefix) {
      for local in ["node_modules/.bin", ".venv/bin", "venv/bin"] { folders.append((folder as NSString).appendingPathComponent(local)) }
      if folder == root { break }
      folder = (folder as NSString).deletingLastPathComponent
    }
    folders += (loginPath ?? "").split(separator: ":").map(String.init)
    folders += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin", "\(home)/go/bin", "/usr/local/go/bin",
                "\(home)/.local/bin"]
    var seen = Set<String>()
    return folders.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// The project's own Prettier: its `node_modules/.bin/prettier`, from the file's folder up to the root. It knows
  /// the project's plugins, Prettier version and `.prettierignore`, so it wins over the copy in the page.
  public static func projectPrettier(file: String, root: String, isExecutable: (String) -> Bool) -> String? {
    let rootPrefix = root.hasSuffix("/") ? root : root + "/"
    var folder = (file as NSString).deletingLastPathComponent
    while folder == root || folder.hasPrefix(rootPrefix) {
      let candidate = (folder as NSString).appendingPathComponent("node_modules/.bin/prettier")
      if isExecutable(candidate) { return candidate }
      if folder == root { break }
      folder = (folder as NSString).deletingLastPathComponent
    }
    return nil
  }

  /// The project's Prettier reads the text on stdin; `range` (UTF-16 offsets, as the page counts) limits it to a selection.
  public static func prettierArguments(for path: String, range: Range<Int>?) -> [String] {
    var arguments = ["--stdin-filepath", path]
    if let range { arguments += ["--range-start", String(range.lowerBound), "--range-end", String(range.upperBound)] }
    return arguments
  }

  /// The first tool found in `folders`, with its executable.
  public static func find(_ tools: [Tool], in folders: [String], isExecutable: (String) -> Bool) -> (Tool, String)? {
    for tool in tools {
      for folder in folders {
        let candidate = (folder as NSString).appendingPathComponent(tool.name)
        if isExecutable(candidate) { return (tool, candidate) }
      }
    }
    return nil
  }

  /// Runs a formatter: `text` on stdin, the formatted text from stdout. Fails on a non-zero exit (with what it said
  /// on stderr), on output that isn't UTF-8, and after `timeout` seconds.
  public static func run(executable: String, arguments: [String], text: String, directory: String, path: String?,
                         timeout: TimeInterval = 10) -> Result<String, Failure> {
    let name = (executable as NSString).lastPathComponent
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    var environment = ProcessInfo.processInfo.environment
    if let path { environment["PATH"] = path }
    process.environment = environment
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    do { try process.run() } catch { return .failure(.failed("Couldn't start \(name): \(error.localizedDescription)")) }

    // Read both pipes while writing, so a big file can't fill one and deadlock.
    let run = RunState()
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) { run.set(output: stdout.fileHandleForReading.readDataToEndOfFile()) }
    DispatchQueue.global().async(group: group) { run.set(errors: stderr.fileHandleForReading.readDataToEndOfFile()) }
    DispatchQueue.global().async {
      try? stdin.fileHandleForWriting.write(contentsOf: Data(text.utf8))
      try? stdin.fileHandleForWriting.close()
    }
    let timer = DispatchWorkItem { if process.isRunning { run.killed(); process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    process.waitUntilExit()
    timer.cancel()
    group.wait()
    let (output, errors, wasKilled) = run.result

    if wasKilled { return .failure(.failed("\(name) took longer than \(Int(timeout)) seconds.")) }
    guard process.terminationStatus == 0 else {
      let said = String(decoding: errors.isEmpty ? output : errors, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return .failure(.failed("\(name): " + (said.isEmpty ? "exited with status \(process.terminationStatus)" : String(said.prefix(400)))))
    }
    guard let formatted = String(data: output, encoding: .utf8) else { return .failure(.failed("\(name) printed something that isn't text.")) }
    // A formatter that prints nothing for a non-empty file is broken, not asking to empty it.
    if formatted.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .failure(.failed("\(name) printed nothing."))
    }
    return .success(formatted)
  }
}

/// What a formatter run collected, from the threads reading its pipes and its timeout.
private final class RunState: @unchecked Sendable {
  private let lock = NSLock()
  private var output = Data(), errors = Data(), wasKilled = false

  func set(output data: Data) { lock.withLock { output = data } }
  func set(errors data: Data) { lock.withLock { errors = data } }
  func killed() { lock.withLock { wasKilled = true } }
  var result: (Data, Data, Bool) { lock.withLock { (output, errors, wasKilled) } }
}
