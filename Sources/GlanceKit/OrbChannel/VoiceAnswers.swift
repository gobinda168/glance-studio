import AppKit
import GlanceCore

/// An fn hold answering the active orb-channel card (spec "Voice"): the card shows Listening… and the words, then
/// "Heard: … · Undo" for 2 s, then the answer goes. Parakeet is freed after 3 idle minutes unless a meeting is being
/// transcribed.
@MainActor
final class CardVoiceAnswer: VoiceDivert {
  private let cardID: String
  /// `release.end()` runs once per hold, though `finished` can fall through to `failed`.
  private var ended = false
  private static var pending: DispatchWorkItem?
  static let undoWindow: TimeInterval = 2
  static let release = IdleRelease(after: .seconds(180)) {
    guard !MeetingRecorder.shared.isBusy else { return }
    await MeetingSpeechModels.shared.releaseTranscription()
  }

  init(cardID: String) {
    self.cardID = cardID
    Self.release.begin()
  }

  private var model: ChannelCardsModel { ChannelCards.shared.model }

  func began() {
    // A new hold takes back an answer still in its Undo window.
    Self.cancelPending()
    model.voiceError = nil
    model.heard = nil
    model.partial = nil
    model.transcribing = false
    model.listening = true
    OrbChannelHub.shared.listening = true
  }

  func heard(_ partial: String) { model.partial = partial }

  func transcribing() {
    model.listening = false
    model.partial = nil
    model.transcribing = true
    OrbChannelHub.shared.listening = false
  }

  func finished(_ text: String) {
    stopListening()
    let book = OrbChannelHub.shared.book
    guard book.cards.contains(where: { $0.id == cardID }) else { return failed("That card was already answered") }
    // A prompt card came up over this card during the hold: it's hidden now, so it isn't answered.
    guard ChannelCards.shared.model.prompt == nil, let card = book.active, card.id == cardID else {
      return failed(Self.cardChanged)
    }
    let answer: ChannelBook.Answer
    switch card.kind {
    case .question(let choices, let allowText):
      switch SpokenAnswer.match(text, choices: choices, allowText: allowText) {
      case .choice(let index): answer = .choice(choices[index])
      case .text(let said): answer = .text(said)
      default: return failed("Didn't catch that. Say one of the choices.")
      }
    case .nudge(let actions):
      switch SpokenAnswer.match(text, choices: actions, allowText: false) {
      case .choice(let index): answer = .action(actions[index])
      default: return failed("Didn't catch that. Say one of the buttons.")
      }
    case .permission:
      switch SpokenAnswer.permission(text) {
      case .allow: answer = .allow
      case .deny: answer = .deny
      default: return failed("Didn't catch that. Say allow or deny.")
      }
    }
    model.heard = ChannelNotices.said(answer)
    // The controller lets go of this divert when the hold ends, so the send and Undo hold the model, not self.
    let id = cardID
    let model = self.model
    let send = DispatchWorkItem {
      MainActor.assumeIsolated {
        model.heard = nil
        OrbChannelHub.shared.answer(id, answer, via: .voice)
      }
    }
    Self.pending?.cancel()
    Self.pending = send
    ChannelCards.shared.onUndo = {
      send.cancel()
      model.heard = nil
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow, execute: send)
  }

  /// The active card changed in the Undo window: the answer isn't sent (its Undo is gone).
  static let cardChanged = "Answer not sent — the card changed"

  /// Cancels the answer waiting out its Undo window, if any.
  static func cancelPending() {
    pending?.cancel()
    pending = nil
  }

  func failed(_ message: String) {
    stopListening()
    model.voiceError = message.isEmpty ? nil : message
  }

  private func stopListening() {
    model.listening = false
    model.partial = nil
    model.transcribing = false
    OrbChannelHub.shared.listening = false
    guard !ended else { return }
    ended = true
    Self.release.end()
  }
}

/// An fn hold for the orb assistant: the orb shows listening, then the words are sent; its answer comes in Glance's
/// card from the orb, with the question above it.
@MainActor
final class AssistantVoice: VoiceDivert {
  /// `release.end()` runs once per hold, though `finished` can fall through to `failed`.
  private var ended = false

  init() { CardVoiceAnswer.release.begin() }

  func began() { OrbChannelHub.shared.listening = true }

  func heard(_ partial: String) {}

  func transcribing() { OrbChannelHub.shared.listening = false }

  func finished(_ text: String) {
    stop()
    OrbAssistant.shared.send(text)
  }

  func failed(_ message: String) {
    stop()
    guard !message.isEmpty else { return }
    NotificationHub.shared.post(ChannelNotices.message(
      id: "orb-" + UUID().uuidString, label: "Glance", surface: nil, cwd: nil,
      title: "Glance couldn't hear you: \(message)", body: nil, date: Date()))
  }

  private func stop() {
    OrbChannelHub.shared.listening = false
    guard !ended else { return }
    ended = true
    CardVoiceAnswer.release.end()
  }
}

extension OrbChannelHub {
  /// The assistant is on and this hold is for it: the pointer is on an orb or its key is held with fn.
  private var assistantHold: Bool {
    guard Prefs.orbAssistantEnabled else { return false }
    let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let pointer = NSEvent.mouseLocation
    let onOrb = OrbAttention.visibleOrbFrames.contains { $0.insetBy(dx: -8, dy: -8).contains(pointer) }
    return onOrb || modifiers.contains(Prefs.orbAssistantFlag)
  }

  /// The divert for an fn hold, or nil for plain dictation: the orb assistant when the pointer is on an orb or its
  /// key is held with fn; else the active card when one waits. While the assistant waits on an Allow / Deny card,
  /// the hold answers the card.
  public func voiceDivert() -> VoiceDivert? {
    // The quick-reply panel has the keyboard: the hold dictates into its composer, unless the pointer is on an orb or
    // the assistant's key is held (that hold is for the assistant).
    if let reply = QuickReplyPanel.shared.voiceDivert(), !assistantHold { return reply }
    guard running else { return nil }
    // A Claude prompt card shows in the channel card's place (NeedsYouCards): the channel card under it is hidden,
    // so a hold must not answer it. The orb assistant still listens; otherwise it's plain dictation, as with no card.
    let promptShowing = ChannelCards.shared.model.prompt != nil
    if !promptShowing, OrbAssistant.shared.working, let card = book.active, card.isPermission {
      return CardVoiceAnswer(cardID: card.id)
    }
    if assistantHold { return AssistantVoice() }
    guard !promptShowing, let card = book.active else { return nil }
    return CardVoiceAnswer(cardID: card.id)
  }
}
