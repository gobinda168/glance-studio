import Foundation

/// Where a session's explainers live: `<session's record folder>/explainers/<reply id>/`, kept and removed with the rest
/// of its records. Ids come from a transcript or a page, so each is checked before it goes in a path.
public struct ExplainerStore: Sendable {
  public let work: WorkStore

  public init(work: WorkStore = WorkStore()) { self.work = work }

  public static func isSafeID(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 128 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
  }

  public func folder(session: String) -> URL? {
    guard WorkStore.isSessionID(session) else { return nil }
    return work.sessionFolder(session).appendingPathComponent("explainers", isDirectory: true)
  }

  public func folder(session: String, reply: String) -> URL? {
    guard Self.isSafeID(reply) else { return nil }
    return folder(session: session)?.appendingPathComponent(reply, isDirectory: true)
  }

  public func audio(session: String, reply: String, beat: String) -> URL? {
    guard ExplainerPage.isBeatID(beat) else { return nil }
    return folder(session: session, reply: reply)?.appendingPathComponent("\(beat).wav")
  }

  public func save(fragment: String, model: String, session: String, reply: String, now: Date = Date()) throws {
    guard let folder = folder(session: session, reply: reply) else { throw CocoaError(.fileWriteInvalidFileName) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(fragment.utf8).write(to: folder.appendingPathComponent("fragment.html"), options: .atomic)
    let meta: [String: String] = ["model": model, "time": ISO8601DateFormatter().string(from: now)]
    try JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
  }

  /// A saved page, checked again: a file changed on disk gets no more trust than Claude's output.
  public func page(session: String, reply: String) -> ExplainerPage? {
    guard let folder = folder(session: session, reply: reply),
          let text = try? String(contentsOf: folder.appendingPathComponent("fragment.html"), encoding: .utf8),
          case .success(let page) = ExplainerPage.check(text) else { return nil }
    return page
  }

  /// The replies with a saved page.
  public func replies(session: String) -> [String] {
    guard let folder = folder(session: session),
          let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
    return entries.filter { Self.isSafeID($0) && FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0)/fragment.html").path) }
  }

  /// The session's switch, or nil when it was never set.
  public func mode(session: String) -> Bool? {
    guard let folder = folder(session: session),
          let text = try? String(contentsOf: folder.appendingPathComponent(".mode"), encoding: .utf8) else { return nil }
    return text == "on"
  }

  public func setMode(_ on: Bool, session: String) {
    guard let folder = folder(session: session) else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? Data((on ? "on" : "off").utf8).write(to: folder.appendingPathComponent(".mode"), options: .atomic)
  }
}
