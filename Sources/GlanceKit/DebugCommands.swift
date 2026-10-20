import AVFoundation
import AppKit
import FluidAudio
import GlanceCore

/// Developer checks against the real services, without the UI.
///   glance transcribe <audio file>   streams a file to Scribe in real time and prints every server message
///   glance type <text>               types text into the frontmost app after 3 seconds
///   glance watch [folder]            prints Claude Code turns as the transcript watcher sees them (Ctrl-C to stop)
///   glance kokoro-fetch              downloads Kokoro and the offered voices into FluidAudio's cache (build time)
///   glance voice-check kokoro [text] speaks text with Kokoro, writes a WAV and prints timings
@MainActor
public enum DebugCommands {
  public static func transcribe(path: String) -> Int32 {
    guard let key = KeychainStore.elevenLabs.read() else {
      print("No ElevenLabs key. Add one in Glance Settings.")
      return 1
    }
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
      (try? file.read(into: buffer)) != nil,
      let converter = PCM16Converter(from: file.processingFormat)
    else {
      print("Can't read audio file \(path)")
      return 1
    }
    let pcm = converter.convert(buffer, endOfStream: true)
    let size = PCM16Converter.chunkBytes
    let chunks = stride(from: 0, to: pcm.count, by: size).map { Data(pcm[$0..<min($0 + size, pcm.count)]) }
    guard !chunks.isEmpty else { print("No audio in \(path)"); return 1 }

    let keyterms = Keyterms.build(reply: "`useEffect` in `Transcript.swift`", projectFiles: [])
    print("keyterms:", keyterms.joined(separator: ", "))
    let client = ScribeClient(key: key, keyterms: keyterms, zeroRetention: Prefs.scribeZeroRetention, previousText: nil)
    var done = false
    var status: Int32 = 0
    client.onRawMessage = { print("←", $0) }
    client.onEvent = { event in
      switch event {
      case .committed: done = true
      case .failure: done = true; status = 1
      default: break
      }
    }
    client.connect()
    Task { @MainActor in
      for (index, chunk) in chunks.enumerated() {
        client.send(audio: chunk, commit: index == chunks.count - 1)
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    let deadline = Date().addingTimeInterval(Double(chunks.count) * 0.1 + 15)
    while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    client.close()
    if !done { print("Timed out waiting for a committed transcript."); return 1 }
    return status
  }

  public static func type(_ text: String) -> Int32 {
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    switch TextInserter.insert(DictationText.finalize(text)) {
    case .inserted: return 0
    case .notAllowed: NSLog("glance type: Accessibility isn't granted"); return 1
    case .secureInput: NSLog("glance type: secure input is on"); return 1
    case .failed: NSLog("glance type: couldn't create key events"); return 1
    }
  }

  /// Prints each prompt and finished turn the transcript watcher sees, with the reply's first words, until Ctrl-C.
  /// With a folder, only sessions working in exactly that folder count, the way Glance Studio matches a split.
  public static func watch(cwd: String?) -> Int32 {
    let watcher = TranscriptWatcher()
    if let cwd {
      let folder = cwd == "." ? FileManager.default.currentDirectoryPath : cwd
      watcher.accepts = { SessionMatch.matches(sessionCwd: $0, surfacePwd: folder) }
    }
    watcher.onEvent = { event in
      let session = URL(fileURLWithPath: event.file).deletingPathExtension().lastPathComponent.prefix(8)
      switch event.kind {
      case .prompt:
        print("prompt  \(event.cwd ?? "?")  [\(session)]")
      case .done:
        let reply = GlanceSession.readReply(event.file).map { String($0.prefix(80)).replacingOccurrences(of: "\n", with: " ") }
        print("done    \(event.cwd ?? "?")  [\(session)]  \(reply ?? "(no text)")")
      }
      fflush(stdout)
    }
    guard watcher.start() else {
      print("Can't watch ~/.claude/projects")
      return 1
    }
    print("Watching ~/.claude/projects\(cwd.map { " for \($0)" } ?? ""). Ctrl-C to stop.")
    fflush(stdout)
    withExtendedLifetime(watcher) { RunLoop.main.run() }
    return 0
  }

  /// Downloads the Kokoro models, G2P assets and every offered voice, then prints the models directory last, for
  /// `scripts/build.sh` to snapshot into the app. The only code path that downloads Kokoro.
  public static func kokoroFetch() -> Int32 {
    let box = StatusBox()
    Task.detached {
      do {
        let manager = KokoroAneManager()
        try await manager.initialize(preloadVoices: Set(KokoroVoices.all.map(\.id)))
        print(try TtsCacheDirectory.ensure().appendingPathComponent("Models").path)
        box.status = 0
      } catch {
        print("Glance Voice (Kokoro) download failed: \(error.localizedDescription)")
        box.status = 1
      }
    }
    return box.wait()
  }

  /// Times loading and one synthesis with the saved Kokoro voice, and writes the audio to a WAV in the temp folder.
  static func kokoroCheck(_ text: String) -> Int32 {
    let box = StatusBox()
    let voice = Prefs.kokoroVoice
    Task { @MainActor in
      do {
        let loadStart = Date()
        try await KokoroVoice.shared.prepare()
        let load = Date().timeIntervalSince(loadStart)
        let start = Date()
        let wav = try await KokoroVoice.shared.wav(for: text, voice: voice.id)
        let elapsed = Date().timeIntervalSince(start)
        let seconds = Double(max(0, wav.count - 44)) / 2 / 24_000
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glance-kokoro.wav")
        try wav.write(to: url)
        print(String(format: "voice: %@ · load %.2f s · speech %.2f s for %.2f s of audio (%.1f× real time)",
                     voice.name, load, elapsed, seconds, seconds / max(elapsed, 0.001)))
        print("wrote \(url.path)")
        box.status = 0
      } catch {
        print("failed: \((error as? TTSFailure)?.message(provider: "Glance Voice") ?? error.localizedDescription)")
        box.status = 1
      }
    }
    return box.wait()
  }

  /// An exit status set from a task, read on the main thread while the run loop services the main actor.
  private final class StatusBox: @unchecked Sendable {
    var status: Int32?

    func wait() -> Int32 {
      while status == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
      return status ?? 1
    }
  }
}
