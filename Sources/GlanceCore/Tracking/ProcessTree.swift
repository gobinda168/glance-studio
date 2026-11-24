import Darwin
import Foundation

/// Parent processes and process names, from the kernel (no `ps`): how a hook and `glance changes --mine` find the
/// `claude` process they run under.
public enum ProcessTree {
  static func info(_ pid: Int32) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
  }

  public static func parent(of pid: Int32) -> Int32? {
    guard let parent = info(pid)?.kp_eproc.e_ppid, parent > 0 else { return nil }
    return parent
  }

  /// The process's short name (`p_comm`, e.g. "claude"), not its executable's file name.
  public static func name(of pid: Int32) -> String? {
    guard var info = info(pid) else { return nil }
    return withUnsafePointer(to: &info.kp_proc.p_comm) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
    }
  }

  /// The nearest ancestor of `pid` named `named`, within twelve steps.
  public static func ancestor(of pid: Int32, named: String) -> Int32? {
    ancestor(of: pid, names: [named])
  }

  /// The nearest ancestor of `pid` whose name is any of `names`, within twelve steps.
  public static func ancestor(of pid: Int32, names: Set<String>) -> Int32? {
    var current = pid
    for _ in 0..<12 {
      guard let parent = parent(of: current) else { return nil }
      if let name = name(of: parent), names.contains(name) { return parent }
      current = parent
    }
    return nil
  }

  /// The Claude Code process `pid` runs under. Its short name is "claude", but the npm install's binary is
  /// `claude.exe`, so that name counts too.
  public static func claudeAncestor(of pid: Int32) -> Int32? {
    ancestor(of: pid, names: claudeNames)
  }

  static let claudeNames: Set<String> = ["claude", "claude.exe"]

  /// Whether `pid` is a running Claude Code process: how a session counts as live. A pid the system reused for
  /// another program doesn't count.
  public static func isClaude(_ pid: Int32) -> Bool {
    guard pid > 0, isAlive(pid), let name = name(of: pid) else { return false }
    return claudeNames.contains(name)
  }

  public static func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }
}
