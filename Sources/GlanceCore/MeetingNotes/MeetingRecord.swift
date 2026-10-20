import Foundation

/// One recorded meeting, as `meeting.json` holds it (spec 2026-10-09-meeting-notes-design.md).
public struct MeetingRecord: Codable, Equatable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable {
    /// Recording now.
    case recording
    /// Stopped; the rest of the audio is being transcribed and the speakers told apart.
    case transcribing
    /// Claude is writing the notes.
    case summarizing
    /// Done: transcript and (unless `problem` says why not) notes.
    case ready
    /// Studio quit while recording; the audio is kept for Transcribe.
    case interrupted
  }

  public var id: String
  public var title: String
  public var start: Date
  public var end: Date?
  /// The calendar occurrence it was recorded for (`MeetingEvent.id`), if any.
  public var eventID: String?
  public var status: Status
  public var lines: [TranscriptLine]
  /// Names given to the speakers: "S1" → "Priya". "you" is the user.
  public var speakerNames: [String: String]
  public var summary: MeetingSummary?
  public var asks: [MeetingAsk]
  /// Why the notes or the transcript are missing, shown with a way to retry.
  public var problem: String?
  /// The audio files are still on disk.
  public var hasAudio: Bool

  public init(id: String, title: String, start: Date, end: Date? = nil, eventID: String? = nil,
              status: Status = .recording, lines: [TranscriptLine] = [], speakerNames: [String: String] = [:],
              summary: MeetingSummary? = nil, asks: [MeetingAsk] = [], problem: String? = nil, hasAudio: Bool = true) {
    self.id = id
    self.title = title
    self.start = start
    self.end = end
    self.eventID = eventID
    self.status = status
    self.lines = lines
    self.speakerNames = speakerNames
    self.summary = summary
    self.asks = asks
    self.problem = problem
    self.hasAudio = hasAudio
  }

  /// A new meeting's id: its start, sortable, plus a short random tail so two never collide.
  public static func newID(start: Date, random: String = String(UUID().uuidString.prefix(4))) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "\(formatter.string(from: start))-\(random.lowercased())"
  }

  /// Seconds from start to end (or to `now` while recording).
  public func duration(now: Date = Date()) -> TimeInterval {
    max(0, (end ?? now).timeIntervalSince(start))
  }

  /// The name shown for a speaker label.
  public func name(of speaker: String, you: String = "You") -> String {
    if let name = speakerNames[speaker], !name.isEmpty { return name }
    if speaker == TranscriptLine.you { return you }
    if speaker == TranscriptLine.others { return "Others" }
    if speaker.hasPrefix("S"), let number = Int(speaker.dropFirst()) { return "Speaker \(number)" }
    return speaker
  }

  /// The speaker labels in the order they first speak.
  public var speakers: [String] {
    var seen: [String] = []
    for line in lines.sorted(by: { $0.start < $1.start }) where !seen.contains(line.speaker) {
      seen.append(line.speaker)
    }
    return seen
  }
}

/// A stretch of speech and what was said, on one channel.
public struct TranscriptLine: Codable, Equatable, Sendable {
  public enum Channel: String, Codable, Sendable {
    /// The microphone: the user.
    case mic
    /// The Mac's sound output: everyone else on the call.
    case system
  }

  /// The user's speaker label.
  public static let you = "you"
  /// The call channel before (or without) telling the speakers apart.
  public static let others = "others"

  public var channel: Channel
  public var speaker: String
  /// Seconds since the recording started.
  public var start: Double
  public var end: Double
  public var text: String

  public init(channel: Channel, speaker: String? = nil, start: Double, end: Double, text: String) {
    self.channel = channel
    self.speaker = speaker ?? (channel == .mic ? Self.you : Self.others)
    self.start = start
    self.end = end
    self.text = text
  }
}

/// The notes Claude writes from the transcript.
public struct MeetingSummary: Codable, Equatable, Sendable {
  public struct ActionItem: Codable, Equatable, Sendable {
    public var task: String
    /// Who does it, as said in the meeting; nil when nobody was named.
    public var owner: String?
    /// The user owns it.
    public var mine: Bool

    public init(task: String, owner: String? = nil, mine: Bool = false) {
      self.task = task
      self.owner = owner
      self.mine = mine
    }
  }

  /// A short title for the meeting when it had none (no calendar event).
  public var title: String?
  public var overview: String
  public var decisions: [String]
  public var actionItems: [ActionItem]
  public var openQuestions: [String]

  public init(title: String? = nil, overview: String, decisions: [String] = [], actionItems: [ActionItem] = [],
              openQuestions: [String] = []) {
    self.title = title
    self.overview = overview
    self.decisions = decisions
    self.actionItems = actionItems
    self.openQuestions = openQuestions
  }
}

/// A question asked about the meeting (live or later) and Claude's answer.
public struct MeetingAsk: Codable, Equatable, Sendable {
  public var question: String
  public var answer: String
  public var date: Date

  public init(question: String, answer: String, date: Date) {
    self.question = question
    self.answer = answer
    self.date = date
  }
}
