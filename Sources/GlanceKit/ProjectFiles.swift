import Foundation

/// Keyterm candidates from the project Claude Code is working in.
enum ProjectFiles {
  /// Tracked files of the git repo at `cwd`, most recently modified first. Empty outside a repo.
  static func recent(cwd: String, limit: Int = 60) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd, "ls-files", "-z"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return [] }
    let base = URL(fileURLWithPath: cwd)
    let dated = String(decoding: data, as: UTF8.self).split(separator: "\0").prefix(5000).map { path -> (String, Date) in
      let attributes = try? FileManager.default.attributesOfItem(atPath: base.appendingPathComponent(String(path)).path)
      return (String(path), attributes?[.modificationDate] as? Date ?? .distantPast)
    }
    return dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
  }
}
