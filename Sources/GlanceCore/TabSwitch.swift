import Foundation

/// Open in Editor / Open in Terminal (spec 2026-10-11-strip-switching-design.md §4): the project's open tab when
/// there is one, never a second; else a new one. Folders compare normalized (`SessionMatch.normalize`).
public enum TabSwitch {
  public enum Target<Tab: Equatable>: Equatable {
    case reuse(Tab)
    case create
  }

  /// Home and the disk's root: a shell there is in no project, so the Editor start page asks which folder.
  public static func isProjectless(_ project: String, home: String) -> Bool {
    let folder = SessionMatch.normalize(project, home: home)
    return folder == SessionMatch.normalize(home, home: home) || folder == "/"
  }

  /// The editor tab (either kind) on `project`, else create one.
  public static func editor<Tab: Equatable>(for project: String, editors: [(tab: Tab, root: String)],
                                            home: String) -> Target<Tab> {
    let wanted = SessionMatch.normalize(project, home: home)
    guard let open = editors.first(where: { SessionMatch.normalize($0.root, home: home) == wanted }) else { return .create }
    return .reuse(open.tab)
  }

  /// The terminal in `project` that was in front most recently (else the last in tab order), else create one.
  public static func terminal<Tab: Hashable & Sendable>(for project: String, terminals: [(tab: Tab, project: String)],
                                                        memory: StripMemory<Tab>, home: String) -> Target<Tab> {
    let wanted = SessionMatch.normalize(project, home: home)
    let mine = terminals.filter { SessionMatch.normalize($0.project, home: home) == wanted }.map(\.tab)
    guard let tab = memory.mostRecent(of: mine) ?? mine.last else { return .create }
    return .reuse(tab)
  }
}
