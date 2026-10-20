import Foundation

/// How a secret goes into a request: the one header it fills (spec "Secret record"). Never a URL or a body.
public enum SecretSlot: Codable, Equatable, Hashable, Sendable {
  case bearer
  case header(name: String, prefix: String)
  case basic(username: String)

  public func header(value: String) -> (name: String, value: String) {
    switch self {
    case .bearer: ("Authorization", "Bearer " + value)
    case .header(let name, let prefix): (name, prefix + value)
    case .basic(let username): ("Authorization", "Basic " + Data("\(username):\(value)".utf8).base64EncodedString())
    }
  }

  public var headerName: String {
    switch self {
    case .bearer, .basic: "Authorization"
    case .header(let name, _): name
    }
  }

  /// What `secrets_list` tells Claude.
  public var summary: String {
    switch self {
    case .bearer: "bearer"
    case .header(let name, _): "header \(name)"
    case .basic: "basic"
    }
  }
}

public enum SecretApproval: String, Codable, CaseIterable, Sendable {
  case everyTime, oncePerSession, always
}

/// One secret: the value and every rule, kept together in the sealed vault (spec "Storage").
public struct SecretRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var note: String
  public var value: String
  public var hosts: [String]
  public var slot: SecretSlot
  /// Empty: any folder.
  public var folders: [String]
  public var approval: SecretApproval
  public var created: Date
  public var updated: Date

  public static let minimumValueLength = 8
  /// Caps on the lists, so what a save changes always fits the Touch ID sheet (`SecretDraft.changeReason`).
  public static let maximumHosts = 20
  public static let maximumFolders = 20
  static let forbiddenHeaders: Set<String> = ["host", "content-length", "transfer-encoding", "connection"]

  public init(id: UUID, name: String, note: String, value: String, hosts: [String], slot: SecretSlot,
              folders: [String], approval: SecretApproval, created: Date, updated: Date) {
    self.id = id
    self.name = name
    self.note = note
    self.value = value
    self.hosts = hosts
    self.slot = slot
    self.folders = folders
    self.approval = approval
    self.created = created
    self.updated = updated
  }

  public static func validName(_ name: String) -> Bool {
    guard let first = name.first, first.isASCII, first.isUppercase, name.count <= 64 else { return false }
    return name.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
  }

  static func isToken(_ text: String) -> Bool {
    !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }
  }

  /// True for anything that could end or split a header line: every control scalar except HTAB (C0, DEL, NEL, LS, PS).
  /// Scans unicode scalars, not Characters: Swift folds "\r\n" into one Character that equals neither "\r" nor "\n".
  static func hasLineBreak(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F || scalar.value == 0x85
        || scalar.value == 0x2028 || scalar.value == 0x2029
    }
  }

  /// A fence is a non-empty absolute path (after standardizing).
  static func isUsableFolder(_ folder: String) -> Bool {
    (folder as NSString).standardizingPath.hasPrefix("/")
  }

  /// What stops a save, as sentences for the sheet; empty when it can be saved.
  public func problems(otherNames: Set<String>) -> [String] {
    var problems: [String] = []
    if !Self.validName(name) {
      problems.append("The name must be capital letters, digits and _, starting with a letter (like GITHUB_TOKEN).")
    } else if otherNames.contains(name) {
      problems.append("Another secret is already called \(name).")
    }
    if Self.hasLineBreak(value) { problems.append("The value can't contain line breaks.") }
    else if value.count < Self.minimumValueLength { problems.append("The value must be at least 8 characters.") }
    if hosts.isEmpty { problems.append("Add at least one host it may be sent to.") }
    if hosts.count > Self.maximumHosts { problems.append("A secret can have at most \(Self.maximumHosts) hosts.") }
    problems += hosts.compactMap(SecretHostRule.problem(pattern:))
    if folders.count > Self.maximumFolders {
      problems.append("A secret can have at most \(Self.maximumFolders) folders.")
    }
    for folder in folders where !Self.isUsableFolder(folder) {
      problems.append("\"\(folder)\": a folder must be an absolute path, like /Users/me/Code/acme.")
    }
    switch slot {
    case .bearer: break
    case .header(let name, let prefix):
      if !Self.isToken(name) || Self.forbiddenHeaders.contains(name.lowercased()) {
        problems.append("\"\(name)\" can't be the header name.")
      }
      if Self.hasLineBreak(prefix) { problems.append("The header prefix can't contain line breaks.") }
    case .basic(let username):
      if username.unicodeScalars.contains(":") || Self.hasLineBreak(username) {
        problems.append("The username can't contain : or line breaks.")
      }
    }
    return problems
  }

  /// A session in `folder` (nil when Studio couldn't verify it) may use this secret.
  public func allows(folder: String?) -> Bool {
    guard !folders.isEmpty else { return true }
    guard let folder else { return false }
    let path = (folder as NSString).standardizingPath
    return folders.contains { fence in
      guard Self.isUsableFolder(fence) else { return false }
      let fence = (fence as NSString).standardizingPath
      return path == fence || path.hasPrefix(fence + "/")
    }
  }
}
