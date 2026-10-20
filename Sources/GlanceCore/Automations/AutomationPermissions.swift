import CryptoKit
import Foundation

extension AutomationPermissions {
  /// Whether a step's Claude tool pattern is allowed: listed as is, or its tool is listed bare ("Bash" allows
  /// "Bash(git:*)").
  public func allows(tool: String) -> Bool {
    tools.contains(tool) || tool.firstIndex(of: "(").map { tools.contains(String(tool[..<$0])) } == true
  }

  /// Whether a step's MCP tool is allowed: listed as is, or its whole server is ("mcp__slack" allows
  /// "mcp__slack__post").
  public func allows(mcp tool: String) -> Bool {
    mcp.contains(tool) || mcp.contains { tool.hasPrefix($0 + "__") }
  }

  /// Every Claude step's `tools` and `mcp` the permissions don't cover: "steps[1].tools: `Write` isn't in
  /// permissions.tools".
  public func problems(in manifest: AutomationManifest) -> [AutomationProblem] {
    var problems: [AutomationProblem] = []
    for (index, step) in manifest.steps.enumerated() {
      for tool in step.tools ?? [] where !allows(tool: tool) {
        problems.append(AutomationProblem("steps[\(index)].tools", "`\(tool)` isn't in permissions.tools"))
      }
      for tool in step.mcp ?? [] where !allows(mcp: tool) {
        problems.append(AutomationProblem("steps[\(index)].mcp", "`\(tool)` isn't in permissions.mcp"))
      }
    }
    return problems
  }
}

/// What the user approves (spec "Approvals"): a version's permissions and triggers, recorded as a hash.
public enum AutomationApproval {
  /// SHA-256 (hex) of permissions + triggers as sorted-key JSON: equal exactly when neither changed. The permission
  /// lists are sets, so their order doesn't count. If the manifest can't be encoded (a NaN input), the result is a
  /// fresh value that never equals a stored hash: nothing is ever approved by it.
  public static func hash(_ manifest: AutomationManifest) -> String {
    struct Approved: Encodable {
      var permissions: AutomationPermissions
      var triggers: [AutomationTrigger]
    }
    var permissions = manifest.permissions
    permissions.commands.sort()
    permissions.tools.sort()
    permissions.mcp.sort()
    permissions.folders.sort()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(Approved(permissions: permissions, triggers: manifest.triggers)) else {
      return "unhashable-" + UUID().uuidString
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// A save keeps its approval when permissions and triggers are unchanged and every step stays inside them.
  public static func keeps(approvedHash: String, _ manifest: AutomationManifest) -> Bool {
    hash(manifest) == approvedHash && manifest.permissions.problems(in: manifest).isEmpty
  }

  /// The Setup page's diff against the approved version, one plain line each: "Adds command `jq`", "Turns network
  /// on", "Removes trigger schedule 0 9 * * 1-5".
  public static func changes(from old: AutomationManifest, to new: AutomationManifest) -> [String] {
    var lines: [String] = []
    let lists: [(String, [String], [String])] = [
      ("command", old.permissions.commands, new.permissions.commands),
      ("tool", old.permissions.tools, new.permissions.tools),
      ("MCP tool", old.permissions.mcp, new.permissions.mcp),
      ("folder", old.permissions.folders, new.permissions.folders),
    ]
    for (label, before, after) in lists {
      lines += after.filter { !before.contains($0) }.map { "Adds \(label) `\($0)`" }
      lines += before.filter { !after.contains($0) }.map { "Removes \(label) `\($0)`" }
    }
    if old.permissions.network != new.permissions.network {
      lines.append(new.permissions.network ? "Turns network on" : "Turns network off")
    }
    let before = old.triggers.map(\.summary), after = new.triggers.map(\.summary)
    lines += after.filter { !before.contains($0) }.map { "Adds trigger \($0)" }
    lines += before.filter { !after.contains($0) }.map { "Removes trigger \($0)" }
    // A trigger that stays (same summary) but runs with other inputs or another filter.
    let kept = Set(before).intersection(after)
    let retargeted = kept.contains { summary in
      old.triggers.filter { $0.summary == summary } != new.triggers.filter { $0.summary == summary }
    }
    if retargeted { lines.append("Changes a trigger's inputs or filter") }
    return lines
  }
}
