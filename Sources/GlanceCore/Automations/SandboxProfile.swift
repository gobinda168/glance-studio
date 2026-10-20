import Foundation

/// The sandbox-exec (SBPL) profile a script step and a watcher run under (spec "Runs", *Script steps*): read
/// anywhere; write only to the run directory, the library's state/, the temp directories and `permissions.folders`;
/// network only when `permissions.network`.
public enum SandboxProfile {
  /// The per-user and shared temp roots (`/tmp` and `$TMPDIR` resolve under them).
  public static let tempDirectories = ["/private/tmp", "/private/var/folders"]
  /// Devices a shell writes to.
  static let devices = ["/dev/null", "/dev/zero", "/dev/tty", "/dev/stdout", "/dev/stderr", "/dev/dtracehelper"]

  /// `home` expands "~" in folders. Paths under /tmp, /var and /etc also get their /private form (what the kernel
  /// checks).
  public static func make(permissions: AutomationPermissions, runDirectory: String, stateDirectory: String,
                          home: String) -> String {
    var writable = [runDirectory, stateDirectory] + tempDirectories
    writable += permissions.folders.map { expand($0, home: home) }
    var paths: [String] = []
    for path in writable.flatMap(variants) where !paths.contains(path) { paths.append(path) }
    var lines = [
      "(version 1)",
      "(allow default)",
      "(deny file-write*)",
      "(allow file-write*",
    ]
    lines += paths.map { "  (subpath \(quoted($0)))" }
    lines += devices.map { "  (literal \(quoted($0)))" }
    lines.append(#"  (regex #"^/dev/fd/[0-9]+$")"#)
    lines.append(#"  (regex #"^/dev/ttys[0-9]+$"))"#)
    if !permissions.network {
      lines.append(#"(deny network-outbound (remote ip "*:*"))"#)
      lines.append(#"(deny network-inbound (local ip "*:*"))"#)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  static func expand(_ path: String, home: String) -> String {
    var expanded = path
    if expanded == "~" {
      expanded = home
    } else if expanded.hasPrefix("~/") {
      expanded = home + expanded.dropFirst()
    }
    while expanded.count > 1, expanded.hasSuffix("/") { expanded.removeLast() }
    return expanded
  }

  static func variants(_ path: String) -> [String] {
    for root in ["/tmp", "/var", "/etc"] where path == root || path.hasPrefix(root + "/") {
      return [path, "/private" + path]
    }
    return [path]
  }

  /// An SBPL string literal.
  static func quoted(_ path: String) -> String {
    "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
