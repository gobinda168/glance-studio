import Foundation
import GlanceCore
import GlanceKit

/// `Glance setup` / `Glance unsetup`: installs or removes the hook script, the status line script (plan usage), the
/// output style and the hook and statusLine entries in ~/.claude/settings.json. Shows exactly what changes and asks
/// before writing anything.
enum SetupCommand {
  static func run(install: Bool) -> Int32 {
    let paths = ClaudeSetup.Paths()
    let plan: ClaudeSetup.Plan
    do { plan = try ClaudeSetup.plan(install: install, paths: paths) } catch {
      print("✗ \(error.localizedDescription) Nothing was changed.")
      return 1
    }

    print(install ? "Glance setup will:" : "Glance unsetup will:")
    if install {
      print("  • copy the hook script     → \(paths.notifyScript.path)")
      print("  • copy the status line script (plan usage) → \(paths.statusScript.path)")
      print("  • copy the output style    → \(paths.style.path)")
      print("  • add the \"glance\" MCP server for Claude Code (claude mcp add-json --scope user glance)")
      print("  • add the \"glance-browser\" MCP server: the Glance browser, shown in Glance Studio")
    } else {
      print("  • remove \(paths.notifyScript.path)")
      print("  • remove \(paths.statusScript.path), \(paths.usage.path) and the saved status line")
      print("  • remove \(paths.style.path)")
      print("  • remove the \"glance\" MCP server for Claude Code (claude mcp remove --scope user glance)")
      print("  • remove the \"glance-browser\" MCP server")
    }
    print("  • update hooks and statusLine in \(paths.settings.path) (backup: settings.json.glance-backup)\n")
    print("hooks before:\n\(pretty(plan.before["hooks"]))\n")
    print("hooks after:\n\(pretty(plan.after["hooks"]))\n")
    print("statusLine before:\n\(pretty(plan.before["statusLine"]))\n")
    print("statusLine after:\n\(pretty(plan.after["statusLine"]))\n")
    if plan.statusLineUnsupported {
      print("note: your statusLine isn't a command, so Glance leaves it alone and there will be no plan usage strip.\n")
    } else if install, plan.original != nil {
      print("note: your statusLine keeps working: Glance's script runs it and shows its output unchanged.\n")
    }
    print("Apply? [y/N] ", terminator: "")
    guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
      print("Nothing was changed.")
      return 0
    }

    do {
      try ClaudeSetup.apply(plan, paths: paths)
      if install {
        print("✓ Done. In Claude Code pick Glance Humanize with /output-style, then keep Glance running.")
        if !plan.statusLineUnsupported {
          print("  Plan usage appears in Glance Studio's top bar after Claude Code's next response (claude.ai plans).")
        }
      } else {
        print("✓ Removed.")
      }
      registerMCP(install: install)
      return 0
    } catch {
      print("✗ \(error.localizedDescription)")
      return 1
    }
  }

  /// The orb channel's MCP server, through `claude mcp` (it owns ~/.claude.json). A missing `claude` or a failure is
  /// reported; hooks are set up either way.
  private static func registerMCP(install: Bool) {
    // The running binary's real path (argv[0] may be a bare name found on PATH). Removing doesn't need it.
    let glancePath = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? ""
    if install, !FileManager.default.isExecutableFile(atPath: glancePath) {
      print("note: couldn't find the running glance binary, so the \"glance\" MCP server was not added.")
      return
    }
    registerBrowserMCP(install: install, glancePath: glancePath)
    let arguments = install ? MCPSetup.addArguments(glancePath: glancePath) : MCPSetup.removeArguments
    if install {
      // add-json refuses a name that exists: remove ours first, quietly.
      _ = runClaude(MCPSetup.removeArguments)
    }
    let (status, output) = runClaude(arguments)
    if status == 0 {
      print(install ? "✓ Claude Code sessions can reach you through Glance (MCP server \"glance\")."
                    : "✓ Removed the \"glance\" MCP server.")
    } else {
      print("note: couldn't \(install ? "add" : "remove") the \"glance\" MCP server: \(output)")
      print("      run: claude \(arguments.map { $0.contains(" ") || $0.contains("\"") ? "'\($0)'" : $0 }.joined(separator: " "))")
    }
  }

  /// Glance browser's MCP server ("glance-browser"): the Playwright MCP on the Chromium Studio shows in a floating panel.
  private static func registerBrowserMCP(install: Bool, glancePath: String) {
    let arguments = install ? BrowserMCPSetup.addArguments(glancePath: glancePath) : BrowserMCPSetup.removeArguments
    if install { _ = runClaude(BrowserMCPSetup.removeArguments) }
    let (status, output) = runClaude(arguments)
    if status == 0 {
      print(install ? "✓ Claude Code can use the Glance browser, shown in Glance Studio (MCP server \"glance-browser\")."
                    : "✓ Removed the \"glance-browser\" MCP server.")
    } else {
      print("note: couldn't \(install ? "add" : "remove") the \"glance-browser\" MCP server: \(output)")
    }
  }

  private static func runClaude(_ arguments: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["claude"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (127, error.localizedDescription) }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func pretty(_ value: Any?) -> String {
    guard let value, JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return "  (none)" }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n")
  }
}
