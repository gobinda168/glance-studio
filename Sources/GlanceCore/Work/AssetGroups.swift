import Foundation

/// One image, video or file in a session's Assets section.
public struct AssetItem: Sendable, Equatable, Identifiable {
  /// Where it came from, in the order the section lists them (the design's: Outcome, In the PR, Testing, On the branch,
  /// Test runs).
  public enum Group: String, CaseIterable, Sendable { case outcome, pr, testing, branch, testRun }
  public enum Kind: Sendable, Equatable { case image, video, file }

  public let id: String
  public let group: Group
  public let kind: Kind
  public let name: String
  /// What the item is called where it lives: a file name, a repository-relative path, or a PR reference.
  public let path: String
  /// The file to show. Nil when it is missing or not downloaded (then usually `failed`).
  public let file: URL?
  public let environment: String?
  public let at: Date?
  /// The file could not be found or fetched; the tile stays, saying so.
  public let failed: Bool
  /// Not brought in yet, and not for want of trying: the scan ran out of time or room first, and the next one tries again.
  /// Not a failure, so it never reads or counts as one.
  public let pending: Bool
  public let bytes: Int64?
  /// Lowercase hex SHA-256 of the file, when known.
  public let sha256: String?

  public init(id: String, group: Group, kind: Kind, name: String, path: String, file: URL? = nil, environment: String? = nil,
              at: Date? = nil, failed: Bool = false, bytes: Int64? = nil, sha256: String? = nil, pending: Bool = false) {
    self.id = id; self.group = group; self.kind = kind; self.name = name; self.path = path; self.file = file
    self.environment = environment; self.at = at; self.failed = failed; self.bytes = bytes; self.sha256 = sha256
    self.pending = pending
  }
}

/// What counts as an asset and which group it belongs to (spec §2.5 item 5). Pure rules: the scanning, the downloads
/// and the file reads that feed them live elsewhere.
public enum AssetGroups {
  public static let mediaExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "mp4", "mov", "webm", "m4v"]
  private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v"]

  /// The session's captures and what was found around the branch and the PR, as one list: grouped in the designed order,
  /// the order given kept inside a group.
  ///
  /// - A capture is Outcome when Claude marked it so, or when it is a finished explainer; otherwise Testing.
  /// - Two captures with the same hash are one asset, as Outcome when either is: a browser screenshot that Claude then
  ///   marked as the outcome is two captures of one image.
  /// - A found file with a capture's hash is that capture, shown once under the capture's group.
  /// - `media` finds a capture's file on disk. When it returns nil the item stays, `failed`, so a lost file is visible.
  /// - An id already listed is not listed again.
  public static func merge(captures: [ProofCapture], media: (ProofCapture) -> URL?, found: [AssetItem]) -> [AssetItem] {
    var items: [AssetItem] = []
    var slotByHash: [String: Int] = [:]
    for capture in captures {
      let item = item(for: capture, file: media(capture))
      if let hash = hash(capture.sha256) {
        if let slot = slotByHash[hash] {
          if items[slot].group != .outcome, item.group == .outcome { items[slot] = item }
          continue
        }
        slotByHash[hash] = items.count
      }
      items.append(item)
    }
    for item in found {
      if let hash = hash(item.sha256), slotByHash[hash] != nil { continue }
      items.append(item)
    }
    var ids = Set<String>()
    let unique = items.filter { ids.insert($0.id).inserted }
    let order = AssetItem.Group.allCases
    return unique.enumerated().sorted {
      let (a, b) = (order.firstIndex(of: $0.element.group) ?? 0, order.firstIndex(of: $1.element.group) ?? 0)
      return a != b ? a < b : $0.offset < $1.offset
    }.map(\.element)
  }

  /// What Proof's one-line count says: the session's captures by purpose, as Assets lists them (two captures of one image
  /// are one). A finished explainer is not counted: it is under Outcome in Assets and nowhere in Proof.
  public static func proofCounts(captures: [ProofCapture]) -> (outcome: Int, testing: Int) {
    let listed = merge(captures: captures.filter { $0.kind != .explainer }, media: { _ in nil }, found: [])
    return (listed.filter { $0.group == .outcome }.count, listed.filter { $0.group == .testing }.count)
  }

  /// The tag on a timeline row's screenshot: Outcome when it, or another capture of the same image, was marked as the
  /// outcome; else Testing. Nil when the row isn't a capture (a row is a capture when their ids are equal).
  public static func timelineTag(rowID: String, captures: [ProofCapture]) -> AssetItem.Group? {
    guard let capture = captures.first(where: { $0.id == rowID }) else { return nil }
    if group(of: capture) == .outcome { return .outcome }
    guard let hash = hash(capture.sha256) else { return .testing }
    return captures.contains { hash == Self.hash($0.sha256) && group(of: $0) == .outcome } ? .outcome : .testing
  }

  // MARK: Private

  private static func group(of capture: ProofCapture) -> AssetItem.Group {
    capture.purpose == .outcome || capture.kind == .explainer ? .outcome : .testing
  }

  private static func hash(_ text: String?) -> String? {
    guard let text = text?.lowercased(), !text.isEmpty else { return nil }
    return text
  }

  private static func item(for capture: ProofCapture, file: URL?) -> AssetItem {
    let kind: AssetItem.Kind
    switch capture.kind {
    case .clip, .explainer: kind = .video
    case .screenshot: kind = .image
    case .file:
      let ext = (capture.file as NSString).pathExtension.lowercased()
      kind = videoExtensions.contains(ext) ? .video : mediaExtensions.contains(ext) ? .image : .file
    }
    return AssetItem(id: capture.id, group: group(of: capture), kind: kind, name: capture.caption.isEmpty ? capture.file : capture.caption,
                     path: capture.file, file: file, environment: capture.environment, at: capture.at, failed: file == nil,
                     bytes: nil, sha256: capture.sha256)
  }
}
