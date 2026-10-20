import CoreServices
import Foundation

/// FSEvents on a folder, debounced: `onChange` gets the changed paths (real paths, /private/var/… for /var/…) once
/// nothing has changed for `debounce` seconds. The library's own watch (0.5 s) and files triggers (2 s) use it.
/// `accept` sees each raw batch of paths as FSEvents delivers it (before the debounce, so what it knows is how
/// things stood when the change happened, not when it is reported): a batch it refuses is dropped.
@MainActor
final class FolderWatcher {
  private final class Box: @unchecked Sendable {
    let changed: @Sendable ([String]) -> Void
    init(_ changed: @escaping @Sendable ([String]) -> Void) { self.changed = changed }
  }

  private var stream: FSEventStreamRef?
  /// Also retained by the stream itself (the context's retain/release), so a callback already on its way when
  /// `stop` runs still finds it alive.
  private var box: Box?
  private var pending = Set<String>()
  private var flush: DispatchWorkItem?
  private let debounce: TimeInterval
  private let onChange: @MainActor ([String]) -> Void
  private let accept: @MainActor ([String]) -> Bool

  /// nil when FSEvents can't watch `path` (it doesn't exist).
  init?(path: String, debounce: TimeInterval, accept: @escaping @MainActor ([String]) -> Bool = { _ in true },
        onChange: @escaping @MainActor ([String]) -> Void) {
    self.debounce = debounce
    self.accept = accept
    self.onChange = onChange
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let box = Box { [weak self] paths in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(paths) } }
    }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
      retain: { info in
        if let info { _ = Unmanaged<Box>.fromOpaque(info).retain() }
        return info
      },
      release: { info in
        if let info { Unmanaged<Box>.fromOpaque(info).release() }
      }, copyDescription: nil)
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                         | kFSEventStreamCreateFlagNoDefer)
    guard let stream = FSEventStreamCreate(nil, { _, info, _, paths, _, _ in
      guard let info else { return }
      let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
      box.changed(unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [])
    }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
      return nil
    }
    FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return nil
    }
    self.stream = stream
    self.box = box
  }

  /// A watcher dropped without `stop` still lets go of its stream.
  deinit {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }

  func stop() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
    stream = nil
    box = nil
    flush?.cancel()
    pending.removeAll()
  }

  private func received(_ paths: [String]) {
    guard stream != nil, accept(paths) else { return }
    pending.formUnion(paths)
    flush?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.pending.isEmpty else { return }
        let paths = self.pending.sorted()
        self.pending.removeAll()
        self.onChange(paths)
      }
    }
    flush = work
    DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
  }
}
