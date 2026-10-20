import Foundation
import GlanceCore

/// `glance automation check <id|path> [--inputs <json>]` (spec 2026-10-09-automations-design.md, "Claude: skill +
/// Glance MCP"): validates a package, parses its shell scripts and command steps with the shell, and dry-runs the
/// pipeline. Prints "ok" (exit 0) or one problem per line (exit 1); bad usage or no package exits 2. The logic is
/// GlanceCore's `AutomationCheck`; this file reads the disk and runs the shell.
enum AutomationCommands {
  static let usage = "usage: glance automation check <id|path> [--inputs <json>]"

  /// ~/Library/Application Support/Glance/Automations
  static var library: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance/Automations", isDirectory: true)
  }

  static func run(_ arguments: [String]) -> Int32 {
    // Everything but `check` works on the library and the engine (stages A1 and A2).
    if let command = arguments.first, command != "check" { return AutomationEngineCommands.run(arguments) }
    guard arguments.first == "check" else {
      print(usage)
      return 2
    }
    var rest = Array(arguments.dropFirst())
    var given: [String: AutomationValue] = [:]
    if let flag = rest.firstIndex(of: "--inputs") {
      guard flag + 1 < rest.count, let object = AutomationValue.decode(Data(rest[flag + 1].utf8))?.object else {
        print(#"glance: --inputs needs a JSON object, like '{"repo": "acme/app"}'"#)
        return 2
      }
      given = object
      rest.removeSubrange(flag...(flag + 1))
    }
    guard rest.count == 1 else {
      print(usage)
      return 2
    }
    let folder = packageURL(rest[0])
    guard let package = read(folder) else { return 2 }
    let result = AutomationCheck.run(package, library: siblings(of: folder), inputs: given)
    var problems = result.problems
    for check in result.shellChecks {
      if let output = complaint(check) { problems.append(AutomationCheck.shellProblem(check, output: output)) }
    }
    print(AutomationCheck.report(problems))
    return problems.isEmpty ? 0 : 1
  }

  /// A path when it has a "/" (or is "." / ".."); otherwise an id in the library.
  static func packageURL(_ argument: String) -> URL {
    if argument.contains("/") || argument == "." || argument == ".." {
      return URL(fileURLWithPath: (argument as NSString).expandingTildeInPath).standardizedFileURL
        .resolvingSymlinksInPath()
    }
    return library.appendingPathComponent(argument, isDirectory: true).resolvingSymlinksInPath()
  }

  /// The package's manifest and every other file's text (hidden files skipped; a file over 1 MB or not UTF-8 reads
  /// as "").
  static func read(_ folder: URL) -> AutomationPackage? {
    guard let manifest = try? Data(contentsOf: folder.appendingPathComponent(AutomationManifest.fileName)) else {
      print("glance: no \(AutomationManifest.fileName) in \(folder.path)")
      return nil
    }
    var files: [String: String] = [:]
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])
    while let url = walker?.nextObject() as? URL {
      let values = try? url.resourceValues(forKeys: Set(keys))
      guard values?.isRegularFile == true else { continue }
      let full = url.resolvingSymlinksInPath().path
      guard full.hasPrefix(folder.path + "/") else { continue }
      let path = String(full.dropFirst(folder.path.count + 1))
      guard path != AutomationManifest.fileName else { continue }
      let small = (values?.fileSize ?? 0) <= 1_000_000
      files[path] = small ? (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } ?? "" : ""
    }
    return AutomationPackage(folderName: folder.lastPathComponent, directory: folder.path, manifest: manifest,
                             files: files)
  }

  /// Where the builder's Claude drafts packages, inside the library (hidden: never a package).
  static let draftsFolder = ".drafts"

  /// The other packages beside this one (the library, or the starters): folder → the automations it calls. A draft in
  /// the library's `.drafts/` also sees the library's automations (a draft may call them).
  static func siblings(of folder: URL) -> [String: Set<String>] {
    let parent = folder.deletingLastPathComponent()
    var found = callees(in: parent)
    if parent.lastPathComponent == draftsFolder {
      found.merge(callees(in: parent.deletingLastPathComponent())) { draft, _ in draft }
    }
    return found
  }

  /// The packages in `parent`: folder → the automations it calls.
  static func callees(in parent: URL) -> [String: Set<String>] {
    var found: [String: Set<String>] = [:]
    for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] where !name.hasPrefix(".") {
      let url = parent.appendingPathComponent(name).appendingPathComponent(AutomationManifest.fileName)
      guard let data = try? Data(contentsOf: url) else { continue }
      found[name] = AutomationManifest.parse(data).manifest?.callees ?? []
    }
    return found
  }

  /// What the shell said about the script (`-n`: parse only, run nothing), or nil when it parses.
  static func complaint(_ check: AutomationShellCheck) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: check.shell)
    process.arguments = (check.shell == "/bin/zsh" ? ["-f"] : []) + ["-n", "-c", check.script]
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return "glance: couldn't start \(check.shell): \(error.localizedDescription)"
    }
    let output = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? nil : String(decoding: output, as: UTF8.self)
  }
}
