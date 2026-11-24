import Foundation

/// The `claude` process a tab's session runs under: the stable key to that session's windows in the Glance browser
/// (`BrowserSessionTable.pages(claudePID:session:)`). `/clear` changes the session id but not the process, so a window
/// the wrapper registered under the old id is still found.
public enum SessionClaudePID {
  /// The terminal's foreground process when it is `claude` (it works outside git); else the pid the tracking ledger
  /// recorded when this session started, if that process is still `claude`. Reads files: call it off the main thread.
  public static func find(foregroundPID: Int32?, sessionID: String, cwd: String?, ledger: Ledger = Ledger(),
                          commonDir: (String) -> String? = { GitCommonDir.find(from: $0) },
                          isClaude: (Int32) -> Bool = ProcessTree.isClaude) -> Int32? {
    if let foregroundPID, isClaude(foregroundPID) { return foregroundPID }
    func pid(in repo: String) -> Int32? { ledger.state(repo: repo).sessions[sessionID]?.pid }
    var found = cwd.flatMap(commonDir).flatMap(pid(in:))
    // The hooks key a repository by git's spelling of its folder, which can differ from ours: a session id is unique,
    // so the other repositories are tried before giving up.
    if found == nil { found = ledger.repos().lazy.compactMap(pid(in:)).first }
    return found.flatMap { isClaude($0) ? $0 : nil }
  }
}
