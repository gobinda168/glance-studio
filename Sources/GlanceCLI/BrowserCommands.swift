import Darwin
import Foundation
import GlanceCore

/// `glance browser …` (spec 2026-10-12-web-logs-design.md): the console and network log of a page open in Glance
/// Studio's Browser, in the terminal. Studio writes the log; this reads it, for a person (colors, `-f` to follow) and
/// for Claude Code (plain text when piped, `--json` for one entry per line).
enum BrowserCommands {
  static let usage = """
    usage: glance browser <command> [options]

      tabs                          the Browser tabs being logged
      console                       console output (log, info, warn, error, debug) and uncaught errors
      network                       fetch and XHR requests: method, address, status, time
      watch                         console and network together, following
      request <id>                  one request in full: headers, payload, response

    options:
      --tab <match>                 a tab: its key (tab:3, 3) or part of its address or title (default: the one in front)
      -f, --follow                  keep printing as the page logs
      --errors                      console errors and failed requests (4xx, 5xx, no answer) only
      --level <debug|log|warn|error>  console messages at this level or above
      --method <GET|POST|…>         requests with this method only
      --grep <text>                 entries containing text (messages, addresses, bodies)
      -n <count>                    the latest count entries (default 50; 0 for all)
      -x, --expand                  show each request in full, not as one row
      --json                        one JSON object per line
      --no-color                    plain text

    Passwords, tokens, cookies and authorization headers are masked before Studio writes the log.
    """

  struct Options {
    var tab: String?
    var follow = false
    var filter = WebLogFilter()
    var count = 50
    var expand = false
    var json = false
    var color = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    var positional: [String] = []
  }

  static func run(_ arguments: [String]) -> Int32 {
    guard let command = arguments.first, !["-h", "--help", "help"].contains(command) else {
      print(usage)
      return arguments.isEmpty ? 2 : 0
    }
    var options = Options()
    if command == "watch" { options.follow = true; options.count = 20 }
    switch parse(Array(arguments.dropFirst()), into: &options) {
    case .failure(let message):
      FileHandle.standardError.write(Data("glance browser: \(message)\n".utf8))
      return 2
    case .success: break
    }
    let folder = environmentFolder()
    switch command {
    case "tabs": return tabs(in: folder, options)
    case "console":
      options.filter.network = false
      return list(in: folder, options)
    case "network":
      options.filter.console = false
      options.filter.navigation = false
      return list(in: folder, options)
    case "watch": return list(in: folder, options)
    case "request": return request(in: folder, options)
    default:
      FileHandle.standardError.write(Data("glance browser: unknown command \"\(command)\"\n\(usage)\n".utf8))
      return 2
    }
  }

  // MARK: Arguments

  private enum Parsed { case success, failure(String) }

  private static func parse(_ arguments: [String], into options: inout Options) -> Parsed {
    var index = 0
    func value(_ name: String) -> String? {
      index += 1
      return index < arguments.count ? arguments[index] : nil
    }
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--tab":
        guard let tab = value(argument) else { return .failure("--tab needs a tab") }
        options.tab = tab
      case "-f", "--follow": options.follow = true
      case "--errors", "--failed": options.filter.errorsOnly = true
      case "--level":
        guard let level = value(argument), ["debug", "log", "info", "warn", "error"].contains(level) else {
          return .failure("--level is one of debug, log, warn, error")
        }
        options.filter.minLevel = level
      case "--method":
        guard let method = value(argument) else { return .failure("--method needs a method") }
        options.filter.method = method
      case "--grep":
        guard let text = value(argument) else { return .failure("--grep needs text") }
        options.filter.text = text
      case "-n":
        guard let text = value(argument), let count = Int(text), count >= 0 else {
          return .failure("-n needs a number")
        }
        options.count = count
      case "-x", "--expand": options.expand = true
      case "--json": options.json = true
      case "--no-color": options.color = false
      default:
        if argument.hasPrefix("-") { return .failure("unknown option \(argument)") }
        options.positional.append(argument)
      }
      index += 1
    }
    return .success
  }

  private static func environmentFolder() -> URL {
    if let path = ProcessInfo.processInfo.environment["GLANCE_BROWSER_LOGS"], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return WebLogFiles.folder()
  }

  // MARK: Commands

  private static func tabs(in folder: URL, _ options: Options) -> Int32 {
    let tabs = WebLogFiles.readIndex(in: folder)
    guard !tabs.isEmpty else { return report(noTabs) }
    let front = tabs.max { $0.focused < $1.focused }?.key
    if options.json {
      for tab in tabs { printJSON(tab) }
      return 0
    }
    for tab in tabs.sorted(by: { $0.focused > $1.focused }) {
      let marker = tab.key == front ? "*" : " "
      let title = tab.title.isEmpty ? "" : "  " + tab.title
      let key = tab.key.count >= 8 ? tab.key : tab.key + String(repeating: " ", count: 8 - tab.key.count)
      print("\(marker) \(key)  \(tab.url)\(title)")
    }
    return 0
  }

  private static func list(in folder: URL, _ options: Options) -> Int32 {
    guard let tab = resolve(options, in: folder) else { return report(noTabs, tabMissing: options.tab) }
    let file = folder.appendingPathComponent(tab.file)
    let format = WebLogFormat(color: options.color, width: options.json ? nil : terminalWidth())
    if !options.json && isatty(STDOUT_FILENO) != 0 {
      FileHandle.standardError.write(Data("\(tab.key)  \(tab.url)\n".utf8))
    }

    var shown = WebLogReader.load(file: file).filter(options.filter.matches)
    if options.count > 0 { shown = Array(shown.suffix(options.count)) }
    for entry in shown { emit(entry, options, format) }
    guard options.follow else {
      if shown.isEmpty { FileHandle.standardError.write(Data("Nothing logged yet.\n".utf8)) }
      return 0
    }

    // Follow: a request prints once, when it ends; messages and page changes print at once.
    var printed = Set(shown.filter { !$0.isPending }.map(\.id))
    var tail = LogTail(file: file)
    tail.skipToEnd()
    var existed = FileManager.default.fileExists(atPath: file.path)
    while true {
      usleep(250_000)
      if !FileManager.default.fileExists(atPath: file.path) {
        if existed {
          FileHandle.standardError.write(Data("The tab closed.\n".utf8))
          return 0
        }
        continue
      }
      existed = true
      for entry in tail.poll() where !entry.isPending && !printed.contains(entry.id) && options.filter.matches(entry) {
        printed.insert(entry.id)
        emit(entry, options, format)
      }
    }
  }

  private static func request(in folder: URL, _ options: Options) -> Int32 {
    guard let text = options.positional.first, let id = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text)
    else {
      FileHandle.standardError.write(Data("glance browser request needs a request number, such as 12 or #12\n".utf8))
      return 2
    }
    guard let tab = resolve(options, in: folder) else { return report(noTabs, tabMissing: options.tab) }
    let entries = WebLogReader.load(file: folder.appendingPathComponent(tab.file))
    guard let entry = entries.first(where: { $0.id == id && $0.kind == .network }) else {
      FileHandle.standardError.write(
        Data("No request #\(id) in \(tab.key). `glance browser network` lists them.\n".utf8))
      return 1
    }
    if options.json {
      printJSON(entry)
    } else {
      print(WebLogFormat(color: options.color, width: nil).detail(entry))
    }
    return 0
  }

  // MARK: Helpers

  private static let noTabs = "No Browser tab is being logged. Open a page in Glance Studio's Browser (a dev server's "
    + "page opens there on its own) and run this again."

  private static func resolve(_ options: Options, in folder: URL) -> WebLogTab? {
    WebLogReader.tab(options.tab, in: WebLogFiles.readIndex(in: folder))
  }

  private static func report(_ message: String, tabMissing: String? = nil) -> Int32 {
    let text = tabMissing.map { "No Browser tab matches \"\($0)\". `glance browser tabs` lists them." } ?? message
    FileHandle.standardError.write(Data((text + "\n").utf8))
    return 1
  }

  private static func emit(_ entry: WebLogEntry, _ options: Options, _ format: WebLogFormat) {
    if options.json {
      printJSON(entry)
    } else if options.expand && entry.kind == .network {
      print(format.detail(entry) + "\n")
    } else {
      print(format.line(entry))
    }
    fflush(stdout)
  }

  private static func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
  }

  private static func terminalWidth() -> Int? {
    guard isatty(STDOUT_FILENO) != 0 else { return nil }
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
    return Int(size.ws_col)
  }
}

/// Reads what is appended to a log file; starts over when the file was rotated.
struct LogTail {
  let file: URL
  private var offset: UInt64 = 0
  private var partial = Data()

  init(file: URL) { self.file = file }

  mutating func skipToEnd() {
    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    offset = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  mutating func poll() -> [WebLogEntry] {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return [] }
    if end < offset {
      offset = 0
      partial = Data()
    }
    guard end > offset, (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else {
      return []
    }
    offset += UInt64(data.count)
    partial.append(data)
    // Only whole lines: the writer may be in the middle of one.
    guard let last = partial.lastIndex(of: 0x0A) else { return [] }
    let whole = partial[partial.startIndex...last]
    partial = Data(partial[partial.index(after: last)...])
    return WebLogReader.parse(String(decoding: whole, as: UTF8.self))
  }
}
