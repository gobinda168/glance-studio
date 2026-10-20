import Foundation
import GlanceCore

/// A past Claude Code session of a folder, for the Terminal side bar's History.
public struct HistoryEntry: Identifiable, Equatable, Sendable {
  public let id: String
  public let path: String
  public let title: String
  public let updated: Date
  /// The folder it ran in, where `claude --resume` finds it.
  public let cwd: String
  /// In a project's list, the subfolder or worktree it ran in; nil at the project's root.
  public let place: String?
}

/// Lists past Claude Code sessions, newest first, named by their first prompt: a folder's, or a whole project's.
/// Callers read it off the main thread's queue: it opens one file head per session it hasn't named yet.
public enum ClaudeHistory {
  public static let limit = 100

  /// The newest `limit` sessions started in `folder` (or its resolved path, for symlinks).
  public static func sessions(folder: String, limit: Int = limit,
                              projects: URL = ChatFeed.defaultProjects) -> [HistoryEntry] {
    var names: [String] = [ClaudeProjectFolder.name(for: folder)]
    let resolved = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
    if resolved != folder { names.append(ClaudeProjectFolder.name(for: resolved)) }
    let files = names.flatMap { transcripts(projects.appendingPathComponent($0)) }
    return entries(files.map { ($0, folder, nil) }, limit: limit)
  }

  /// The newest `limit` sessions of the project at `root`: its own, its subfolders' and its worktrees'
  /// (`HistoryProject`).
  public static func sessions(project root: String, limit: Int = limit,
                              projects: URL = ChatFeed.defaultProjects) -> [HistoryEntry] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
    var files: [(file: Transcript, cwd: String, place: String?)] = []
    for name in HistoryProject.candidates(names, root: root) {
      let folder = transcripts(projects.appendingPathComponent(name))
      guard let cwd = cache.cwd(of: name, files: folder), HistoryProject.contains(cwd: cwd, root: root) else { continue }
      let place = HistoryProject.place(cwd: cwd, root: root)
      files += folder.map { ($0, cwd, place) }
    }
    return entries(files, limit: limit)
  }

  struct Transcript {
    let path: String
    let id: String
    let updated: Date
  }

  private static func transcripts(_ directory: URL) -> [Transcript] {
    let files = FileManager.default
    return ((try? files.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.map { file in
      let path = directory.appendingPathComponent(file).path
      let date = ((try? files.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
      return Transcript(path: path, id: String(file.dropLast(".jsonl".count)), updated: date)
    }
  }

  private static func entries(_ files: [(file: Transcript, cwd: String, place: String?)], limit: Int) -> [HistoryEntry] {
    files.sorted { $0.file.updated > $1.file.updated }.prefix(limit * 2).compactMap { item in
      // Sessions without a user prompt (opened and closed at once) have nothing to show.
      guard let title = cache.title(of: item.file) else { return nil }
      return HistoryEntry(id: item.file.id, path: item.file.path, title: title, updated: item.file.updated,
                          cwd: item.cwd, place: item.place)
    }.prefix(limit).map { $0 }
  }

  private static let cache = Cache()

  /// What was read off disk already: a transcript's title until it's written again, and a transcript folder's working
  /// folder (one per folder, as Claude Code names the folder after it).
  private final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var titles: [String: (updated: Date, title: String?)] = [:]
    private var folders: [String: String] = [:]

    func title(of file: Transcript) -> String? {
      if let known = lock.withLock({ titles[file.path] }), known.updated == file.updated { return known.title }
      let title = ChatTranscript.title(jsonl: ChatFeed.head(file.path))
      lock.withLock { titles[file.path] = (file.updated, title) }
      return title
    }

    func cwd(of name: String, files: [Transcript]) -> String? {
      if let known = lock.withLock({ folders[name] }) { return known }
      for file in files.sorted(by: { $0.updated > $1.updated }).prefix(3) {
        guard let cwd = HistoryProject.cwd(jsonl: ChatFeed.head(file.path, window: 32 << 10)) else { continue }
        lock.withLock { folders[name] = cwd }
        return cwd
      }
      return nil
    }
  }
}
