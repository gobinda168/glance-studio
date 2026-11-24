import Darwin
import Foundation

/// Writes a script that may be running while it's replaced (the tracking hooks' wrapper, rewritten at every Studio
/// launch): the new file is written beside it, made executable, then renamed over it in one step, so a reader finds
/// the old script or the new one, executable either way.
public enum ExecutableScript {
  public static func write(_ text: String, to url: URL) throws {
    let folder = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      try Data(text.utf8).write(to: temporary)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
      guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}
