import Foundation

/// The editor's branch picker (its status bar's branch chip, as in VS Code): the project's branches, and switching to
/// one, to a new one, or to a remote one (a local branch tracking it). git runs in the project's folder.
public enum GitBranches {
  public struct List: Equatable, Sendable {
    public var current: String?
    /// Local branches, most recently committed first.
    public var local: [String]
    /// Remote branches (`origin/x`) with no local branch of the same name, most recently committed first.
    public var remote: [String]
  }

  /// Most recently committed first, so the branches in use come up top.
  static let localArguments = ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"]
  static let remoteArguments = ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/remotes"]
  static let currentArguments = ["symbolic-ref", "--short", "-q", "HEAD"]

  /// The list from git's three outputs. A remote's HEAD (`origin/HEAD`, or the bare `origin` short form) is left out,
  /// and so is a remote branch already checked out locally under its own name.
  static func list(current: String?, local: String, remote: String) -> List {
    let locals = lines(local)
    let localNames = Set(locals)
    let remotes = lines(remote).filter { ref in
      guard let slash = ref.firstIndex(of: "/") else { return false }
      let name = String(ref[ref.index(after: slash)...])
      return name != "HEAD" && !localNames.contains(name)
    }
    let head = current?.trimmingCharacters(in: .whitespacesAndNewlines)
    return List(current: head?.isEmpty == false ? head : nil, local: locals, remote: remotes)
  }

  /// What `git switch` is run with: an existing local branch by name; a remote one by its name after the remote
  /// (git makes a local branch tracking it); a new one with `-c`.
  public static func switchArguments(to branch: String, create: Bool, remote: Bool) -> [String] {
    if create { return ["switch", "-c", branch] }
    if remote, let slash = branch.firstIndex(of: "/") { return ["switch", String(branch[branch.index(after: slash)...])] }
    return ["switch", branch]
  }

  /// The project's branches; nil outside a git repository.
  public static func list(root: String) -> List? {
    guard let local = git(root, localArguments), local.status == 0,
          let remote = git(root, remoteArguments) else { return nil }
    let current = git(root, currentArguments)
    return list(current: current?.status == 0 ? current?.output : nil, local: local.output, remote: remote.output)
  }

  /// Switches the project's checkout; nil when it did, else git's own message (local changes in the way, a bad name).
  public static func switchBranch(root: String, to branch: String, create: Bool, remote: Bool) -> String? {
    guard let run = git(root, switchArguments(to: branch, create: create, remote: remote)) else { return "git couldn't be run" }
    if run.status == 0 { return nil }
    let message = run.error.trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? "git switch failed" : message
  }

  private static func lines(_ text: String) -> [String] {
    text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  private static func git(_ root: String, _ arguments: [String]) -> (status: Int32, output: String, error: String)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root] + arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    // Read both before waiting, so a full pipe can't stall git.
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let error = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: error, as: UTF8.self))
  }
}
