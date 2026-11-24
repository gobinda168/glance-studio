import Foundation

/// An uncommitted file and who made its current content.
public struct AttributedFile: Equatable, Sendable {
  public var path: String
  public var status: String
  public var author: Author

  public init(path: String, status: String, author: Author) {
    self.path = path
    self.status = status
    self.author = author
  }
}

public enum Uncommitted {
  /// Each file of `now` with its author: the recorded one while the content is still what that author left, else
  /// outside Claude. Sorted by path.
  public static func attribute(_ now: Fingerprint, authors: [String: TrackState.Authorship]) -> [AttributedFile] {
    now.entries.keys.sorted().compactMap { path in
      guard let entry = now.entries[path] else { return nil }
      let known = authors[path].flatMap { $0.hash == entry.hash ? $0.author : nil }
      return AttributedFile(path: path, status: entry.status, author: known ?? .outside)
    }
  }
}
