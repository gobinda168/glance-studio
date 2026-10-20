import AppKit

/// An fn hold dictating into the quick-reply panel's composer: the card shows Listening… and the words so far, and the
/// words land at the end of the text box for the user to read, change with Claude, and send. Nothing is sent by it.
@MainActor
final class QuickReplyVoice: VoiceDivert {
  private let model: QuickReplyModel
  /// `release.end()` runs once per hold, though `finished` can fall through to `failed`.
  private var ended = false

  init(model: QuickReplyModel) {
    self.model = model
    CardVoiceAnswer.release.begin()
  }

  func began() { model.voiceBegan() }

  func heard(_ partial: String) { model.voiceHeard(partial) }

  func transcribing() { model.voiceTranscribing() }

  func finished(_ text: String) {
    stop()
    model.voiceFinished(text)
  }

  func failed(_ message: String) {
    stop()
    model.voiceFailed(message)
  }

  private func stop() {
    guard !ended else { return }
    ended = true
    CardVoiceAnswer.release.end()
  }
}

extension QuickReplyPanel {
  /// The divert for an fn hold while the panel is the window taking the keyboard, else nil.
  public func voiceDivert() -> VoiceDivert? {
    guard let model = keyModel else { return nil }
    return QuickReplyVoice(model: model)
  }
}
