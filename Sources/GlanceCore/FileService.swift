import Foundation

/// Reads, saves and lists the files of one project folder. Nothing outside the root is ever touched, not through `..`,
/// absolute paths or symlinks. All calls are synchronous: callers run them off the main thread.
public struct FileService: Sendable {
  public static let maxBytes = 2 * 1024 * 1024
  private static let ignoredFolders: Set<String> = [".git", "node_modules", ".build", "build", "dist", ".next", "target", "DerivedData", "Pods"]
  private static let ignoredFiles: Set<String> = [".DS_Store"]

  public enum Failure: Error, Equatable {
    case outsideRoot, notFound, notAFile, notADirectory, binary, tooLarge, notUTF8, changedOnDisk, exists
    case io(String)

    public var code: String {
      switch self {
      case .outsideRoot: "outside-root"
      case .notFound: "not-found"
      case .notAFile: "not-a-file"
      case .notADirectory: "not-a-directory"
      case .binary: "binary"
      case .tooLarge: "too-large"
      case .notUTF8: "not-utf8"
      case .changedOnDisk: "changed-on-disk"
      case .exists: "exists"
      case .io: "io"
      }
    }

    public var message: String {
      switch self {
      case .outsideRoot: "That file is outside the project folder."
      case .notFound: "That file doesn't exist."
      case .notAFile: "That isn't a file."
      case .notADirectory: "That isn't a folder."
      case .binary: "This looks like a binary file, so it isn't opened."
      case .tooLarge: "This file is larger than 2 MB, so it isn't opened."
      case .notUTF8: "This file isn't UTF-8 text, so it isn't opened."
      case .changedOnDisk: "The file changed on disk."
      case .exists: "A file or folder with that name already exists."
      case .io(let reason): reason
      }
    }
  }

  public struct Document: Equatable, Sendable {
    public var path: String
    public var text: String
    public var modified: Double
    public var bom: Bool
  }

  /// The project folder, with symlinks resolved.
  public let root: String

  public init(root: String) {
    self.root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
  }

  private var rootPrefix: String { root.hasSuffix("/") ? root : root + "/" }

  /// The real location of `relative` inside the root. A file that doesn't exist yet is allowed (a save recreates it)
  /// when `mustExist` is false; its folder must still resolve inside the root.
  private func url(for relative: String, mustExist: Bool) throws -> URL {
    guard !relative.isEmpty, !relative.hasPrefix("/") else { throw Failure.outsideRoot }
    let candidate = URL(fileURLWithPath: rootPrefix + relative).standardizedFileURL
    // `..` is resolved lexically first, so an escape is "outside the root" even when the target doesn't exist.
    guard candidate.path == root || candidate.path.hasPrefix(rootPrefix) else { throw Failure.outsideRoot }
    let resolved: URL
    if FileManager.default.fileExists(atPath: candidate.path) {
      resolved = candidate.resolvingSymlinksInPath()
    } else {
      guard !mustExist else { throw Failure.notFound }
      resolved = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(candidate.lastPathComponent)
    }
    guard resolved.path == root || resolved.path.hasPrefix(rootPrefix) else { throw Failure.outsideRoot }
    return resolved
  }

  private func modified(of url: URL) -> Double? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
      .flatMap { $0 as? Date }?.timeIntervalSince1970
  }

  /// The file's modification time, or nil when it is gone (or outside the root).
  public func modified(_ relative: String) -> Double? {
    guard let url = try? url(for: relative, mustExist: true) else { return nil }
    return modified(of: url)
  }

  public func read(_ relative: String) throws -> Document {
    let url = try url(for: relative, mustExist: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw Failure.notAFile
    }
    let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    guard (attributes[.size] as? Int ?? 0) <= Self.maxBytes else { throw Failure.tooLarge }
    let data: Data
    do { data = try Data(contentsOf: url) } catch { throw Failure.io(error.localizedDescription) }
    guard !data.prefix(8192).contains(0) else { throw Failure.binary }
    let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
    guard let text = String(data: bom ? data.dropFirst(3) : data, encoding: .utf8) else { throw Failure.notUTF8 }
    return Document(path: relative, text: text, modified: modified, bom: bom)
  }

  /// The raw bytes of a file (any type, up to `limit`), for the preview's images, stylesheets and scripts.
  public func readData(_ relative: String, limit: Int = 50 * 1024 * 1024) throws -> Data {
    let url = try url(for: relative, mustExist: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw Failure.notAFile
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    guard size <= limit else { throw Failure.tooLarge }
    do { return try Data(contentsOf: url) } catch { throw Failure.io(error.localizedDescription) }
  }

  /// Writes `text` to the file, replacing it atomically and keeping its permissions. With `expectedModified`, the
  /// save fails unless the file still has that modification time (so a file someone else changed, or deleted, is
  /// never overwritten by accident). With nil it overwrites, or recreates a deleted file. Returns the new time.
  @discardableResult
  public func save(_ relative: String, text: String, expectedModified: Double?, bom: Bool) throws -> Double {
    let url = try url(for: relative, mustExist: false)
    if let expectedModified {
      guard let current = modified(of: url), current == expectedModified else { throw Failure.changedOnDisk }
    }
    let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
    var data = Data()
    if bom { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
    data.append(Data(text.utf8))
    do {
      try data.write(to: url, options: .atomic)
      if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    } catch {
      throw Failure.io(error.localizedDescription)
    }
    guard let modified = modified(of: url) else { throw Failure.io("The file disappeared after saving.") }
    return modified
  }

  /// Makes an empty file, or a folder, at `relative`, with any missing folders above it (`a/b/c.ts`). Fails when
  /// anything is already there, a dangling symlink too, and never reaches outside the root through a symlinked folder.
  public func create(_ relative: String, directory: Bool) throws {
    let url = try url(for: relative, mustExist: false)
    // attributesOfItem doesn't follow symlinks, so a link (even a broken one) counts as taken.
    guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else { throw Failure.exists }
    var nearest = url.deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: nearest.path) { nearest = nearest.deletingLastPathComponent() }
    let real = nearest.resolvingSymlinksInPath().path
    guard real == root || real.hasPrefix(rootPrefix) else { throw Failure.outsideRoot }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw Failure.notADirectory
    }
    do {
      if directory {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      } else {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url, options: .withoutOverwriting)
      }
    } catch {
      throw Failure.io(error.localizedDescription)
    }
  }

  /// Relative paths of the project's files, sorted. A git repo lists tracked and untracked files minus ignored ones;
  /// anything else is walked, skipping build and dependency folders. Capped at `limit`.
  public func listFiles(limit: Int = 20_000) -> [String] {
    if FileManager.default.fileExists(atPath: rootPrefix + ".git"), let listed = gitFiles(limit: limit) { return listed }
    return walk(limit: limit)
  }

  public struct DirectoryEntry: Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool
  }

  /// The entries of one folder for the file tree. Folders first, then files, each sorted case-insensitively. Build and
  /// dependency folders, `.git` and `.DS_Store` are hidden, and symlinks are never listed.
  public func listDirectory(_ relative: String) throws -> [DirectoryEntry] {
    let folder: URL
    if relative.isEmpty || relative == "." {
      folder = URL(fileURLWithPath: root)
    } else {
      folder = try url(for: relative, mustExist: true)
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw Failure.notADirectory
    }
    let names: [String]
    do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path) } catch { throw Failure.io(error.localizedDescription) }
    var entries: [DirectoryEntry] = []
    for name in names {
      let type = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.type] as? FileAttributeType
      switch type {
      case .typeDirectory:
        if !Self.ignoredFolders.contains(name) { entries.append(DirectoryEntry(name: name, isDirectory: true)) }
      case .typeRegular:
        if !Self.ignoredFiles.contains(name) { entries.append(DirectoryEntry(name: name, isDirectory: false)) }
      default:
        continue
      }
    }
    return entries.sorted {
      if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
      return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private func gitFiles(limit: Int) -> [String]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    var seen = Set<String>()
    var files: [String] = []
    for path in String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init) where seen.insert(path).inserted {
      // A tracked file that was deleted from disk is still in the index.
      if FileManager.default.fileExists(atPath: rootPrefix + path) { files.append(path) }
    }
    return Array(files.sorted().prefix(limit))
  }

  private func walk(limit: Int) -> [String] {
    // `enumerator(atPath:)` hands back paths relative to the root, so /private/var vs /var spellings can't confuse it.
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
    var files: [String] = []
    while let relative = enumerator.nextObject() as? String {
      let name = (relative as NSString).lastPathComponent
      switch enumerator.fileAttributes?[.type] as? FileAttributeType {
      case .typeDirectory:
        if Self.ignoredFolders.contains(name) { enumerator.skipDescendants() }
      case .typeRegular:
        if Self.ignoredFiles.contains(name) { continue }
        files.append(relative)
        if files.count >= limit { return files.sorted() }
      default:
        continue // symlinks (they could loop or leave the root), sockets, devices
      }
    }
    return files.sorted()
  }
}
