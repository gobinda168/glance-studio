import Foundation
import GlanceCore

/// Watches the session-links folder (StudioClaudeFolders.linksFolder) and reports every valid link each time a file in
/// it changes. A folder's vnode event fires when an entry is added, renamed or removed, which is what the hook's `mv`
/// does.
@MainActor
public final class SessionLinkFolder {
  public var onChange: (([SessionLink]) -> Void)?
  private let url: URL
  private var source: DispatchSourceFileSystemObject?

  public init(url: URL = StudioClaudeFolders.linksFolder) { self.url = url }

  public func start() {
    guard source == nil else { return }
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let fd = open(url.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                           queue: .main)
    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reload() } }
    source.setCancelHandler { close(fd) }
    source.resume()
    self.source = source
    reload()
  }

  /// A terminal closed: its link goes too.
  public func remove(surface: UUID) {
    try? FileManager.default.removeItem(at: url.appendingPathComponent("\(surface.uuidString).json"))
  }

  private func reload() {
    let url = self.url
    DispatchQueue.global(qos: .utility).async {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
      let links = names.compactMap { name -> SessionLink? in
        guard let data = FileManager.default.contents(atPath: url.appendingPathComponent(name).path) else { return nil }
        return SessionLink.parse(fileName: name, data: data, home: NSHomeDirectory())
      }
      DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.onChange?(links) } }
    }
  }
}
