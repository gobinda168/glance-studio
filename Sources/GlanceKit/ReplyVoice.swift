import Combine
import Foundation
import GlanceCore

/// The voices of the session view, and what the rest of the app needs to know about them: one voice at a time, ⌥. plays
/// and pauses whichever is active, holding fn to dictate pauses it, a meeting nudge stops it.
@MainActor
public enum SessionVoices {
  /// Stops the voices outside the session view (the Glance pane, the orb). Set by the app.
  public static var silenceOthers: (() -> Void)?

  public static var isSpeaking: Bool {
    (ReplyVoice.shared.speaking != nil && !ReplyVoice.shared.isPaused) || ExplainerVoicePlayer.shared.isPlaying
  }

  public static func stopAll() {
    ReplyVoice.shared.stop()
    ExplainerVoicePlayer.shared.stop()
  }

  /// ⌥.: false when neither voice is active, so the key goes on to the pane's narration.
  public static func playPause() -> Bool {
    if ExplainerVoicePlayer.shared.current != nil {
      ExplainerVoicePlayer.shared.playPause()
      return true
    }
    if ReplyVoice.shared.speaking != nil {
      ReplyVoice.shared.playPause()
      return true
    }
    return false
  }

  /// Holding fn to dictate: a voice that is playing waits, and picks up after.
  public static func dictationHold(_ holding: Bool) {
    if holding {
      if ReplyVoice.shared.speaking != nil, !ReplyVoice.shared.isPaused {
        ReplyVoice.shared.playPause()
        heldReply = true
      }
      if ExplainerVoicePlayer.shared.isPlaying {
        ExplainerVoicePlayer.shared.playPause()
        heldPage = true
      }
    } else {
      if heldReply, ReplyVoice.shared.isPaused { ReplyVoice.shared.playPause() }
      if heldPage, !ExplainerVoicePlayer.shared.isPlaying { ExplainerVoicePlayer.shared.playPause() }
      heldReply = false
      heldPage = false
    }
  }

  private static var heldReply = false
  private static var heldPage = false
}

/// Reads one markdown reply aloud in the timeline: Listen, in the voice from Settings → Voice, and a short reply in
/// Explainer mode, on Kokoro only so the mode never spends cloud voice credit unasked. The pane isn't involved.
@MainActor
public final class ReplyVoice: ObservableObject {
  public static let shared = ReplyVoice()

  /// The reply being read, paused or not.
  @Published public private(set) var speaking: String?
  @Published public private(set) var isPaused = false

  private let narrator = Narrator()
  private let cache = AudioCache(limit: 8 << 20)

  private init() {
    narrator.onFinish = { [weak self] in
      self?.speaking = nil
      self?.isPaused = false
    }
  }

  /// Listen: starts this reply, or stops it when it is the one being read.
  public func toggle(id: String, markdown: String) {
    if speaking == id { stop() } else { read(id: id, markdown: markdown, kokoroOnly: false) }
  }

  public func read(id: String, markdown: String, kokoroOnly: Bool) {
    let segments = Self.segments(markdown)
    guard !segments.isEmpty else { return }
    SessionVoices.silenceOthers?()
    ExplainerVoicePlayer.shared.stop()
    narrator.stop()
    if kokoroOnly {
      narrator.cloud = nil
      narrator.kokoro = KokoroVoice.shared
      narrator.kokoroVoice = Prefs.kokoroVoice.id
    } else {
      _ = narrator.useChosenVoice(cache: cache)
    }
    narrator.rate = Float(Prefs.panel.speed)
    speaking = id
    isPaused = false
    narrator.speak(segments)
  }

  public func playPause() {
    guard speaking != nil else { return }
    narrator.togglePause()
    isPaused = narrator.isPaused
  }

  public func stop() {
    guard speaking != nil else { return }
    narrator.stop()
    speaking = nil
    isPaused = false
  }

  /// What's said: the prose and lists, not code, diagrams or tables.
  static func segments(_ markdown: String) -> [Segment] {
    Blocks.split(MarkdownComments.strip(markdown)).enumerated().compactMap { index, block in
      Speech.text(for: block).map { Segment(block: index, text: $0) }
    }
  }
}
