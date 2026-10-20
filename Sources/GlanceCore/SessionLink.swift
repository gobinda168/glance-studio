import Foundation

/// The Claude Code session a Studio terminal runs (spec 2026-10-11-humanize-summaries-design.md, "Session isolation"):
/// read from the file `mods/glance-session`'s SessionStart hook writes, `<surface uuid>.json` holding the hook's input.
/// Anything local can write there, so the name must be a UUID and the transcript must be a Claude Code one.
public struct SessionLink: Equatable, Sendable {
  public let surface: UUID
  public let sessionID: String
  public let transcriptPath: String
  public let cwd: String?
  /// startup, resume, clear or compact.
  public let source: String?

  public init(surface: UUID, sessionID: String, transcriptPath: String, cwd: String?, source: String?) {
    self.surface = surface
    self.sessionID = sessionID
    self.transcriptPath = transcriptPath
    self.cwd = cwd
    self.source = source
  }

  private struct Input: Decodable {
    let hook_event_name: String
    let session_id: String?
    let transcript_path: String?
    let cwd: String?
    let source: String?
  }

  public static func parse(fileName: String, data: Data, home: String) -> SessionLink? {
    guard fileName.hasSuffix(".json"), let surface = UUID(uuidString: String(fileName.dropLast(5))),
      let input = try? JSONDecoder().decode(Input.self, from: data), input.hook_event_name == "SessionStart",
      let id = input.session_id, !id.isEmpty, let path = input.transcript_path,
      HookEvent(name: input.hook_event_name, sessionID: id, transcriptPath: path, cwd: input.cwd)
        .isTranscriptPathAllowed(home: home)
    else { return nil }
    return SessionLink(surface: surface, sessionID: id, transcriptPath: path, cwd: input.cwd, source: input.source)
  }
}
