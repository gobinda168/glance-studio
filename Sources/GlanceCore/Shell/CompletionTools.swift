import Foundation

/// Installed tools that can print their own zsh completion (spec "S1: the Tab menu", "Coverage"): Studio runs each
/// once per tool version and keeps the script in Glance's caches, which the zsh plugin adds to `fpath`.
public enum CompletionTools {
  public struct Tool: Equatable, Sendable {
    /// The command the completion is for.
    public let command: String
    /// The program to run (usually the command itself) and its arguments.
    public let program: String
    public let arguments: [String]

    public init(_ command: String, _ arguments: [String], program: String? = nil) {
      self.command = command
      self.program = program ?? command
      self.arguments = arguments
    }
  }

  public static let tools: [Tool] = [
    Tool("pnpm", ["completion", "zsh"]),
    Tool("kubectl", ["completion", "zsh"]),
    Tool("helm", ["completion", "zsh"]),
    Tool("docker", ["completion", "zsh"]),
    Tool("deno", ["completions", "zsh"]),
    Tool("uv", ["generate-shell-completion", "zsh"]),
    Tool("rustup", ["completions", "zsh"]),
    Tool("cargo", ["completions", "zsh", "cargo"], program: "rustup"),
    Tool("poetry", ["completions", "zsh"]),
  ]

  /// `program`'s executable on `path` (a `$PATH` value): the first folder that has it. Nil for a name with a slash.
  public static func locate(_ program: String, path: String, isExecutable: (String) -> Bool) -> String? {
    guard !program.isEmpty, !program.contains("/") else { return nil }
    for folder in path.split(separator: ":", omittingEmptySubsequences: true) where folder.hasPrefix("/") {
      let candidate = folder.hasSuffix("/") ? "\(folder)\(program)" : "\(folder)/\(program)"
      if isExecutable(candidate) { return candidate }
    }
    return nil
  }

  /// A tool executable's identity (path, size, modification time): the script is made again only when it changes.
  public static func stamp(path: String, size: Int64, modified: Date) -> String {
    "\(path)|\(size)|\(Int64(modified.timeIntervalSince1970 * 1000))"
  }

  /// Output that is a zsh completion (`#compdef` first), not an error message or a usage text.
  public static func isCompletionScript(_ text: String) -> Bool {
    text.hasPrefix("#compdef ")
  }

  /// `_<command>` when zsh can autoload the script from `fpath` (it defines `_<command>`), else `<command>.zsh`, a
  /// script that registers itself and has to be sourced (tabtab's, pnpm's).
  public static func fileName(for command: String, script: String) -> String {
    let name = "_\(command)"
    let defines = script.split(separator: "\n").contains { line in
      let text = line.trimmingCharacters(in: .whitespaces)
      return text.hasPrefix("\(name)()") || text.hasPrefix("\(name) ()") || text.hasPrefix("function \(name)")
    }
    return defines ? name : "\(command).zsh"
  }
}
