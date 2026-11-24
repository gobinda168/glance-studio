import Foundation
import ImageIO

/// One clip being written. Frames arrive from the connection's queue (`offer`); decoding and writing run on a shared serial
/// queue, and only there, so the writer is never used from two threads.
final class ClipSink: @unchecked Sendable {
  static let minGap = 0.05
  static let deepest = 6
  static let decodeQueue = DispatchQueue(label: "dev.glance.clips.decode", qos: .userInitiated)

  let target: String
  let url: String
  let file: URL
  let owner: ClipOwner
  /// The session the clip was filed in, once it was.
  var filedSession: String?
  /// Called (on the decode queue) for each frame handed to the writer.
  var onFrame: (@Sendable () -> Void)?

  private let queue: DispatchQueue
  private let writer: VideoWriter
  private let lock = NSLock()
  private var queued = 0
  // Decode queue only:
  private var origin: Double?
  private var lastWritten = -Double.infinity
  private var held: (data: Data, at: Double)?
  private var closed = false

  init(target: String, url: String, file: URL, owner: ClipOwner, queue: DispatchQueue = ClipSink.decodeQueue) throws {
    self.queue = queue
    self.target = target
    self.url = url
    self.file = file
    self.owner = owner
    writer = try VideoWriter(url: file, width: 1280, height: 720, bitrate: 2_000_000, fps: 10, keyframeSeconds: 2, realtime: true)
  }

  /// Frames accepted by `offer` that the decode queue hasn't started on yet.
  var pending: Int {
    lock.lock()
    defer { lock.unlock() }
    return queued
  }

  /// A frame from the browser (any thread). It never waits: when the decoder is far behind the frame is dropped (the
  /// connection already acked it).
  func offer(_ data: Data, at time: Double) {
    lock.lock()
    let room = queued < Self.deepest
    if room { queued += 1 }
    lock.unlock()
    guard room else { return }
    queue.async {
      self.lock.lock()
      self.queued -= 1
      self.lock.unlock()
      self.receive(data, at: time)
    }
  }

  /// At most one frame per 50 ms is written; the newest one in between is held, and goes in when the clip ends.
  private func receive(_ data: Data, at time: Double) {
    guard !closed, time > lastWritten else { return }
    if time - lastWritten >= Self.minGap, write(data, at: time) {
      held = nil
    } else {
      held = (data, time)
    }
  }

  private func write(_ data: Data, at time: Double) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
    let base = origin ?? time
    guard writer.append(image, at: time - base) else { return false }
    origin = base
    lastWritten = time
    onFrame?()
    return true
  }

  /// Writes the held frame, takes no more, and says how many frames the video has.
  func flush() async -> Int {
    await withCheckedContinuation { continuation in
      queue.async {
        if !self.closed, let held = self.held, held.at > self.lastWritten { _ = self.write(held.data, at: held.at) }
        self.held = nil
        self.closed = true
        continuation.resume(returning: self.writer.frames)
      }
    }
  }

  /// Ends the video where the clip ended (the last picture stays until then). Call after `flush`.
  func finish(at end: Date) async throws {
    let base = await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.origin) } }
    try await writer.finish(at: end.timeIntervalSince1970 - (base ?? end.timeIntervalSince1970))
  }

  /// Stops the writer and removes the file.
  func cancel() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.closed = true
        self.held = nil
        self.writer.cancel()
        continuation.resume()
      }
    }
  }

  /// Waits for what was queued before this call.
  func drain() async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
  }
}

/// The clips being recorded, by page, for the connection's queue to hand frames to.
final class SinkTable: @unchecked Sendable {
  private let lock = NSLock()
  private var sinks: [String: ClipSink] = [:]

  func set(_ target: String, _ sink: ClipSink) {
    lock.lock()
    sinks[target] = sink
    lock.unlock()
  }

  func remove(_ target: String, _ sink: ClipSink) {
    lock.lock()
    if sinks[target] === sink { sinks[target] = nil }
    lock.unlock()
  }

  func deliver(_ target: String, _ data: Data, at time: Double) {
    lock.lock()
    let sink = sinks[target]
    lock.unlock()
    sink?.offer(data, at: time)
  }

  func drain() async {
    for sink in current() { await sink.drain() }
  }

  private func current() -> [ClipSink] {
    lock.lock()
    defer { lock.unlock() }
    return Array(sinks.values)
  }
}
