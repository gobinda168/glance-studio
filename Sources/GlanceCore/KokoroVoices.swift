/// The Kokoro-82M voices offered in Settings: the best-rated English ones, default first.
public enum KokoroVoices {
  public static let all: [VoiceOption] = [
    VoiceOption(id: "af_heart", name: "Heart", detail: "American · warm"),
    VoiceOption(id: "af_bella", name: "Bella", detail: "American · bright"),
    VoiceOption(id: "af_nicole", name: "Nicole", detail: "American · soft, close"),
    VoiceOption(id: "af_sarah", name: "Sarah", detail: "American · clear"),
    VoiceOption(id: "am_michael", name: "Michael", detail: "American · calm"),
    VoiceOption(id: "am_fenrir", name: "Fenrir", detail: "American · deep"),
    VoiceOption(id: "bf_emma", name: "Emma", detail: "British · measured"),
    VoiceOption(id: "bm_george", name: "George", detail: "British · steady"),
  ]

  public static var defaultVoice: VoiceOption { all[0] }

  /// The saved voice, or the default when nothing (or a voice Glance doesn't offer) is saved.
  public static func option(id: String?) -> VoiceOption {
    all.first { $0.id == id } ?? defaultVoice
  }
}
