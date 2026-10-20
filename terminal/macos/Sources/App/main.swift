import AppKit
import Cocoa
import GhosttyKit
import GlanceCore // GLANCE:
import GlanceKit // GLANCE:

// GLANCE: Studio started from inside a Claude Code session (by Claude, or a script it ran) inherits that session's
// markers, and every `claude` in its terminals would think it's a child session and save no transcript. Drop them
// before ghostty_init copies the environment for the shells.
for key in ClaudeMods.sessionMarkers(in: ProcessInfo.processInfo.environment) { unsetenv(key) }
// GLANCE: started from a Warp shell, it inherits Warp's variables too, and Claude's Warp plugin sends Warp's own
// notifications (raw JSON on Glance's cards). Drop them the same way.
for key in ClaudeMods.otherTerminalMarkers(in: ProcessInfo.processInfo.environment) { unsetenv(key) }

// GLANCE: every `claude` in Studio loads Glance's mods (glance-replies). Set before ghostty_init: libghostty takes its
// copy of the environment there, and the shells it starts get that copy, not a later setenv. The mods run from a copy
// in Caches, not Application Support: it is made again at every launch, and an Application Support folder made this
// early would stop the old Glance Terminal folder moving over (EditorServerManager).
if let resources = Bundle.main.resourceURL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    ClaudeMods.export(from: resources.appendingPathComponent("mods"),
                      into: caches.appendingPathComponent("Glance Studio/mods"),
                      userMods: ModFolders.userMods, state: ModState.load())
}

// GLANCE: Automations: every `claude` in Studio also loads the Glance plugin (the glance-automations skill and the
// Glance MCP, which runs this app's glance CLI), the same way as the mods and for the same reason: before
// ghostty_init copies the environment for the shells. Switched on later in the Develop menu, it reaches new terminal
// tabs after a restart (Razor Chat and the builder get it at once: GlanceTerminalHost.startAutomations).
if MainActor.assumeIsolated({ StudioFeatures.shared.isOn(.automations) }) {
    ClaudePluginDir.export(cli: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/glance").path)
}

// GLANCE: per-launch Claude folders: the session links each terminal's SessionStart hook writes, and the Glance
// Humanize plugin a Humanize terminal loads (spec 2026-10-11-humanize-summaries-design.md). StudioFeatures (read just
// above) has set Prefs.summariesOn, which the Response style depends on.
StudioClaudeFolders.prepare()

// Initialize Ghostty global state. We do this once right away because the
// CLI APIs require it and it lets us ensure it is done immediately for the
// rest of the app.
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    Ghostty.logger.critical("ghostty_init failed")

    // We also write to stderr if this is executed from the CLI or zig run
    switch Ghostty.launchSource {
    case .cli, .zig_run:
        let stderrHandle = FileHandle.standardError
        stderrHandle.write(
            "Glance Studio failed to initialize! If you're executing it from the command line\n" +
            "then this is usually because an invalid action or multiple actions were specified.\n" +
            "Actions start with the `+` character.\n\n" +
            "View all available actions by running `ghostty +help`.\n")
        exit(1)

    case .app:
        // For the app we exit immediately. We should handle this case more
        // gracefully in the future.
        exit(1)
    }
}

// This will run the CLI action and exit if one was specified. A CLI
// action is a command starting with a `+`, such as `ghostty +boo`.
ghostty_cli_try_action()

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
