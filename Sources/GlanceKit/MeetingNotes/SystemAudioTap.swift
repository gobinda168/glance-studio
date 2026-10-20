@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Everything the Mac plays except Glance Studio itself (spec 2026-10-09-meeting-notes-design.md, "SystemAudioTap"):
/// a Core Audio process tap in a private aggregate device, 16 kHz mono, handed to `onSamples` on the tap's queue.
/// macOS asks once for "System Audio Recording"; until it's allowed the tap hears silence. Started and stopped only on
/// the recorder's capture queue: starting can wait on that permission prompt, which must never block the main thread.
final class SystemAudioTap: @unchecked Sendable {
  enum Failure: LocalizedError {
    case coreAudio(String, OSStatus)
    case format

    var errorDescription: String? {
      switch self {
      case .coreAudio(let step, let status): "Couldn't capture the call's audio (\(step): \(status))."
      case .format: "Couldn't read the call audio's format."
      }
    }
  }

  let level = MeetingLevel()
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private let queue = DispatchQueue(label: "dev.glance.meeting-system-audio", qos: .userInitiated)

  func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
    stop()
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
    description.uuid = UUID()
    description.name = "Glance Meeting Notes"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    var tap = AudioObjectID(kAudioObjectUnknown)
    try check(AudioHardwareCreateProcessTap(description, &tap), "tap")
    tapID = tap

    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "format")
    guard let tapFormat = AVAudioFormat(streamDescription: &format), let resampler = MonoResampler(from: tapFormat)
    else {
      stop()
      throw Failure.format
    }

    let output = try Self.defaultOutputUID()
    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Glance Meeting Notes",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: output,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
      kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                         kAudioSubTapUIDKey: description.uuid.uuidString]],
    ]
    var device = AudioObjectID(kAudioObjectUnknown)
    do {
      try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "aggregate device")
    } catch {
      stop()
      throw error
    }
    aggregateID = device

    let level = self.level
    var proc: AudioDeviceIOProcID?
    let created = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { @Sendable _, input, _, _, _ in
      guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil) else {
        return
      }
      level.value = MonoResampler.level(buffer)
      onSamples(resampler.convert(buffer))
    }
    do {
      try check(created, "IO proc")
      procID = proc
      try check(AudioDeviceStart(device, proc), "start")
    } catch {
      stop()
      throw error
    }
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
    procID = nil
    aggregateID = AudioObjectID(kAudioObjectUnknown)
    tapID = AudioObjectID(kAudioObjectUnknown)
    level.value = 0
  }

  private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw Failure.coreAudio(step, status) }
  }

  /// Glance Studio's own audio object, so Glance Voice reading a reply isn't recorded. Empty when Core Audio doesn't
  /// know the process yet.
  private static func ownProcessObjects() -> [AudioObjectID] {
    var pid = ProcessInfo.processInfo.processIdentifier
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
    return status == noErr && object != kAudioObjectUnknown ? [object] : []
  }

  private static func defaultOutputUID() throws -> String {
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    guard status == noErr else { throw Failure.coreAudio("output device", status) }
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    address.mSelector = kAudioDevicePropertyDeviceUID
    status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
    guard status == noErr, let uid else { throw Failure.coreAudio("output device UID", status) }
    return uid.takeRetainedValue() as String
  }
}
