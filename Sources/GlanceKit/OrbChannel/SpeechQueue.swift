import Foundation
import GlanceCore

/// One voice for the orb channel (spec "Voice"): sessions' `speak`, questions read aloud and the assistant's answers
/// take turns, never over each other, and wait for the panel's own narration to end. Nothing is said during a
/// meeting or Do not disturb.
@MainActor
final class SpeechQueue {
  static let shared = SpeechQueue()

  /// True while Glance's panel (or the overlay's) is reading a reply; the queue waits for it.
  var otherSpeech: () -> Bool = { false }
  var onSpeaking: ((Bool) -> Void)?
  private(set) var isSpeaking = false

  private struct Item {
    let text: String
    let done: (Bool) -> Void
    /// When this item first met other speech; it gives up `patience` after.
    var waitingSince: Date?
  }

  private let narrator = Narrator()
  private let cache = AudioCache(limit: 2 << 20)
  private var items: [Item] = []
  private var current: Item?
  private var waitTimer: Timer?
  private var watchdog: Timer?
  /// Gives up on an item after waiting this long for other speech to end.
  private static let patience: TimeInterval = 60
  /// Roughly how fast speech runs, for the watchdog on a playing item.
  private static let charactersPerSecond = 15.0

  private init() {
    narrator.onFinish = { [weak self] in self?.finished(spoken: true) }
  }

  /// Why nothing may be said now, or nil.
  static func quietReason() -> String? {
    if MeetingNudger.shared.isInMeeting { return "The user is in a meeting." }
    if NotificationHub.shared.prefs.doNotDisturb { return "The user has Do not disturb on." }
    return nil
  }

  func say(_ text: String, interrupt: Bool, done: @escaping (Bool) -> Void) {
    if interrupt {
      dropWaiting()
      if current != nil {
        narrator.stop()
        finished(spoken: false)
      }
    }
    items.append(Item(text: text, done: done))
    advance()
  }

  func stopAll() {
    dropWaiting()
    narrator.stop()
    if current != nil { finished(spoken: false) }
  }

  private func dropWaiting() {
    let dropped = items
    items.removeAll()
    waitTimer?.invalidate()
    waitTimer = nil
    dropped.forEach { $0.done(false) }
  }

  private func advance() {
    guard current == nil, let next = items.first else {
      if current == nil { waitTimer?.invalidate(); waitTimer = nil }
      return
    }
    if Self.quietReason() != nil {
      removeHead()
      next.done(false)
      return advance()
    }
    if otherSpeech() {
      let since = next.waitingSince ?? Date()
      items[0].waitingSince = since
      if Date().timeIntervalSince(since) > Self.patience {
        removeHead()
        next.done(false)
        return advance()
      }
      waitTimer?.invalidate()
      let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.advance() }
      }
      RunLoop.main.add(timer, forMode: .common)
      waitTimer = timer
      return
    }
    removeHead()
    current = next
    setSpeaking(true)
    _ = narrator.useChosenVoice(cache: cache)
    narrator.rate = Float(Prefs.panel.speed)
    narrator.speak([Segment(block: 0, text: next.text)])
    // If playback never reports its end, don't hold the queue forever.
    let limit = max(Self.patience, 2 * Double(next.text.count) / Self.charactersPerSecond)
    let timer = Timer(timeInterval: limit, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.current != nil else { return }
        self.narrator.stop()
        self.finished(spoken: false)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    watchdog = timer
  }

  /// Takes the head item off the queue; the wait timer was for it.
  private func removeHead() {
    items.removeFirst()
    waitTimer?.invalidate()
    waitTimer = nil
  }

  private func finished(spoken: Bool) {
    guard let item = current else { return }
    current = nil
    watchdog?.invalidate()
    watchdog = nil
    setSpeaking(false)
    item.done(spoken)
    advance()
  }

  private func setSpeaking(_ on: Bool) {
    guard on != isSpeaking else { return }
    isSpeaking = on
    onSpeaking?(on)
  }
}
