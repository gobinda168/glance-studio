import Foundation
import GlanceCore

/// Claude Code writing a meeting's notes and answering questions about it (spec 2026-10-09-meeting-notes-design.md,
/// "MeetingNotesPrompt"). Only the transcript text leaves the Mac.
@MainActor
public enum MeetingNotesWriter {
  /// The user as the transcript names them: the first word of the Mac account's name.
  public static var you: String { HomeState.greetingName(fullName: NSFullUserName()) ?? "You" }

  /// Writes the notes. A generic title ("Meeting") takes Claude's.
  @discardableResult
  public static func notes(for record: MeetingRecord,
                           completion: @escaping @MainActor (Result<MeetingSummary, Error>) -> Void)
    -> ClaudeOneShot.Run {
    ClaudeOneShot.run(arguments: MeetingNotesPrompt.arguments(), prompt: MeetingNotesPrompt.notes(record, you: you),
                      folder: nil, timeout: MeetingNotesPrompt.timeout) { reply in
      switch reply {
      case .success(let text):
        if let summary = MeetingNotesPrompt.parse(text) {
          completion(.success(summary))
        } else {
          completion(.failure(Failure(message: "Claude's notes weren't in the expected shape. Try Regenerate.")))
        }
      case .failure(let failure):
        completion(.failure(Failure(message: failure.message)))
      }
    }
  }

  /// Answers a question about the meeting; `live` while it's being recorded.
  @discardableResult
  public static func ask(_ question: String, about record: MeetingRecord, live: Bool,
                         completion: @escaping @MainActor (Result<String, Error>) -> Void) -> ClaudeOneShot.Run {
    ClaudeOneShot.run(arguments: MeetingNotesPrompt.arguments(),
                      prompt: MeetingNotesPrompt.ask(question, record: record, you: you, live: live), folder: nil,
                      timeout: MeetingNotesPrompt.askTimeout) { reply in
      switch reply {
      case .success(let text): completion(.success(text))
      case .failure(let failure): completion(.failure(Failure(message: failure.message)))
      }
    }
  }

  public struct Failure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
  }

  /// The default title of a meeting recorded without a calendar event.
  public nonisolated static let untitled = "Meeting"
}
