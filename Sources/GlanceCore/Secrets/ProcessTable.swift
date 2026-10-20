import Darwin
import Foundation

/// What the kernel says about a process: its parent and its working directory. Studio uses it to learn a Claude
/// session's real folder instead of the one its shim claims (spec "Request flow", step 2).
///
/// Both lookups can race pid reuse: the pid may name a different process by the time it is read. Treat a parent pid of
/// 0 or 1 as "no parent".
public enum ProcessTable {
  public static func parent(of pid: pid_t) -> pid_t? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
  }

  /// The working directory, or nil when the process is gone or its directory can't be read (an empty path).
  public static func cwd(of pid: pid_t) -> String? {
    guard pid > 0 else { return nil }
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafePointer(to: info.pvi_cdir.vip_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return path.isEmpty ? nil : path
  }
}
