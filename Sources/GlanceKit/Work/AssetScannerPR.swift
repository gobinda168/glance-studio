import Foundation
import GlanceCore

/// What the PR group of the Assets scan remembers between scans, in memory: which PR text was read (so a PR that has not
/// changed is not looked up again) and which images failed (so a broken link is not asked for every 20 seconds).
public final class PRMediaState: @unchecked Sendable {
  public static let shared = PRMediaState()
  /// A failed image is not asked for again for this long.
  public static let retryAfter: TimeInterval = 10 * 60

  struct Lookup {
    let updatedAt: String
    let urls: [URL]
  }

  private let lock = NSLock()
  private var lookups: [String: Lookup] = [:]
  private var failures: [String: Date] = [:]

  public init() {}

  func lookup(_ key: String) -> Lookup? { lock.lock(); defer { lock.unlock() }; return lookups[key] }

  func store(_ lookup: Lookup, for key: String) {
    lock.lock(); defer { lock.unlock() }
    if lookups.count >= 200 { lookups.removeAll() }
    lookups[key] = lookup
  }

  func failed(_ name: String, now: Date) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard let at = failures[name] else { return false }
    if now.timeIntervalSince(at) >= Self.retryAfter { failures[name] = nil; return false }
    return true
  }

  func recordFailure(_ name: String, at date: Date) {
    lock.lock(); defer { lock.unlock() }
    if failures.count >= 2_000 { failures.removeAll() }
    failures[name] = date
  }
}

extension AssetScanner {
  /// All the PR's images and videos together may take this much room in a session's cache.
  static let maxPRCacheBytes: Int64 = 300 << 20
  /// Partial downloads older than this are leftovers of a run that was cut short.
  private static let partialLife: TimeInterval = 10 * 60

  /// The images and videos in the PR's description and comments ("In the PR"), brought onto this Mac under the session's
  /// cache folder. Nothing when there is no `session`.
  ///
  /// The text is read with `bodies` only when the PR's `updatedAt` is not the one already read. At most
  /// `PRMedia.maxItems` links are taken, in order, each once, and only ones `AssetLinks` passes. Each is downloaded at
  /// most once: a file already in the cache is used, a failed one stays a placeholder (`failed`) and is not asked for
  /// again for ten minutes, and running out of `timeLimit` (or room) leaves placeholders that the next scan tries again.
  ///
  /// - Parameters:
  ///   - folder: where `gh` runs, for a PR whose repository `info` doesn't name.
  ///   - download: how a link is fetched (`PRMedia.download`: GitHub uploads through gh, the rest on the plain web).
  public static func scanPR(info: ProofPR.Info, session: String?, folder: String? = nil, store: WorkStore = WorkStore(),
                            state: PRMediaState = .shared, now: @escaping @Sendable () -> Date = { Date() },
                            timeLimit: TimeInterval = 120,
                            bodies: @escaping @Sendable (ProofPR.Info, String?) -> Result<(texts: [String], updatedAt: String), ProofPR.Failure>
                              = { ProofPR.bodies(info: $0, folder: $1) },
                            download: @escaping PRMedia.Downloader = { PRMedia.download(url: $0, to: $1, limit: $2) }) async -> [AssetItem] {
    guard let session, WorkStore.isSessionID(session) else { return [] }
    let cancelled = Cancelled()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let answer = Once { continuation.resume(returning: $0) }
        scanQueue.async {
          guard answer.start() else { return }
          answer.send(prItems(info: info, session: session, folder: folder, store: store, state: state, now: now,
                              deadline: Date().addingTimeInterval(timeLimit), cancelled: cancelled,
                              bodies: bodies, download: download))
        }
        // A scan that never gets a thread answers with nothing and never runs. One that has begun is left to finish, so
        // that two never download at once.
        timeouts.asyncAfter(deadline: .now() + timeLimit + startGrace) { answer.giveUpIfNotStarted() }
      }
    } onCancel: {
      cancelled.set()
    }
  }

  private final class Cancelled: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
  }

  private static func prItems(info: ProofPR.Info, session: String, folder: String?, store: WorkStore, state: PRMediaState,
                              now: @Sendable () -> Date, deadline: Date, cancelled: Cancelled,
                              bodies: @Sendable (ProofPR.Info, String?) -> Result<(texts: [String], updatedAt: String), ProofPR.Failure>,
                              download: @escaping PRMedia.Downloader) -> [AssetItem] {
    let key = "\(session)|\(info.repository)|\(info.number)"
    let known = state.lookup(key)
    let urls: [URL]
    if !info.updatedAt.isEmpty, let known, known.updatedAt == info.updatedAt {
      urls = known.urls
    } else {
      switch bodies(info, folder) {
      case .success(let read):
        urls = mediaLinks(in: read.texts)
        state.store(PRMediaState.Lookup(updatedAt: read.updatedAt, urls: urls), for: key)
      case .failure:
        guard let known else { return [] }
        urls = known.urls
      }
    }
    guard !urls.isEmpty else { return [] }

    let cache = store.cacheFolder(session: session).appendingPathComponent("pr", isDirectory: true)
    sweepPartials(in: cache, now: now())
    var used = folderBytes(cache)
    var items: [AssetItem] = []
    for (index, url) in urls.enumerated() {
      let name = PRMedia.cacheName(url)
      if let file = PRMedia.cachedFile(for: url, in: cache) {
        items.append(item(url: url, name: name, index: index, number: info.number, file: file))
      } else if state.failed(name, now: now()) {
        items.append(placeholder(url: url, name: name, index: index, number: info.number))
      } else if cancelled.isSet || Date() >= deadline || maxPRCacheBytes - used <= 0 {
        // Out of time or room, not a failure of this image: the next scan tries it, and it must not read as failed.
        items.append(placeholder(url: url, name: name, index: index, number: info.number, pending: true))
      } else {
        switch PRMedia.fetch(url: url, into: cache, limit: min(PRMedia.maxBytes, maxPRCacheBytes - used), download: download) {
        case .success(let fetched):
          used += fetched.bytes
          items.append(item(url: url, name: name, index: index, number: info.number, file: fetched.file))
        case .failure:
          state.recordFailure(name, at: now())
          items.append(placeholder(url: url, name: name, index: index, number: info.number))
        }
      }
    }
    return items
  }

  /// Media links in the texts in order, each once, the first `PRMedia.maxItems`.
  private static func mediaLinks(in texts: [String]) -> [URL] {
    var seen = Set<String>()
    var urls: [URL] = []
    for text in texts {
      for url in AssetLinks.find(in: text) where seen.insert(url.absoluteString).inserted {
        urls.append(url)
        if urls.count == PRMedia.maxItems { return urls }
      }
    }
    return urls
  }

  private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v"]

  private static func reference(_ url: URL, number: Int) -> String { "#\(number) \(url.host ?? "")\(url.path)" }

  private static func item(url: URL, name: String, index: Int, number: Int, file: URL) -> AssetItem {
    let kind: AssetItem.Kind = videoExtensions.contains(file.pathExtension) ? .video : .image
    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let bytes = values?.fileSize.map(Int64.init)
    let modified = values?.contentModificationDate
    return AssetItem(id: "pr:" + name, group: .pr, kind: kind, name: displayName(url, kind: kind, index: index, known: true),
                     path: reference(url, number: number), file: file, at: modified, failed: false, bytes: bytes,
                     sha256: HashCache.shared.hash(of: file, modified: modified, bytes: bytes))
  }

  /// A tile for media that could not be brought in; the kind is a guess from the address.
  private static func placeholder(url: URL, name: String, index: Int, number: Int, pending: Bool = false) -> AssetItem {
    let kind: AssetItem.Kind = videoExtensions.contains(url.pathExtension.lowercased()) ? .video : .image
    return AssetItem(id: "pr:" + name, group: .pr, kind: kind, name: displayName(url, kind: kind, index: index, known: false),
                     path: reference(url, number: number), file: nil, failed: !pending, pending: pending)
  }

  /// The file name when the address has a media one; else "Image 2" / "Video 1" (or "PR media 3" when the kind is a guess).
  private static func displayName(_ url: URL, kind: AssetItem.Kind, index: Int, known: Bool) -> String {
    if AssetGroups.mediaExtensions.contains(url.pathExtension.lowercased()), !url.lastPathComponent.isEmpty { return url.lastPathComponent }
    if !known { return "PR media \(index + 1)" }
    return (kind == .video ? "Video " : "Image ") + String(index + 1)
  }

  private static func folderBytes(_ folder: URL) -> Int64 {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.reduce(0) { total, name in
      total + Int64((try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
  }

  private static func sweepPartials(in folder: URL, now: Date) {
    for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".part") {
      let file = folder.appendingPathComponent(name)
      guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
            now.timeIntervalSince(modified) > partialLife else { continue }
      try? FileManager.default.removeItem(at: file)
    }
  }
}
