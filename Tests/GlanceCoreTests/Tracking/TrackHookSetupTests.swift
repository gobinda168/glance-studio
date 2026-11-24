import Foundation
import Testing
@testable import GlanceCore

private func entries(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
  ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
}

struct TrackHookSetupTests {
  @Test func installsOneTrackHookPerEventBesideOthers() {
    let notify: [String: Any] = ["hooks": [["type": "command", "command": "'/x/notify.sh' # glance"]]]
    let script = "/Users/a b/.claude/glance/track.sh"
    let out = TrackHookSetup.install(into: ["hooks": ["UserPromptSubmit": [notify]]], script: script)
    for event in TrackHookSetup.events { #expect(entries(out, event).count == (event == "UserPromptSubmit" ? 2 : 1)) }
    let hook = (entries(out, "PreToolUse")[0]["hooks"] as? [[String: Any]])?.first
    #expect(hook?["command"] as? String == "'/Users/a b/.claude/glance/track.sh' PreToolUse # glance-track")
    #expect(hook?["type"] as? String == "command")
    #expect(hook?["timeout"] as? Int == 10)
    #expect(TrackHookSetup.isInstalled(in: out))
    // Idempotent, and uninstall leaves Glance's notify hook alone.
    #expect(entries(TrackHookSetup.install(into: out, script: "/g.sh"), "PreToolUse").count == 1)
    let removed = TrackHookSetup.uninstall(from: out)
    #expect(entries(removed, "UserPromptSubmit").count == 1)
    #expect(entries(removed, "PreToolUse").isEmpty)
    #expect(!TrackHookSetup.isInstalled(in: removed))
    // HookSetup's own uninstall doesn't touch the tracking hooks (different marker).
    #expect(TrackHookSetup.isInstalled(in: HookSetup.uninstall(from: out)))
  }

  @Test func theOlderDirectCommandIsReplaced() {
    let old: [String: Any] = ["hooks": ["PreToolUse": [["hooks": [["type": "command",
                                                                    "command": "'/g' track PreToolUse # glance-track"]]]]]]
    let out = TrackHookSetup.install(into: old, script: "/s.sh")
    let commands = entries(out, "PreToolUse").compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
    #expect(commands == ["'/s.sh' PreToolUse # glance-track"])
  }

  @Test func theScriptRunsGlanceOnlyWhileItExists() {
    let text = TrackHookSetup.script(glance: "/Apps/Glance's.app/Contents/MacOS/glance")
    #expect(text == """
    #!/bin/sh
    # Glance's change tracking (glance track). Does nothing if Glance moved or was deleted.
    g='/Apps/Glance'\\''s.app/Contents/MacOS/glance'
    [ -x "$g" ] || exit 0
    exec "$g" track "$1"

    """)
  }

  @Test func scriptCarriesFlags() {
    #expect(TrackHookSetup.script(glance: "/g", options: [.changes, .work]).contains("exec \"$g\" track \"$1\" --work\n"))
    #expect(TrackHookSetup.script(glance: "/g", options: [.work]).contains("exec \"$g\" track \"$1\" --sessions-only --work\n"))
    #expect(TrackHookSetup.script(glance: "/g", options: [.changes]).contains("exec \"$g\" track \"$1\"\n"))
    #expect(TrackHookSetup.script(glance: "/g") == TrackHookSetup.script(glance: "/g", options: [.changes]))
    #expect(TrackHookSetup.events.contains("PostToolUseFailure"))
  }

  @Test func optionsReadBackFromTheScript() {
    for options: TrackHookSetup.Options in [[.changes], [.work], [.changes, .work], []] {
      #expect(TrackHookSetup.Options(script: TrackHookSetup.script(glance: "/Apps/a --work/glance", options: options)) == options)
    }
  }

  @Test func theHookForAFailedToolCallIsInstalledToo() {
    let out = TrackHookSetup.install(into: [:], script: "/s.sh")
    let hook = (entries(out, "PostToolUseFailure")[0]["hooks"] as? [[String: Any]])?.first
    #expect(hook?["command"] as? String == "'/s.sh' PostToolUseFailure # glance-track")
    #expect(TrackHookSetup.isInstalled(in: out))
    #expect(entries(TrackHookSetup.uninstall(from: out), "PostToolUseFailure").isEmpty)
  }

  @Test func theScriptExitsQuietlyWhenGlanceIsGoneAndPassesTheHookOn() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trackscript-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // A stand-in glance that echoes its arguments and its stdin.
    let fake = folder.appendingPathComponent("fake glance").path
    try "#!/bin/sh\necho \"$@\"\ncat\n".write(toFile: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
    func run(glance: String) throws -> (Int32, String, String) {
      let script = folder.appendingPathComponent("track.sh").path
      try TrackHookSetup.script(glance: glance).write(toFile: script, atomically: true, encoding: .utf8)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = [script, "PreToolUse"]
      let input = Pipe(), output = Pipe(), errors = Pipe()
      process.standardInput = input
      process.standardOutput = output
      process.standardError = errors
      try process.run()
      input.fileHandleForWriting.write(Data("{}".utf8))
      try input.fileHandleForWriting.close()
      process.waitUntilExit()
      return (process.terminationStatus,
              String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
              String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    let present = try run(glance: fake)
    #expect(present.0 == 0)
    #expect(present.1 == "track PreToolUse\n{}")
    let gone = try run(glance: folder.appendingPathComponent("deleted/glance").path)
    #expect(gone.0 == 0)
    #expect(gone.1.isEmpty && gone.2.isEmpty)
  }

  @Test func theScriptIsReplacedWholeAndAlreadyExecutable() throws {
    // A hook can fire while Studio rewrites the script: it must find the old file or the new one, executable either
    // way, so the new one is made executable before it's renamed into place.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("track-script-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("glance/track.sh")
    try ExecutableScript.write("#!/bin/sh\necho one\n", to: url)
    let first = try FileManager.default.attributesOfItem(atPath: url.path)
    try ExecutableScript.write("#!/bin/sh\necho two\n", to: url)
    let second = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(try String(contentsOf: url, encoding: .utf8) == "#!/bin/sh\necho two\n")
    #expect((second[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    // Renamed into place (a new file), not rewritten in place.
    #expect((first[.systemFileNumber] as? NSNumber) != (second[.systemFileNumber] as? NSNumber))
    #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["track.sh"])
  }

  @Test func theFeaturesPickTheFlagsAndOnlyBothOffRemovesTheHooks() {
    #expect(TrackHookSetup.Options(worktrees: true, commandCenter: false) == [.changes])
    #expect(TrackHookSetup.Options(worktrees: false, commandCenter: true) == [.work])
    #expect(TrackHookSetup.Options(worktrees: true, commandCenter: true) == [.changes, .work])
    #expect(TrackHookSetup.Options(worktrees: false, commandCenter: false).isEmpty)
    // What Studio writes for Command Center alone: no change tracking, proof on.
    let text = TrackHookSetup.script(glance: "/g", options: TrackHookSetup.Options(worktrees: false, commandCenter: true))
    #expect(text.contains("exec \"$g\" track \"$1\" --sessions-only --work\n"))
  }

  @Test func anInstallWithoutTheFailureEventIsBroughtUpToDate() {
    // Hooks from a build before PostToolUseFailure existed: not "installed", and installing again adds the event
    // once, without doubling the others.
    var old = TrackHookSetup.install(into: [:], script: "/s.sh")
    var hooks = old["hooks"] as? [String: Any] ?? [:]
    hooks["PostToolUseFailure"] = nil
    old["hooks"] = hooks
    #expect(!TrackHookSetup.isInstalled(in: old))
    let fresh = TrackHookSetup.install(into: old, script: "/s.sh")
    #expect(TrackHookSetup.isInstalled(in: fresh))
    for event in TrackHookSetup.events { #expect(entries(fresh, event).count == 1) }
    #expect(NSDictionary(dictionary: TrackHookSetup.install(into: fresh, script: "/s.sh")).isEqual(to: fresh))
  }

  @Test func aReaderNeverSeesTheScriptWithoutItsExecuteBit() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("track-script-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("track.sh")
    try ExecutableScript.write("#!/bin/sh\n", to: url)
    let path = url.path
    let done = ManagedAtomicFlag()
    let sawUnexecutable = ManagedAtomicFlag()
    let reader = Thread {
      var info = stat()
      while !done.isSet {
        if lstat(path, &info) == 0, info.st_mode & 0o111 == 0 { sawUnexecutable.set() }
      }
    }
    reader.start()
    for index in 0..<400 { try ExecutableScript.write("#!/bin/sh\necho \(index)\n", to: url) }
    done.set()
    while !reader.isFinished { usleep(1000) }
    #expect(!sawUnexecutable.isSet)
  }
}

/// A flag two threads can share in a test.
private final class ManagedAtomicFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.withLock { value } }
  func set() { lock.withLock { value = true } }
}
