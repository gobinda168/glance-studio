import Foundation
import GlanceCore

/// Saved summaries, one JSON file per session in Application Support/Glance/Summaries (spec
/// 2026-10-11-humanize-summaries-design.md, "Amendments"). Kept when terminals close or Studio quits.
public enum SummaryStore {
  static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Glance/Summaries")

  /// Session ids are Claude's UUIDs; anything else never becomes a path.
  static func url(_ sessionID: String) -> URL? {
    guard !sessionID.isEmpty, sessionID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else { return nil }
    return folder.appendingPathComponent("\(sessionID).json")
  }

  public static func load(_ sessionID: String) -> SummaryRecord? {
    guard let url = url(sessionID), let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SummaryRecord.self, from: data)
  }

  public static func save(_ record: SummaryRecord) {
    guard let url = url(record.sessionID) else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try? encoder.encode(record).write(to: url, options: .atomic)
  }

  /// A project's saved summaries, newest first (the pane's Terminal sessions list). Folders compare normalised
  /// ("~/x" and "/Users/me/x/" are one).
  public static func records(cwd: String) -> [SummaryRecord] {
    let home = NSHomeDirectory()
    let folder = SessionMatch.normalize(cwd, home: home)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: self.folder.path)) ?? []
    return names.compactMap { $0.hasSuffix(".json") ? load(String($0.dropLast(5))) : nil }
      .filter { $0.cwd.map { SessionMatch.normalize($0, home: home) } == folder }
      .sorted { $0.updatedAt > $1.updatedAt }
  }
}
