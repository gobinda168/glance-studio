import Foundation

/// One automation's row in approvals.json (spec 2026-10-09-automations-design.md, "The package format" and
/// "Approvals"): what the user approved, whether outward steps run without asking, and the enabled switch. It lives
/// outside git: it is the user's say, not part of the package.
public struct AutomationApprovalRecord: Codable, Equatable, Sendable {
  public var approvedVersion: Int?
  /// `AutomationApproval.hash` of the approved permissions and triggers.
  public var approvedPermissionsHash: String?
  /// automation.json's text when it was approved: what the Setup page's diff compares against.
  public var approvedManifest: String?
  /// Outward steps run without parking.
  public var trusted: Bool
  /// Off disarms the triggers; a manual run still works.
  public var enabled: Bool

  public init(approvedVersion: Int? = nil, approvedPermissionsHash: String? = nil, approvedManifest: String? = nil,
              trusted: Bool = false, enabled: Bool = true) {
    self.approvedVersion = approvedVersion
    self.approvedPermissionsHash = approvedPermissionsHash
    self.approvedManifest = approvedManifest
    self.trusted = trusted
    self.enabled = enabled
  }

  enum CodingKeys: String, CodingKey {
    case approvedVersion, approvedPermissionsHash, approvedManifest, trusted, enabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    approvedVersion = try container.decodeIfPresent(Int.self, forKey: .approvedVersion)
    approvedPermissionsHash = try container.decodeIfPresent(String.self, forKey: .approvedPermissionsHash)
    approvedManifest = try container.decodeIfPresent(String.self, forKey: .approvedManifest)
    trusted = try container.decodeIfPresent(Bool.self, forKey: .trusted) ?? false
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
  }
}

/// Where an automation stands with the user's approval.
public enum AutomationApprovalStatus: Equatable, Sendable {
  case approved
  /// Approved before; this version changed its permissions or triggers. The lines say what changed.
  case changed([String])
  /// Never approved.
  case never

  public var isApproved: Bool { self == .approved }
}

/// approvals.json: automation id → its record. Pure; `AutomationLibrary` reads and writes the file.
public struct AutomationApprovalBook: Codable, Equatable, Sendable {
  public static let fileName = "approvals.json"

  public private(set) var records: [String: AutomationApprovalRecord]

  public init(records: [String: AutomationApprovalRecord] = [:]) {
    self.records = records
  }

  public init(from decoder: Decoder) throws {
    records = try decoder.singleValueContainer().decode([String: AutomationApprovalRecord].self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(records)
  }

  /// nil when the file isn't a valid approvals.json (the library moves it to `.bak` and starts over: everything
  /// unapproved, triggers disarmed).
  public static func decode(_ data: Data) -> AutomationApprovalBook? {
    try? JSONDecoder().decode(AutomationApprovalBook.self, from: data)
  }

  /// Pretty, sorted keys: a stable file.
  public func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)) ?? Data("{}".utf8)
  }

  /// The automation's record; a fresh one (unapproved, untrusted, enabled) when it has none.
  public func record(_ id: String) -> AutomationApprovalRecord { records[id] ?? AutomationApprovalRecord() }

  /// Approved while the permissions and triggers hash the same and every step stays inside them
  /// (`AutomationApproval.keeps`). Otherwise the lines for the Setup page and Needs you: the A0 diff against the
  /// approved manifest, or "Changes its triggers" when that diff is empty (a reorder, or a second copy of a trigger
  /// whose one-line summary is the same, changes the hash without a line of its own).
  public func status(of manifest: AutomationManifest) -> AutomationApprovalStatus {
    let record = record(manifest.id)
    guard let hash = record.approvedPermissionsHash else { return .never }
    if AutomationApproval.keeps(approvedHash: hash, manifest) { return .approved }
    guard let text = record.approvedManifest, let old = AutomationManifest.parse(Data(text.utf8)).manifest else {
      return .changed(["Changes its permissions or triggers"])
    }
    let lines = AutomationApproval.changes(from: old, to: manifest)
    return .changed(lines.isEmpty ? ["Changes its triggers"] : lines)
  }

  /// The user approved this version. `manifestText` is automation.json as it is on disk. Approving different
  /// permissions or triggers than before drops trust (it was given for what the user saw then); approving the same
  /// ones again keeps it.
  public mutating func approve(_ manifest: AutomationManifest, manifestText: String) {
    var record = record(manifest.id)
    let hash = AutomationApproval.hash(manifest)
    if record.approvedPermissionsHash != hash { record.trusted = false }
    record.approvedVersion = manifest.version
    record.approvedPermissionsHash = hash
    record.approvedManifest = manifestText
    records[manifest.id] = record
  }

  public mutating func setTrusted(_ id: String, _ on: Bool) {
    var record = record(id)
    record.trusted = on
    records[id] = record
  }

  public mutating func setEnabled(_ id: String, _ on: Bool) {
    var record = record(id)
    record.enabled = on
    records[id] = record
  }

  /// A deleted automation's row goes with it; restoring it from History starts unapproved.
  public mutating func remove(_ id: String) {
    records[id] = nil
  }

  /// Its triggers are armed: enabled, valid (no problems) and approved.
  public func isArmed(_ manifest: AutomationManifest, problems: [AutomationProblem]) -> Bool {
    problems.isEmpty && record(manifest.id).enabled && status(of: manifest).isApproved
  }
}

extension AutomationApproval {
  /// What approving lets the automation do, one plain line each, for the Setup page and the CLI. The sandbox only
  /// stops file writes and direct internet connections, so the words say exactly that: "No direct internet access",
  /// "File writes limited to …" (never "no network" or "sandboxed").
  public static func summary(_ manifest: AutomationManifest) -> [String] {
    var lines: [String] = []
    let quoted = { (items: [String]) in items.map { "`\($0)`" }.joined(separator: ", ") }
    let permissions = manifest.permissions
    if !permissions.commands.isEmpty { lines.append("Runs commands \(quoted(permissions.commands))") }
    if !permissions.tools.isEmpty { lines.append("Claude may use \(quoted(permissions.tools))") }
    if !permissions.mcp.isEmpty { lines.append("Claude may use MCP tools \(quoted(permissions.mcp))") }
    let places = ["its run folder", "Glance's automation state", "temporary folders"]
      + permissions.folders.map { "`\($0)`" }
    lines.append("File writes limited to " + list(places))
    lines.append(permissions.network ? "Direct internet access" : "No direct internet access")
    let triggers = manifest.triggers.filter { $0.typed != .manual }.map(\.summary)
    lines.append(triggers.isEmpty ? "Starts only when you run it" : "Starts on " + triggers.joined(separator: "; "))
    let outward = manifest.steps.filter(\.isOutward).map { "`\($0.id)`" }
    if !outward.isEmpty { lines.append("Asks before running " + list(outward)) }
    return lines
  }

  /// "a", "a and b", "a, b and c".
  static func list(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + items.last!
  }
}
