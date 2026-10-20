import Foundation

/// The first message a shell sends: who it is, what it took over and what it found.
public struct ShellHello: Equatable, Sendable {
  public let protocolVersion: Int
  /// The surface's UUID Studio put in `GLANCE_SHELL_TAB`.
  public let tab: String
  public let pid: Int32
  public let tty: String
  public let zshVersion: String
  /// The keys the plugin bound (`tab`, `up`, `ctrl-r`, `right`, …).
  public let keys: Set<String>
  /// Other plugins it found that own a key Glance would take (`fzf-tab`, `zsh-autosuggestions`, `atuin`, …).
  public let plugins: Set<String>
  /// The shell's `$PATH`, for finding the tools whose completions Studio generates.
  public let path: String
  /// The shell's history file, for the one-time import (`~/.zsh_history` when an older plugin didn't say).
  public let historyFile: String?

  public init(protocolVersion: Int, tab: String, pid: Int32, tty: String, zshVersion: String, keys: Set<String>,
              plugins: Set<String>, path: String, historyFile: String? = nil) {
    self.protocolVersion = protocolVersion
    self.tab = tab
    self.pid = pid
    self.tty = tty
    self.zshVersion = zshVersion
    self.keys = keys
    self.plugins = plugins
    self.path = path
    self.historyFile = historyFile
  }
}

/// What a shell asks Studio to open.
public enum ShellOpen: String, Sendable {
  case history, search, ask
  /// ⏎ on a line that may be plain English: Studio turns it into a command, or has the shell run it as typed.
  case translate
}

/// A message from a shell's plugin to Studio.
public enum ShellEvent: Equatable, Sendable {
  case hello(ShellHello)
  /// A new prompt is waiting for input in `folder`.
  case prompt(seq: Int, folder: String)
  /// The input line changed: its text and the cursor (in characters).
  case line(seq: Int, cursor: Int, text: String)
  /// A command started.
  case exec(folder: String, start: Double, command: String)
  /// The command that started last ended.
  case done(exit: Int, end: Double)
  /// Tab found several candidates: `total` of them, the `cand` rows follow (at most 2,000), then `end`.
  case candidates(request: Int, seq: Int, total: Int)
  case candidate(request: Int, CompletionCandidate)
  case candidatesEnd(request: Int)
  case open(ShellOpen, seq: Int)
  /// The shell's names of one kind (`commands`, `aliases`, `functions`, `builtins`): light completion, error marks.
  case names(kind: String, names: [String])
  /// The answer to `ping`: the line as the shell has it now, with its ghost text.
  case state(seq: Int, cursor: Int, text: String, ghost: String)
  case bye
  /// Studio's `BROWSER` helper (DevServerLinks), not a shell: open `url`, from the terminal `tab` (its
  /// `GLANCE_SHELL_TAB`, empty when unknown). It needs no hello; Studio answers `browsed` and closes the connection.
  case browse(tab: String, url: String)

  public init?(line: String) {
    let f = ShellWire.fields(line)
    func int(_ i: Int) -> Int? { i < f.count ? Int(f[i]) : nil }
    func double(_ i: Int) -> Double? { i < f.count ? Double(f[i]) : nil }
    switch f.first {
    case "hello":
      guard f.count >= 9, let version = int(1), let pid = Int32(f[3]) else { return nil }
      func set(_ s: String) -> Set<String> { Set(s.split(separator: ",").map(String.init)) }
      self = .hello(ShellHello(protocolVersion: version, tab: f[2], pid: pid, tty: f[4], zshVersion: f[5],
                               keys: set(f[6]), plugins: set(f[7]), path: f[8],
                               historyFile: f.count > 9 && !f[9].isEmpty ? f[9] : nil))
    case "prompt":
      guard f.count >= 3, let seq = int(1) else { return nil }
      self = .prompt(seq: seq, folder: f[2])
    case "line":
      guard f.count >= 4, let seq = int(1), let cursor = int(2) else { return nil }
      self = .line(seq: seq, cursor: cursor, text: f[3])
    case "exec":
      guard f.count >= 4, let start = double(2) else { return nil }
      self = .exec(folder: f[1], start: start, command: f[3])
    case "done":
      guard f.count >= 3, let exit = int(1), let end = double(2) else { return nil }
      self = .done(exit: exit, end: end)
    case "candidates":
      guard f.count >= 4, let request = int(1), let seq = int(2), let total = int(3) else { return nil }
      self = .candidates(request: request, seq: seq, total: total)
    case "cand":
      guard f.count >= 3, let request = int(1), let candidate = CompletionCandidate(fields: f[2...]) else { return nil }
      self = .candidate(request: request, candidate)
    case "end":
      guard let request = int(1) else { return nil }
      self = .candidatesEnd(request: request)
    case "open":
      guard f.count >= 3, let what = ShellOpen(rawValue: f[1]), let seq = int(2) else { return nil }
      self = .open(what, seq: seq)
    case "names":
      guard f.count >= 2 else { return nil }
      self = .names(kind: f[1], names: Array(f.dropFirst(2)))
    case "state":
      guard f.count >= 5, let seq = int(1), let cursor = int(2) else { return nil }
      self = .state(seq: seq, cursor: cursor, text: f[3], ghost: f[4])
    case "bye":
      self = .bye
    case "browse":
      guard f.count >= 3, !f[2].isEmpty else { return nil }
      self = .browse(tab: f[1], url: f[2])
    default:
      return nil
    }
  }
}

/// An error mark on the input line: characters `start..<end` (zsh's units) and why.
public struct ShellMark: Equatable, Sendable {
  public let start: Int
  public let end: Int
  public let kind: String

  public init(start: Int, end: Int, kind: String) {
    self.start = start
    self.end = end
    self.kind = kind
  }
}

/// A message from Studio to a shell's plugin. Each carries the line's seq (or a request id) it was made for; the shell
/// drops it when the line has moved on.
public enum ShellCommand: Equatable, Sendable {
  /// The features that are on (`SuggestionFeature` raw values).
  case config(features: [String])
  /// Insert candidate `index` of the Tab list `request` with zsh's own rules.
  case accept(request: Int, index: Int)
  /// Run the completion again at the cursor (a folder was opened, a cut-off list narrowed).
  case complete(seq: Int)
  case replace(seq: Int, text: String, cursor: Int)
  /// Put `text` on the line and run it (Studio writes the wake key after it).
  case run(seq: Int, text: String)
  /// Ghost text after the line; `cursor` is where accepting it leaves the cursor (nil: at the end).
  case suggest(seq: Int, text: String, cursor: Int?)
  case marks(seq: Int, ranges: [ShellMark])
  /// Asks for `state`.
  case ping
  /// Studio has nothing to show for ↑ (`up`) or ⌃R (`search`): the shell does what the key did before.
  case fallback(seq: Int, key: String)
  /// The answer to `browse`: whether Studio opened the address (else the helper opens it with macOS).
  case browsed(Bool)

  public var line: String {
    switch self {
    case .config(let features): ShellWire.line(["config", features.joined(separator: ",")])
    case .accept(let request, let index): ShellWire.line(["accept", String(request), String(index)])
    case .complete(let seq): ShellWire.line(["complete", String(seq)])
    case .replace(let seq, let text, let cursor): ShellWire.line(["replace", String(seq), text, String(cursor)])
    case .run(let seq, let text): ShellWire.line(["run", String(seq), text])
    case .suggest(let seq, let text, let cursor):
      ShellWire.line(["suggest", String(seq), text, cursor.map(String.init) ?? ""])
    case .marks(let seq, let ranges):
      ShellWire.line(["marks", String(seq), ranges.map { "\($0.start)-\($0.end)-\($0.kind)" }.joined(separator: ",")])
    case .ping: ShellWire.line(["ping"])
    case .fallback(let seq, let key): ShellWire.line(["fallback", String(seq), key])
    case .browsed(let opened): ShellWire.line(["browsed", opened ? "yes" : "no"])
    }
  }
}

/// Which shells Studio takes (spec "The bridge", "Joining"): one that speaks this protocol, is the process on the other
/// end of the socket, is the tab's foreground process, and runs on the tab's own terminal. A nested zsh in the same tab
/// passes too (it is in the foreground on the same terminal); tmux panes (other terminals) and anything else don't.
public enum ShellBridgePolicy {
  public static let protocolVersion = 1

  public static func accepts(_ hello: ShellHello, peerPID: Int32, foregroundPID: Int?, tty: String?) -> Bool {
    hello.protocolVersion == protocolVersion && peerPID > 0 && peerPID == hello.pid
      && foregroundPID == Int(hello.pid) && tty != nil && tty == hello.tty
  }
}
