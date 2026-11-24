import Foundation

/// Which sessions' records the board must read again. A hook or the `glance` CLI writes a record without telling the
/// app, so the board looks at each record's modification time (a `stat`) and decodes only the ones that moved.
public enum RecordFreshness {
  /// The stamp of a session with no record or summary file.
  public static let none = Date.distantPast

  /// The sessions, each once and in order, whose current stamp differs from the one last read (or that were never read).
  /// `current` is called once per session, so a tick for one session costs one `stat`.
  public static func changed(sessions: [String], seen: [String: Date], current: (String) -> Date) -> [String] {
    var checked = Set<String>()
    var result: [String] = []
    for session in sessions where checked.insert(session).inserted {
      if seen[session] != current(session) { result.append(session) }
    }
    return result
  }
}
