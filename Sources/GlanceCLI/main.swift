import Foundation
import GlanceCore
import GlanceKit

switch CommandLine.arguments.dropFirst().first {
case "version", "--version":
  print("Glance \(AppVersion.current.full)")
  exit(0)
case "setup":
  exit(SetupCommand.run(install: true))
case "unsetup":
  exit(SetupCommand.run(install: false))
case "voice-check":
  exit(VoiceCheckCommand.run(Array(CommandLine.arguments.dropFirst(2))))
case "transcribe":
  guard CommandLine.arguments.count > 2 else { print("usage: glance transcribe <audio file>"); exit(2) }
  let path = CommandLine.arguments[2]
  exit(MainActor.assumeIsolated { DebugCommands.transcribe(path: path) })
case "type":
  let text = CommandLine.arguments.dropFirst(2).joined(separator: " ")
  exit(MainActor.assumeIsolated { DebugCommands.type(text) })
case "meeting-check":
  exit(MeetingCheckCommand.run(Array(CommandLine.arguments.dropFirst(2))))
case "kokoro-fetch":
  exit(MainActor.assumeIsolated { DebugCommands.kokoroFetch() })
case "suggestions-replay":
  // How often the terminal's ghost text and next-command prediction would have been right on this Mac's history.
  let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Glance/history.sqlite")
  do {
    var records = FileManager.default.fileExists(atPath: url.path) ? try CommandHistoryStore(url: url).all() : []
    if records.isEmpty {
      // Nothing recorded in Studio yet: zsh's own history, as the import would bring it in.
      let file = ProcessInfo.processInfo.environment["HISTFILE"] ?? NSHomeDirectory() + "/.zsh_history"
      let data = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
      records = ZshHistory.records(ZshHistory.parse(data), before: Date())
      print("Glance's history is empty; replaying \(file).")
    }
    print(SuggestionReplay.describe(SuggestionReplay.run(records)))
    exit(0)
  } catch {
    print("glance: couldn't read \(url.path): \(error)")
    exit(1)
  }
case "watch":
  let folder = CommandLine.arguments.dropFirst(2).first
  exit(MainActor.assumeIsolated { DebugCommands.watch(cwd: folder) })
case "automation":
  exit(AutomationCommands.run(Array(CommandLine.arguments.dropFirst(2))))
case "browser":
  exit(BrowserCommands.run(Array(CommandLine.arguments.dropFirst(2))))
case "agent-browser":
  exit(AgentBrowserCommands.run(Array(CommandLine.arguments.dropFirst(2))))
case "helper":
  // Glance Studio's background jobs, in a process of their own.
  exit(HelperCommand.run())
case "mcp":
  // Claude Code's stdio MCP server for the orb channel (registered by `glance setup`).
  McpCommand.run()
default:
  print("usage: glance [version | setup | unsetup | mcp | voice-check <provider|kokoro> [text] | transcribe <audio file> | type <text> | watch [folder] | meeting-check <call audio> [mic audio] | kokoro-fetch | suggestions-replay | automation <check|list|approve|trust|enable|save|history|restore|delete|run|serve> … | browser <tabs|console|network|watch|request> … | agent-browser <mcp|install|status|serve>]")
  exit(2)
}
