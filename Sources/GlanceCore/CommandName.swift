import Darwin
import Foundation

/// A running process's executable and arguments, read with `sysctl(KERN_PROCARGS2)`.
public enum ProcessArguments {
  public static func parse(_ data: Data) -> (executable: String, arguments: [String])? {
    guard data.count > 4 else { return nil }
    let argc = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
    guard argc >= 0 else { return nil }
    let bytes = [UInt8](data)

    func string(at start: Int) -> (value: String, next: Int)? {
      guard start < bytes.count else { return nil }
      var end = start
      while end < bytes.count, bytes[end] != 0 { end += 1 }
      return (String(decoding: bytes[start..<end], as: UTF8.self), end + 1)
    }

    guard let executable = string(at: 4) else { return nil }
    var index = executable.next
    while index < bytes.count, bytes[index] == 0 { index += 1 }
    var arguments: [String] = []
    while arguments.count < argc, let argument = string(at: index) {
      arguments.append(argument.value)
      index = argument.next
    }
    return (executable.value, arguments)
  }

  public static func read(pid: Int) -> (executable: String, arguments: [String])? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(truncatingIfNeeded: pid)]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
    return parse(Data(buffer.prefix(size)))
  }
}

/// The sidebar's "running command" chip.
public enum CommandName {
  private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish"]

  public static func chip(
    executable: String,
    arguments: [String],
    loginShell: String? = ProcessInfo.processInfo.environment["SHELL"],
    limit: Int = 28
  ) -> String? {
    let program = name(of: arguments.first ?? executable)
    if shells.contains(program) { return nil }
    if let loginShell, name(of: loginShell) == program { return nil }
    let shown = [program] + ChannelLaunch.hidingFlag(arguments: Array(arguments.dropFirst())).map { $0.hasPrefix("/") ? (($0 as NSString).lastPathComponent) : $0 }
    let text = shown.joined(separator: " ")
    return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
  }

  /// A program's name; a login shell's argv[0] carries a leading "-" (`-zsh`).
  private static func name(of path: String) -> String {
    let base = (path as NSString).lastPathComponent
    return base.hasPrefix("-") ? String(base.dropFirst()) : base
  }
}
