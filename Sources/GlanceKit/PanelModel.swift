import GlanceCore

/// What the panel shows. Every change that the page draws calls `onChange`.
@MainActor
final class PanelModel {
  var onChange: (() -> Void)?

  var state: OrbState = .idle { didSet { if state != oldValue { onChange?() } } }
  var hasReply = false { didSet { if hasReply != oldValue { onChange?() } } }
  /// Why another voice is reading instead of the chosen one, e.g. "Glance Voice · ElevenLabs quota used · resets 3 Nov".
  var voiceNotice: String? { didSet { if voiceNotice != oldValue { onChange?() } } }
  var project = ""
  var voiceName = ""
  var muted = true
}
