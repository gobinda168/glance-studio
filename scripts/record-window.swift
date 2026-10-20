// Records one app's front window, with that app's own sound, to a .mov. For the landing page's feature clips.
// Build: swiftc -O scripts/record-window.swift -o build/record-window   (scripts/record-demo.sh does this)
// Run:   build/record-window <bundle id> <out.mov> <seconds> [--cursor] [--title <title>]
// Only the app's windows are captured (other apps and the wallpaper are left out), cropped to its front window, at the
// display's full resolution. With --title it waits (up to 15 s) for the app's window with that title and records it. Touches <out.mov>.ready once frames are flowing, so a caller can start the scene then.
// Ctrl-C stops early and still finishes the file.
// --tap: the sound comes from a Core Audio tap of everything the Mac plays, written to <out.mov>.caf beside the video
// (ScreenCaptureKit doesn't hear Glance's voice). Needs System Audio Recording permission, like the screen.
// Also: build/record-window <bundle id> --card  exits 0 when Glance's floating card is on screen, 1 when it isn't. Needs Screen Recording permission for the terminal that runs it.
import AppKit
import AVFoundation
import CoreAudio
import ScreenCaptureKit

let args = CommandLine.arguments

// The floating card: a panel above the windows (layer 3) the size of the pane, unlike the orb beside it.
if args.count == 3, args[2] == "--card" {
  let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
  let open = content.windows.contains {
    $0.owningApplication?.bundleIdentifier == args[1] && $0.windowLayer > 0 && $0.frame.width >= 300 && $0.frame.height >= 300
  }
  exit(open ? 0 : 1)
}

guard args.count >= 4, let seconds = Double(args[3]) else {
  FileHandle.standardError.write("usage: record-window <bundle id> <out.mov> <seconds> [--cursor] [--title <title>]\n".data(using: .utf8)!)
  exit(2)
}
let bundleID = args[1]
let out = URL(fileURLWithPath: args[2])
let showsCursor = args.contains("--cursor")
// Every app's sound (and windows), not just this app's: for when the app's own audio doesn't come through.
let allApps = args.contains("--all-apps")
let tapAudio = args.contains("--tap")
let title = args.firstIndex(of: "--title").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }

func fail(_ message: String) -> Never {
  FileHandle.standardError.write("record-window: \(message)\n".data(using: .utf8)!)
  exit(1)
}

/// Frames have to go somewhere or ScreenCaptureKit logs a drop for each one; the recording output does the writing.
final class Sink: NSObject, SCStreamOutput {
  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

final class Finish: NSObject, SCRecordingOutputDelegate {
  var done: CheckedContinuation<Void, Never>?
  var error: Error?
  func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { done?.resume(); done = nil }
  func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
    self.error = error
    done?.resume()
    done = nil
  }
}

func shareable() async -> SCShareableContent {
  do {
    return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
  } catch {
    fail("can't list windows (\(error.localizedDescription)). Allow Screen Recording for this terminal in System Settings → Privacy & Security, then run it again.")
  }
}

// The window: the titled one when asked for, else the front one (the list runs front to back). Normal windows are
// layer 0; small ones are popovers or the orb.
func pick(_ content: SCShareableContent) -> SCWindow? {
  content.windows.first {
    $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 && $0.frame.width > 400
      && $0.frame.height > 300 && (title == nil || $0.title == title)
  }
}

var content = await shareable()
var found = pick(content)
let deadline = Date().addingTimeInterval(title == nil ? 0 : 15)
while found == nil, Date() < deadline {
  try? await Task.sleep(for: .milliseconds(50))
  content = await shareable()
  found = pick(content)
}
guard let window = found, let app = window.owningApplication else {
  fail(title.map { "no \"\($0)\" window for \(bundleID)" } ?? "no on-screen window for \(bundleID); is the app open?")
}
guard let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) ?? content.displays.first
else { fail("no display") }

let scale = NSScreen.screens.first { $0.frame.width == display.frame.width && $0.frame.height == display.frame.height }?
  .backingScaleFactor ?? 2
// Window and display frames share global coordinates (top-left origin); sourceRect is relative to the display.
let rect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).integral

let filter = allApps
  ? SCContentFilter(display: display, excludingWindows: [])
  : SCContentFilter(display: display, including: [app], exceptingWindows: [])
let config = SCStreamConfiguration()
config.sourceRect = rect
config.width = Int(rect.width * scale)
config.height = Int(rect.height * scale)
config.captureResolution = .best
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
config.showsCursor = showsCursor
config.capturesAudio = !tapAudio
config.sampleRate = 48_000
config.channelCount = 2
config.queueDepth = 8

try? FileManager.default.removeItem(at: out)
let recordingConfig = SCRecordingOutputConfiguration()
recordingConfig.outputURL = out
recordingConfig.outputFileType = .mov
recordingConfig.videoCodecType = .hevc
let finish = Finish()
let recording = SCRecordingOutput(configuration: recordingConfig, delegate: finish)

let stream = SCStream(filter: filter, configuration: config, delegate: nil)
let sink = Sink()
let queue = DispatchQueue(label: "record-window")
do {
  try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: queue)
  if !tapAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: queue) }
  try stream.addRecordingOutput(recording)
  try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
    stream.startCapture { error in if let error { started.resume(throwing: error) } else { started.resume() } }
  }
} catch {
  fail("can't start capture (\(error.localizedDescription))")
}

let tap = tapAudio ? AudioTap(file: URL(fileURLWithPath: out.path + ".caf")) : nil
do { try tap?.start() } catch { stream.stopCapture { _ in }; fail("can't tap the Mac's sound (\(error))") }

let ready = URL(fileURLWithPath: out.path + ".ready")
FileManager.default.createFile(atPath: ready.path, contents: nil)
print("recording \(app.applicationName) \(Int(rect.width))×\(Int(rect.height)) pt at \(scale)× for \(seconds)s → \(out.path)")

// Stop after `seconds`, or on Ctrl-C / SIGTERM, whichever comes first.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signals = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0, queue: .main) }
await withCheckedContinuation { (stop: CheckedContinuation<Void, Never>) in
  var stopped = false
  let once = { if !stopped { stopped = true; stop.resume() } }
  signals.forEach { $0.setEventHandler(handler: once); $0.resume() }
  DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: once)
}

await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
  finish.done = done
  stream.stopCapture { _ in }
}
tap?.stop()
try? FileManager.default.removeItem(at: ready)
if let error = finish.error { fail("recording failed (\(error.localizedDescription))") }
print("saved \(out.path)")

/// Everything the Mac plays, through a Core Audio process tap in a private aggregate device (the way Glance's meeting
/// notes hear a call), written to a file as it arrives.
final class AudioTap: @unchecked Sendable {
  struct Failure: Error, CustomStringConvertible {
    let step: String, status: OSStatus
    var description: String { "\(step): \(status)" }
  }

  private let url: URL
  private var file: AVAudioFile?
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private let queue = DispatchQueue(label: "record-window.tap")
  private var frames: AVAudioFramePosition = 0
  /// When the tap started, in host time: the file's time zero, so its sound lines up with the video's frames.
  private var startHost: UInt64 = 0
  private var sampleRate = 48_000.0
  private var failure: String?

  init(file: URL) { url = file }

  func start() throws {
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    description.uuid = UUID()
    description.name = "record-window"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    try check(AudioHardwareCreateProcessTap(description, &tapID), "tap")

    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "format")
    guard let tapFormat = AVAudioFormat(streamDescription: &format) else { throw Failure(step: "format", status: -1) }
    sampleRate = tapFormat.sampleRate
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: tapFormat.settings, commonFormat: tapFormat.commonFormat,
                               interleaved: tapFormat.isInterleaved)
    self.file = file

    let output = try Self.defaultOutputUID()
    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey: "record-window",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: output,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
      kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                         kAudioSubTapUIDKey: description.uuid.uuidString]],
    ]
    try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "aggregate device")
    startHost = mach_absolute_time()
    try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, inputTime, _, _ in
      guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil) else { return }
      do {
        // The tap only delivers while something plays: fill what it skipped with silence, so pauses keep their length.
        if inputTime.pointee.mFlags.contains(.hostTimeValid), inputTime.pointee.mHostTime > self.startHost {
          let seconds = Double(AudioConvertHostTimeToNanos(inputTime.pointee.mHostTime - self.startHost)) / 1e9
          let gap = AVAudioFramePosition(seconds * tapFormat.sampleRate) - self.frames
          if gap > AVAudioFramePosition(tapFormat.sampleRate / 50), let silence = AVAudioPCMBuffer(
            pcmFormat: tapFormat, frameCapacity: AVAudioFrameCount(gap)) {
            silence.frameLength = AVAudioFrameCount(gap)
            for b in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) where b.mData != nil {
              memset(b.mData, 0, Int(b.mDataByteSize))
            }
            try file.write(from: silence)
            self.frames += gap
          }
        }
        try file.write(from: buffer)
        self.frames += AVAudioFramePosition(buffer.frameLength)
      } catch {
        self.failure = "\(error)"
      }
    }, "IO proc")
    try check(AudioDeviceStart(aggregateID, procID), "start")
  }

  func stop() {
    if aggregateID != kAudioObjectUnknown {
      if let procID {
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
      }
      AudioHardwareDestroyAggregateDevice(aggregateID)
    }
    if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    // After the last buffer: close the file, which writes what AVAudioFile still holds.
    queue.sync { file?.close() }
    file = nil
    print(String(format: "sound: %.1f s tapped", Double(frames) / sampleRate) + (failure.map { " (a write failed: \($0))" } ?? ""))
  }

  private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw Failure(step: step, status: status) }
  }

  private static func defaultOutputUID() throws -> String {
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    guard status == noErr else { throw Failure(step: "output device", status: status) }
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    address.mSelector = kAudioDevicePropertyDeviceUID
    status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
    guard status == noErr, let uid else { throw Failure(step: "output device UID", status: status) }
    return uid.takeRetainedValue() as String
  }
}
