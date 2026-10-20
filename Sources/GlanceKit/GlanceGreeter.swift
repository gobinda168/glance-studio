import Foundation
import GlanceCore

/// Says one line in the voice chosen in Settings → Voice, on its own narrator (no pane, no reply), and reports how
/// loud it is right now so an orb can move with it. First Light's Voice step greets the user with it.
@MainActor
public final class GlanceGreeter {
  private let narrator = Narrator()
  private let cache = AudioCache(limit: 2 << 20)

  /// The voice has started (its first audio is playing) or stopped.
  public var onSpeakingChange: ((Bool) -> Void)?

  public init() {
    narrator.onSegmentStart = { [weak self] _, _ in self?.onSpeakingChange?(true) }
    narrator.onFinish = { [weak self] in self?.onSpeakingChange?(false) }
  }

  /// The voice's loudness, 0…1 (RMS), safe to read every frame.
  public var level: Double { Double(min(narrator.level.value * 4, 1)) }

  /// Reads `text` with the current voice; a new line replaces one still playing.
  public func say(_ text: String) {
    narrator.stop()
    _ = narrator.useChosenVoice(cache: cache)
    narrator.rate = Float(Prefs.panel.speed)
    narrator.speak([Segment(block: 0, text: text)])
  }

  public func stop() {
    narrator.stop()
    onSpeakingChange?(false)
  }
}
