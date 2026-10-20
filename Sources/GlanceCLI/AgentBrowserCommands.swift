import Darwin
import Foundation
import GlanceCore
import GlanceKit

/// `glance agent-browser …` (spec 2026-10-14-agent-browser-design.md): the Glance browser, the headless Chromium Glance
/// Studio shows in a floating panel. `mcp` is the `glance-browser` MCP server `glance setup` registers: the official
/// Playwright MCP, driving that browser through Studio's CDP port.
enum AgentBrowserCommands {
  static let usage = """
    usage: glance agent-browser <command>

      mcp       the glance-browser MCP server for Claude Code (Playwright MCP on the Glance browser)
      install   install Playwright and Chromium for the Glance browser (the first run of mcp does it too)
      status    the ports, whether Glance Studio is listening, and what's installed
      serve     run the ports and the broker without Studio (debugging; ^C to quit)
    """

  static func run(_ arguments: [String]) -> Int32 {
    guard let command = arguments.first, !["-h", "--help", "help"].contains(command) else {
      print(usage)
      return arguments.isEmpty ? 2 : 0
    }
    switch command {
    case "mcp": return mcp()
    case "install": return install(quiet: false) ? 0 : 1
    case "status": return status()
    case "serve": return serve()
    default:
      FileHandle.standardError.write(Data("glance agent-browser: unknown command \"\(command)\"\n\(usage)\n".utf8))
      return 2
    }
  }

  private static let home = NSHomeDirectory()

  private static func say(_ text: String) {
    FileHandle.standardError.write(Data("glance agent-browser: \(text)\n".utf8))
  }

  private static func ports() -> AgentBrowserPorts.Pair? {
    (try? Data(contentsOf: URL(fileURLWithPath: AgentBrowserPackages.portsFile(home: home))))
      .flatMap { try? JSONDecoder().decode(AgentBrowserPorts.Pair.self, from: $0) }
  }

  private static func listening(_ port: Int) -> Bool {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { return false }
    defer { Darwin.close(socket) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
  }

  /// Glance's pinned Playwright, the Playwright MCP and headless Chromium, through the broker's `install`. Progress
  /// goes to stderr (stdout is the MCP's).
  private static func install(quiet: Bool) -> Bool {
    guard let node = NodeLocator.find(loginPath: ProcessInfo.processInfo.environment["PATH"]) else {
      say(NodeLocator.missing)
      return false
    }
    if !quiet { say("installing Playwright \(AgentBrowserPackages.playwrightCore) and Chromium…") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node.node)
    process.arguments = [Resources.agentBrowserScript.path, "install", "--home", AgentBrowserPackages.folder(home: home)]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = node.path
    process.environment = environment
    process.standardOutput = FileHandle.standardError
    process.standardError = FileHandle.standardError
    do { try process.run() } catch {
      say("couldn't run node: \(error.localizedDescription)")
      return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }

  /// The broker writes .chromium-ok last, once Playwright, the MCP and Chromium are all in place.
  private static var installed: Bool {
    FileManager.default.fileExists(atPath: (AgentBrowserPackages.folder(home: home) as NSString).appendingPathComponent(".chromium-ok"))
  }

  private static func mcp() -> Int32 {
    guard let ports = ports() else {
      say("open Glance Studio once: it sets up the Glance browser")
      return 1
    }
    let script = AgentBrowserPackages.mcpScript(home: home)
    if !installed {
      guard install(quiet: false) else { return 1 }
    }
    guard let node = NodeLocator.find(loginPath: ProcessInfo.processInfo.environment["PATH"]) else {
      say(NodeLocator.missing)
      return 1
    }
    if !listening(ports.cdp) { say("Glance Studio isn't running, so the Glance browser isn't either; open Studio and try again") }
    setenv("PATH", node.path, 1)
    let arguments = [node.node, script, "--cdp-endpoint", "http://127.0.0.1:\(ports.cdp)", "--cdp-timeout", "180000",
                     "--output-dir", (NSTemporaryDirectory() as NSString).appendingPathComponent("glance-browser")]
    var argv = arguments.map { strdup($0) } + [nil]
    execv(node.node, &argv)
    say("couldn't start the Playwright MCP: \(String(cString: strerror(errno)))")
    return 1
  }

  private static func status() -> Int32 {
    guard let ports = ports() else {
      print("Glance browser: not set up (Glance Studio sets it up when it starts)")
      return 1
    }
    print("Playwright clients  ws://127.0.0.1:\(ports.client)/  \(listening(ports.client) ? "listening" : "not listening")")
    print("CDP (Claude's MCP)  http://127.0.0.1:\(ports.cdp)  \(listening(ports.cdp) ? "listening" : "not listening")")
    print("Playwright MCP      \(installed ? "installed" : "not installed yet") (\(AgentBrowserPackages.folder(home: home)))")
    return 0
  }

  private static func serve() -> Int32 {
    MainActor.assumeIsolated {
      let broker = AgentBrowserBroker.shared
      broker.startListening()
      guard let ports = broker.ports else {
        say("couldn't listen")
        return
      }
      print("PW_TEST_CONNECT_WS_ENDPOINT=ws://127.0.0.1:\(ports.client)/  CDP http://127.0.0.1:\(ports.cdp)")
      var last = ""
      Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        MainActor.assumeIsolated {
          let line = "\(broker.state)  " + broker.browsers.map { "\($0.kind.rawValue) \($0.version) :\($0.cdpPort)" }.joined(separator: ", ")
          if line != last { print(line); last = line }
        }
      }
    }
    signal(SIGINT) { _ in exit(0) }
    RunLoop.main.run()
    return 0
  }
}
