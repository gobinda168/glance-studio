import Foundation
import GlanceCore

/// What `glance setup` puts into Claude Code: the hook and status line scripts (plan usage), the output style, and the
/// hook and statusLine entries in ~/.claude/settings.json. The CLI shows the plan and asks; Studio installs it once on
/// a new Mac (`ClaudeAutoSetup`).
public enum ClaudeSetup {
  public struct Paths: Sendable {
    public let claude: URL
    public let settings: URL
    public let backup: URL
    public let notifyScript: URL
    public let statusScript: URL
    public let innerJSON: URL
    public let innerCommand: URL
    public let usage: URL
    public let style: URL
    /// The style before Glance Humanize.
    public let legacyStyle: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
      claude = home.appendingPathComponent(".claude")
      settings = claude.appendingPathComponent("settings.json")
      backup = claude.appendingPathComponent("settings.json.glance-backup")
      notifyScript = claude.appendingPathComponent("glance/notify.sh")
      statusScript = claude.appendingPathComponent("glance/statusline.sh")
      innerJSON = claude.appendingPathComponent("glance/statusline.inner.json")
      innerCommand = claude.appendingPathComponent("glance/statusline.inner")
      usage = claude.appendingPathComponent("glance/usage.json")
      style = claude.appendingPathComponent("output-styles/humanize.md")
      legacyStyle = claude.appendingPathComponent("output-styles/explainer.md")
    }
  }

  /// The settings before and after, for the CLI to show; `apply` writes them.
  public struct Plan {
    public let install: Bool
    public let before: [String: Any]
    public let after: [String: Any]
    /// The user's own statusLine that Glance wraps, saved beside the script.
    public let original: [String: Any]?
    /// The statusLine isn't a command, so Glance leaves it alone and there's no plan usage.
    public let statusLineUnsupported: Bool
  }

  public enum Failure: LocalizedError {
    case invalidSettings(URL)

    public var errorDescription: String? {
      switch self {
      case .invalidSettings(let url): "\(url.path) isn't valid JSON; fix it first."
      }
    }
  }

  public static func plan(install: Bool, paths: Paths = Paths()) throws -> Plan {
    let settings = try readSettings(paths)
    guard install else {
      let saved = FileManager.default.contents(atPath: paths.innerJSON.path)
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      let after = StatusLineSetup.uninstall(from: HookSetup.uninstall(from: settings), restoring: saved)
      return Plan(install: false, before: settings, after: after, original: nil, statusLineUnsupported: false)
    }
    let hooked = HookSetup.install(into: settings, command: HookSetup.command(forScript: paths.notifyScript.path))
    let status = StatusLineSetup.install(into: hooked, command: HookSetup.command(forScript: paths.statusScript.path))
    return Plan(install: true, before: settings, after: status.settings, original: status.original,
                statusLineUnsupported: status.unsupported)
  }

  /// Backs up settings.json, writes the plan's settings, and copies (or removes) the scripts and the output style.
  public static func apply(_ plan: Plan, paths: Paths = Paths()) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: paths.settings.path) {
      try? fm.removeItem(at: paths.backup)
      try fm.copyItem(at: paths.settings, to: paths.backup)
    }
    try fm.createDirectory(at: paths.claude, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: plan.after, options: writing).write(to: paths.settings, options: .atomic)
    guard plan.install else {
      for url in [paths.notifyScript, paths.statusScript, paths.innerJSON, paths.innerCommand, paths.usage, paths.style,
                  paths.legacyStyle] { try? fm.removeItem(at: url) }
      return
    }
    try copyScript(Resources.notifyScript, to: paths.notifyScript)
    try replace(paths.style, with: Resources.outputStyle)
    try? fm.removeItem(at: paths.legacyStyle)
    guard !plan.statusLineUnsupported else { return }
    try copyScript(Resources.statusLineScript, to: paths.statusScript)
    if let original = plan.original, let inner = StatusLineSetup.innerCommand(of: original) {
      try JSONSerialization.data(withJSONObject: original, options: writing).write(to: paths.innerJSON, options: .atomic)
      try Data(inner.utf8).write(to: paths.innerCommand, options: .atomic)
    }
  }

  /// Whether Claude Code's settings already have Glance's hooks.
  public static func isInstalled(paths: Paths = Paths()) -> Bool {
    (try? readSettings(paths)).map(HookSetup.isInstalled(in:)) ?? false
  }

  /// Copies this build's scripts over installed ones that differ, so an update reaches Claude Code. Never adds a
  /// script that isn't there (unsetup stays undone).
  public static func refreshScripts(paths: Paths = Paths()) {
    let fm = FileManager.default
    for (source, destination) in [(Resources.notifyScript, paths.notifyScript), (Resources.statusLineScript, paths.statusScript)]
    where fm.fileExists(atPath: destination.path) && !fm.contentsEqual(atPath: source.path, andPath: destination.path) {
      try? copyScript(source, to: destination)
    }
  }

  /// Runs `claude` (no shell) with the login shell's PATH: its exit status and output.
  public static func runClaude(_ executable: String, path: String?, _ arguments: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    if let path { environment["PATH"] = path }
    environment["CLAUDECODE"] = nil
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return (127, error.localizedDescription) }
    // Read to the end first: a full pipe would otherwise keep claude from exiting.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static let writing: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

  private static func readSettings(_ paths: Paths) throws -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: paths.settings.path), !data.isEmpty else { return [:] }
    guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Failure.invalidSettings(paths.settings)
    }
    return parsed
  }

  private static func copyScript(_ source: URL, to destination: URL) throws {
    try replace(destination, with: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
  }

  private static func replace(_ destination: URL, with source: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: destination)
    try fm.copyItem(at: source, to: destination)
  }
}

/// Sets Claude Code up for Glance on a new Mac without asking: what `glance setup` does (hooks, plan usage, output
/// style) plus the "glance" MCP server. Once per Mac: after that, a `glance unsetup` stays undone, and launches only
/// bring the installed scripts up to date.
@MainActor
public enum ClaudeAutoSetup {
  private static let doneKey = "glance.claudeSetup.autoInstalled"
  private static var running = false

  /// At launch, and again once onboarding finds Claude Code. Waits for Claude Code to be installed.
  public static func run() {
    if UserDefaults.standard.bool(forKey: doneKey) {
      DispatchQueue.global(qos: .utility).async { ClaudeSetup.refreshScripts() }
      if !UserDefaults.standard.bool(forKey: "glance.claudeSetup.browserMCPAdded") {
        ClaudeOneShot.locateWithPath { found in
          guard let found else { return }
          let glance = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/glance").path
          DispatchQueue.global(qos: .utility).async { addBrowserServer(claude: found.executable, path: found.path, glance: glance) }
        }
      }
      return
    }
    guard !running else { return }
    running = true
    ClaudeOneShot.locateWithPath { found in
      guard let found else { running = false; return } // no Claude Code yet: the next launch or onboarding tries again
      let glance = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/glance").path
      DispatchQueue.global(qos: .utility).async {
        let done = install(claude: found.executable, path: found.path, glance: glance)
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            running = false
            if done { UserDefaults.standard.set(true, forKey: doneKey) }
          }
        }
      }
    }
  }

  /// True once Claude Code has Glance's hooks (the MCP server is best effort: Settings can add it later).
  nonisolated private static func install(claude: String, path: String?, glance: String) -> Bool {
    do {
      if !ClaudeSetup.isInstalled() {
        try ClaudeSetup.apply(ClaudeSetup.plan(install: true))
        NSLog("Glance: set Claude Code up (hooks, plan usage, output style)")
      }
    } catch {
      NSLog("Glance: couldn't set Claude Code up: \(error.localizedDescription)")
      return false
    }
    let claudeJSON = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude.json")
    // Only when there's none: a "glance" server that isn't Glance's is the user's.
    if MCPSetup.registered(claudeJSON: claudeJSON) == .missing, FileManager.default.isExecutableFile(atPath: glance) {
      let (status, output) = ClaudeSetup.runClaude(claude, path: path, MCPSetup.addArguments(glancePath: glance))
      if status != 0 { NSLog("Glance: couldn't add the glance MCP server: \(output)") }
    }
    addBrowserServer(claude: claude, path: path, glance: glance)
    return true
  }

  /// Glance browser's MCP server ("glance-browser"), once per Mac (Macs set up before it existed get it at their next
  /// launch); a server of that name that isn't Glance's is the user's, and a removed one stays removed.
  nonisolated private static func addBrowserServer(claude: String, path: String?, glance: String) {
    let key = "glance.claudeSetup.browserMCPAdded"
    guard !UserDefaults.standard.bool(forKey: key), FileManager.default.isExecutableFile(atPath: glance) else { return }
    let claudeJSON = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude.json")
    if BrowserMCPSetup.registered(claudeJSON: claudeJSON) == .missing {
      let (status, output) = ClaudeSetup.runClaude(claude, path: path, BrowserMCPSetup.addArguments(glancePath: glance))
      guard status == 0 else { return NSLog("Glance: couldn't add the glance-browser MCP server: \(output)") }
    }
    UserDefaults.standard.set(true, forKey: key)
  }
}
