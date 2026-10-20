import Foundation
import GlanceCore

/// Says a nudge out loud ("Hey Gobinda, Sprint planning starts in 2 minutes.") in the voice from Settings → Voice, on
/// its own narrator: it doesn't open the pane or write into its reply.
@MainActor
final class NudgeVoice {
  static let shared = NudgeVoice()

  private let narrator = Narrator()
  private let cache = AudioCache(limit: 2 << 20)

  /// The first word of the Mac account's name, as Home greets the user.
  static var name: String? { HomeState.greetingName(fullName: NSFullUserName()) }

  func say(_ text: String) {
    _ = narrator.useChosenVoice(cache: cache)
    narrator.rate = Float(Prefs.panel.speed)
    narrator.speak([Segment(block: 0, text: text)])
  }
}
