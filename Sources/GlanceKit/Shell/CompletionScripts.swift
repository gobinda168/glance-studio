import Foundation
import GlanceCore

/// The zsh completions Studio makes for installed tools that can print their own (`CompletionTools`): run once per
/// tool version, in the background, into Glance's caches. The zsh plugin puts the folder on `fpath` (spec "S1: the
/// Tab menu", "Coverage"); a shell started after a script appears picks it up.
public final class CompletionScripts: @unchecked Sendable {
  public static let shared = CompletionScripts()

  /// `~/Library/Caches/Glance/zsh`: the completion dump and these scripts.
  public let cache: URL
  /// `~/Library/Caches/Glance/zsh/completions`.
  public let folder: URL
  private let stampsFile: URL
  private let queue = DispatchQueue(label: "dev.glance.completion-scripts", qos: .utility)
  /// The `$PATH` values already looked at this launch (on `queue`).
  private var refreshed: Set<String> = []

  private init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    cache = caches.appendingPathComponent("Glance/zsh", isDirectory: true)
    folder = cache.appendingPathComponent("completions", isDirectory: true)
    stampsFile = cache.appendingPathComponent("completion-stamps.json")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// Makes the scripts that are missing or stale for the tools on this `$PATH`, once per `$PATH` per launch.
  public func refresh(path: String) {
    queue.async { [self] in
      guard !path.isEmpty, refreshed.insert(path).inserted else { return }
      var stamps = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: stampsFile))) ?? [:]
      let files = FileManager.default
      for tool in CompletionTools.tools {
        guard let found = CompletionTools.locate(tool.program, path: path, isExecutable: files.isExecutableFile),
              let attributes = try? files.attributesOfItem(atPath: (found as NSString).resolvingSymlinksInPath),
              let size = attributes[.size] as? Int64, let modified = attributes[.modificationDate] as? Date
        else { continue }
        let stamp = CompletionTools.stamp(path: found, size: size, modified: modified)
        guard stamps[tool.command] != stamp else { continue }
        // Tried once per version, whether or not it worked: a tool that errors isn't run again until it changes.
        stamps[tool.command] = stamp
        guard let script = Self.run(found, tool.arguments, path: path), CompletionTools.isCompletionScript(script)
        else { continue }
        let name = CompletionTools.fileName(for: tool.command, script: script)
        for old in ["_\(tool.command)", "\(tool.command).zsh"] where old != name {
          try? files.removeItem(at: folder.appendingPathComponent(old))
        }
        try? script.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
      }
      try? JSONEncoder().encode(stamps).write(to: stampsFile, options: .atomic)
    }
  }

  /// The program's standard output, or nil when it fails or runs past 5 s.
  private static func run(_ executable: String, _ arguments: [String], path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": path, "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "TERM": "dumb"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timer)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer.cancel()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
