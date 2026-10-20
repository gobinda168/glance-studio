import Foundation

public enum KokoroSeedError: Error, Equatable, LocalizedError {
  case missingBundle(String)

  public var errorDescription: String? {
    switch self {
    case .missingBundle(let path): "the model files aren't in the app (\(path)). Rebuild it with scripts/build.sh."
    }
  }
}

/// Kokoro's files ship inside the app, but FluidAudio reads them from its cache folder and downloads whatever is
/// missing there. Seeding copies each bundled file the cache lacks, so FluidAudio finds everything and never downloads.
public enum KokoroSeed {
  /// Paths relative to `bundle` of the regular files `cache` lacks, or holds at a different size (a copy cut short),
  /// sorted.
  public static func missing(bundle: URL, cache: URL) -> [String] {
    let root = bundle.resolvingSymlinksInPath().path + "/"
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
    guard let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: Array(keys)) else { return [] }
    var missing: [String] = []
    for case let url as URL in walker {
      guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
      let path = url.resolvingSymlinksInPath().path
      guard path.hasPrefix(root) else { continue }
      let relative = String(path.dropFirst(root.count))
      let cached = try? cache.appendingPathComponent(relative).resourceValues(forKeys: [.fileSizeKey]).fileSize
      if cached != values.fileSize { missing.append(relative) }
    }
    return missing.sorted()
  }

  /// Copies the missing files and returns how many. Each file is copied to `<name>.partial` and then renamed, so an
  /// interrupted copy never leaves a short file under the real name. Throws when `bundle` doesn't exist, so a build
  /// without the model says so instead of downloading it.
  @discardableResult
  public static func seed(bundle: URL, cache: URL) throws -> Int {
    let files = FileManager.default
    guard files.fileExists(atPath: bundle.path) else { throw KokoroSeedError.missingBundle(bundle.path) }
    let list = missing(bundle: bundle, cache: cache)
    for relative in list {
      let target = cache.appendingPathComponent(relative)
      let staging = target.appendingPathExtension("partial")
      try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? files.removeItem(at: staging)
      try files.copyItem(at: bundle.appendingPathComponent(relative), to: staging)
      _ = try files.replaceItemAt(target, withItemAt: staging)
    }
    return list.count
  }
}
