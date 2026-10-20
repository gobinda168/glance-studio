import Foundation

/// A package as `glance automation check` read it from disk.
public struct AutomationPackage: Equatable, Sendable {
  public var folderName: String
  /// Its absolute path (`{{automation.dir}}`).
  public var directory: String
  /// automation.json's bytes.
  public var manifest: Data
  /// Every other file, path relative to the package → its text ("" when it isn't UTF-8).
  public var files: [String: String]

  public init(folderName: String, directory: String, manifest: Data, files: [String: String]) {
    self.folderName = folderName
    self.directory = directory
    self.manifest = manifest
    self.files = files
  }
}

/// A script `check` asks the shell to parse (`<shell> -n -c <script>`).
public struct AutomationShellCheck: Equatable, Sendable {
  /// Where a problem points: "steps/fetch.sh" or "steps[2].run".
  public var location: String
  public var script: String
  /// /bin/zsh, or /bin/bash or /bin/sh when the script's #! line names them.
  public var shell: String
}

public struct AutomationCheckResult: Equatable, Sendable {
  public var problems: [AutomationProblem]
  /// nil when validation found problems (the dry run would repeat them).
  public var dryRun: AutomationDryRun?
  /// What the CLI parses with the shell next; their problems join `problems`.
  public var shellChecks: [AutomationShellCheck]
}

/// `glance automation check <id|path>` (spec "Claude: skill + Glance MCP") without the disk and the shell: validate,
/// check line endings and inputs, dry-run the pipeline, and list the shell scripts to parse.
public enum AutomationCheck {
  /// `library`: the other automations in the package's folder, id → the ids they call. `inputs`: `--inputs`.
  public static func run(_ package: AutomationPackage, library: [String: Set<String>],
                         inputs: [String: AutomationValue]) -> AutomationCheckResult {
    var others = library
    others[package.folderName] = nil
    let parsed = AutomationManifest.parse(package.manifest)
    let promptPaths = Set(parsed.manifest?.steps.compactMap(\.claude) ?? [])
    let context = AutomationValidationContext(
      folderName: package.folderName, files: Set(package.files.keys).union([AutomationManifest.fileName]),
      prompts: package.files.filter { promptPaths.contains($0.key) }, automations: others)
    let checked = AutomationManifest.check(package.manifest, context)
    guard let manifest = checked.manifest else {
      return AutomationCheckResult(problems: checked.problems, dryRun: nil, shellChecks: [])
    }
    let lineEndings = lineEndingProblems(package.files)
    let sampled = manifest.sampleInputs(inputs)
    let problems = checked.problems + lineEndings + sampled.problems
    let crlf = Set(lineEndings.map(\.path))
    var shellChecks = package.files.keys.sorted().filter { isShellFile($0) && !crlf.contains($0) }.map { path in
      AutomationShellCheck(location: path, script: package.files[path]!, shell: shell(for: package.files[path]!))
    }
    guard problems.isEmpty else {
      return AutomationCheckResult(problems: problems, dryRun: nil, shellChecks: shellChecks)
    }
    let dryRun = manifest.dryRun(inputs: sampled.values, prompts: context.prompts,
                                 automationDirectory: package.directory)
    for (index, step) in manifest.steps.enumerated() {
      guard let command = dryRun.steps.first(where: { $0.id == step.id })?.command else { continue }
      shellChecks.append(AutomationShellCheck(location: "steps[\(index)].run", script: command, shell: "/bin/zsh"))
    }
    return AutomationCheckResult(problems: dryRun.problems, dryRun: dryRun, shellChecks: shellChecks)
  }

  static func isShellFile(_ path: String) -> Bool {
    AutomationStep.shellExtensions.contains((path as NSString).pathExtension.lowercased())
  }

  /// The shell a script's #! line asks for (bash or sh); zsh, what steps run under, otherwise.
  static func shell(for script: String) -> String {
    guard script.hasPrefix("#!") else { return "/bin/zsh" }
    let words = script.dropFirst(2).prefix { $0 != "\n" && $0 != "\r" }.split(separator: " ").map(String.init)
    var name = words.first.map { ($0 as NSString).lastPathComponent } ?? ""
    if name == "env", words.count > 1 { name = words[1] }
    switch name {
    case "bash": return "/bin/bash"
    case "sh": return "/bin/sh"
    default: return "/bin/zsh"
    }
  }

  /// Scripts saved with Windows line endings break at run time ("bad interpreter", "then\r"); say so plainly.
  static func lineEndingProblems(_ files: [String: String]) -> [AutomationProblem] {
    files.keys.sorted().filter { path in
      AutomationStep.scriptExtensions.contains((path as NSString).pathExtension.lowercased())
        && files[path]!.contains("\r\n")
    }.map { AutomationProblem($0, "has Windows line endings (CRLF); save it with LF line endings") }
  }

  /// The shell's complaint as a problem: "zsh:2: parse error near `fi'" and "/bin/bash: -c: line 2: syntax error …"
  /// → "line 2: …".
  public static func shellProblem(_ check: AutomationShellCheck, output: String) -> AutomationProblem {
    let first = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    if let match = first.firstMatch(of: /^\S+?:(?: -c:)? ?(?:line )?(\d+): (.+)$/) {
      return AutomationProblem(check.location, "line \(match.1): \(match.2)")
    }
    let message = first.drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
    return AutomationProblem(check.location, message.isEmpty ? "the shell couldn't parse it" : message)
  }

  /// What the command prints: "ok", or one problem per line.
  public static func report(_ problems: [AutomationProblem]) -> String {
    problems.isEmpty ? "ok" : problems.map(\.description).joined(separator: "\n")
  }
}
