import Foundation
import GlanceCore

/// `glance meeting-check [--notes] <call audio> [mic audio]`: the meeting pipeline on files, without Studio (spec
/// 2026-10-09-meeting-notes-design.md, "Testing"). Transcribes each file as its channel, tells the call's speakers
/// apart, prints the transcript with timings, and releases the models. Downloads them on first use. `--notes` then
/// has Claude Code write the notes and prints them as Markdown.
public enum MeetingCheckCommand {
  public static func run(_ given: [String]) -> Int32 {
    let notes = given.contains("--notes")
    let arguments = given.filter { $0 != "--notes" }
    guard let call = arguments.first else {
      print("usage: glance meeting-check [--notes] <call audio file> [mic audio file]")
      return 2
    }
    let box = Box()
    Task.detached {
      do {
        let models = MeetingSpeechModels.shared
        let loadStart = Date()
        try await models.loadTranscription { fraction, phase in
          print(String(format: "%@ %3.0f%%", phase, fraction * 100))
        }
        print(String(format: "transcription model ready in %.1f s", Date().timeIntervalSince(loadStart)))
        var files: [(TranscriptLine.Channel, URL)] = [(.system, URL(fileURLWithPath: call))]
        if arguments.count > 1 { files.append((.mic, URL(fileURLWithPath: arguments[1]))) }
        var lines: [TranscriptLine] = []
        var audioSeconds = 0.0
        let start = Date()
        var callURL: URL?
        for (channel, url) in files {
          let samples = try MeetingAudioFile.samples(at: url)
          audioSeconds += Double(samples.count) / Double(SpeechChunker.sampleRate)
          lines += try await MeetingPipeline.transcribe(samples, channel: channel, models: models)
          if channel == .system {
            // The diarizer reads a 16 kHz file; write the samples as the recorder does.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("glance-meeting-check.caf")
            try? FileManager.default.removeItem(at: copy)
            let file = try MeetingAudioFile(url: copy)
            file.append(samples)
            file.close()
            callURL = copy
          }
        }
        let transcribed = Date().timeIntervalSince(start)
        await models.releaseTranscription()
        let labelStart = Date()
        lines = await MeetingPipeline.label(lines.sorted { $0.start < $1.start }, systemAudio: callURL, models: models)
        let record = MeetingRecord(id: "check", title: MeetingNotesWriter.untitled, start: Date(),
                                   end: Date().addingTimeInterval(audioSeconds), lines: lines)
        print(MeetingTranscript.text(record))
        print(String(format: "%.1f s of audio · transcribed in %.1f s (%.0f× real time) · speakers in %.1f s · %d lines, "
                     + "%d speakers", audioSeconds, transcribed, audioSeconds / max(transcribed, 0.001),
                     Date().timeIntervalSince(labelStart), lines.count, Set(lines.map(\.speaker)).count))
        guard notes, !lines.isEmpty else {
          box.status = lines.isEmpty ? 1 : 0
          return
        }
        let notesStart = Date()
        await MainActor.run {
          MeetingNotesWriter.notes(for: record) { result in
            switch result {
            case .success(let summary):
              var done = record
              done.summary = summary
              if let title = summary.title { done.title = title }
              print("\n" + MeetingMarkdown.notes(done))
              print(String(format: "notes in %.1f s", Date().timeIntervalSince(notesStart)))
              box.status = 0
            case .failure(let error):
              print("notes failed: \(error.localizedDescription)")
              box.status = 1
            }
          }
        }
      } catch {
        print("meeting-check failed: \(error.localizedDescription)")
        box.status = 1
      }
    }
    return box.wait()
  }

  private final class Box: @unchecked Sendable {
    var status: Int32?

    func wait() -> Int32 {
      while status == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
      return status ?? 1
    }
  }
}
