import Foundation
import GlanceCore

/// The user's Node.js (18 or later) for the Glance browser: the login shell's PATH (nvm, volta, fnm set up in rc files),
/// then the usual install places, then nvm's newest version.
public enum NodeLocator {
  public struct Found: Sendable {
    public let node: String
    /// A PATH for the broker and npm: node's folder first, then the login PATH.
    public let path: String
  }

  public static let missing = "The Glance browser needs Node.js 18 or later (nodejs.org)"

  /// Blocking (runs a login shell): call off the main thread. `loginPath` nil asks the login shell.
  public static func find(loginPath: String? = nil, home: String = NSHomeDirectory()) -> Found? {
    let login = loginPath ?? ClaudeLocator.loginPath() ?? ""
    var folders = login.split(separator: ":").map(String.init)
    folders += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.volta/bin"]
    let nvm = "\(home)/.nvm/versions/node"
    let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
    folders += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
    var seen = Set<String>()
    for folder in folders where !folder.isEmpty && seen.insert(folder).inserted {
      let node = (folder as NSString).appendingPathComponent("node")
      guard FileManager.default.isExecutableFile(atPath: node), major(of: node) >= 18 else { continue }
      let path = ([folder] + login.split(separator: ":").map(String.init) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
      return Found(node: node, path: path)
    }
    return nil
  }

  private static func major(of node: String) -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = ["-p", "process.versions.node"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return 0 }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return Int(text.split(separator: ".").first ?? "") ?? 0
  }
}
