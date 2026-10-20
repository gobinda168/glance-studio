import Darwin
import Foundation

/// A file `body_file` reads or `save_to` writes, checked by path first (`SecretRequestPolicy.path`, for clear early
/// errors) and then opened again at the moment of use by walking file descriptors, so a hostile Claude racing the
/// file system (swapping a folder for a symlink while the request waits for approval) can't lead it outside.
///
/// The session folder is opened (O_NOFOLLOW) when the file is located and held until it is used, so renaming the
/// folder or putting a symlink in its place afterwards changes nothing. From there every intermediate folder is
/// opened with `openat(O_DIRECTORY | O_NOFOLLOW)`, the components being the ones the early check resolved. Reads take
/// only a regular file with a single link (a hard link to an outside file is refused) and never block on a FIFO.
/// Writes go to a fresh temp file beside the target (O_EXCL | O_NOFOLLOW, 0600), renamed over it: never through a
/// symlink, never over a folder.
final class SecretFolderFile: @unchecked Sendable {
  enum Failure: Error, Equatable {
    /// A component on the way is a symlink, gone, or not a folder: the same refusal as the early check's.
    case outside
    /// Not a plain, singly linked file (a folder, a symlink at the target, a FIFO, a hard link).
    case notAFile
    case tooLarge
    case failed
  }

  /// Where the early check found it (what `saved_to` reports).
  let url: URL
  private let root: Int32
  private let parents: [String]
  private let name: String

  private init(url: URL, root: Int32, parents: [String], name: String) {
    self.url = url
    self.root = root
    self.parents = parents
    self.name = name
  }

  deinit { close(root) }

  static func locate(_ path: String, inside folder: String?) -> Result<SecretFolderFile, SecretRequestPolicy.Refusal> {
    let target: URL
    switch SecretRequestPolicy.path(path, inside: folder) {
    case .failure(let refusal): return .failure(refusal)
    case .success(let checked): target = checked
    }
    guard let folder, let rootPath = realPath(folder) else { return .failure(.noFolder) }
    let rootParts = URL(fileURLWithPath: rootPath).pathComponents
    let parentParts = target.deletingLastPathComponent().pathComponents
    let parents = Array(parentParts.dropFirst(rootParts.count))
    let name = target.lastPathComponent
    guard parentParts.starts(with: rootParts), !parents.contains(where: { $0 == "." || $0 == ".." }),
          name != ".", name != "..", !name.isEmpty else { return .failure(.pathOutsideFolder(path)) }
    let fd = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return .failure(.pathOutsideFolder(path)) }
    return .success(SecretFolderFile(url: target, root: fd, parents: parents, name: name))
  }

  /// The file's folder, walked from the pinned session folder without following a symlink. The caller closes it.
  private func openParent() -> Int32? {
    var fd = dup(root)
    guard fd >= 0 else { return nil }
    for part in parents {
      let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      close(fd)
      guard next >= 0 else { return nil }
      fd = next
    }
    return fd
  }

  func read(limit: Int) -> Result<Data, Failure> {
    guard let folder = openParent() else { return .failure(.outside) }
    defer { close(folder) }
    // O_NONBLOCK: opening a FIFO for reading would otherwise wait for a writer.
    let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return .failure(errno == ELOOP ? .outside : .failed) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { return .failure(.failed) }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return .failure(.notAFile) }
    guard info.st_size <= limit else { return .failure(.tooLarge) }
    _ = fcntl(fd, F_SETFL, 0)

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        return .failure(.failed)
      }
      if count == 0 { return .success(data) }
      // The file may have grown since fstat.
      guard data.count + count <= limit else { return .failure(.tooLarge) }
      data.append(contentsOf: buffer[0..<count])
    }
  }

  /// Nil when written.
  func write(_ data: Data) -> Failure? {
    guard let folder = openParent() else { return .outside }
    defer { close(folder) }
    var info = stat()
    if fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
      // Replace a plain file (its entry, so a hard link elsewhere keeps its content); never a folder or symlink.
      guard info.st_mode & S_IFMT == S_IFREG else { return .notAFile }
    } else if errno != ENOENT {
      return .failed
    }

    let temp = ".glance-\(UUID().uuidString).tmp"
    let fd = openat(folder, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return .failed }
    var written = Self.writeAll(fd, data)
    if close(fd) != 0 { written = false }
    // If a symlink appears at `name` after the check above, renameat replaces the link itself: nothing is written
    // through it. A folder that appears there makes it fail.
    guard written, renameat(folder, temp, folder, name) == 0 else {
      let failure: Failure = written && (errno == EISDIR || errno == ENOTEMPTY || errno == EEXIST) ? .notAFile : .failed
      unlinkat(folder, temp, 0)
      return failure
    }
    return nil
  }

  private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          return false
        }
        offset += count
      }
      return true
    }
  }

  /// realpath(3): nil when any component is missing, dangling or in a loop.
  private static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
