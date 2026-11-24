import Foundation

/// A project's proof setup, `.glance/proof.json` at its repository root (spec §3 "The project setup"). Written by the
/// user's own Claude (the glance-proof-setup skill); Glance only reads and validates it.
public struct ProofSetup: Codable, Equatable, Sendable {
  public struct Environment: Codable, Equatable, Sendable {
    public var name: String
    public var url: String?
    /// A script (relative to the root) that prints the URL; `gh-deployments` reads the PR's deployments instead.
    public var urlScript: String?
    public var match: [String]

    public init(name: String, url: String? = nil, urlScript: String? = nil, match: [String] = []) {
      self.name = name; self.url = url; self.urlScript = urlScript; self.match = match
    }
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      name = try c.decode(String.self, forKey: .name)
      url = try c.decodeIfPresent(String.self, forKey: .url)
      urlScript = try c.decodeIfPresent(String.self, forKey: .urlScript)
      match = try c.decodeIfPresent([String].self, forKey: .match) ?? []
    }
  }

  public struct Check: Codable, Equatable, Sendable {
    public var name: String
    /// A regular expression over the Bash command line.
    public var match: String
    public var env: String?
    /// An environment variable or flag in the command whose value is a URL, classified through the environments.
    public var envFrom: String?

    public init(name: String, match: String, env: String? = nil, envFrom: String? = nil) {
      self.name = name; self.match = match; self.env = env; self.envFrom = envFrom
    }
  }

  public struct Explainer: Codable, Equatable, Sendable {
    public var command: String?
  }

  public var version: Int
  public var environments: [Environment]
  public var checks: [Check]
  /// "Check@Environment" pairs that must pass for Ready.
  public var required: [String]
  public var sections: [String]
  /// Extra asset globs (stage 3 uses them).
  public var assets: [String]
  public var explainer: Explainer?

  public init(version: Int = 1, environments: [Environment] = [], checks: [Check] = [], required: [String] = [],
              sections: [String] = [], assets: [String] = [], explainer: Explainer? = nil) {
    self.version = version; self.environments = environments; self.checks = checks; self.required = required
    self.sections = sections; self.assets = assets; self.explainer = explainer
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decode(Int.self, forKey: .version)
    environments = try c.decodeIfPresent([Environment].self, forKey: .environments) ?? []
    checks = try c.decodeIfPresent([Check].self, forKey: .checks) ?? []
    required = try c.decodeIfPresent([String].self, forKey: .required) ?? []
    sections = try c.decodeIfPresent([String].self, forKey: .sections) ?? []
    assets = try c.decodeIfPresent([String].self, forKey: .assets) ?? []
    explainer = try c.decodeIfPresent(Explainer.self, forKey: .explainer)
  }

  /// "Unit@Local" → ("Unit", "Local"); nil without exactly one "@".
  public static func requirement(_ text: String) -> (check: String, environment: String)? {
    let parts = text.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return (parts[0], parts[1])
  }
}

/// One problem with a setup file: what's wrong, in a sentence Claude can act on, and the line it's on.
public struct ProofSetupIssue: Equatable, Sendable {
  public var line: Int?
  public var message: String
  /// The offending line's text.
  public var excerpt: String?

  public init(line: Int?, message: String, excerpt: String?) {
    self.line = line; self.message = message; self.excerpt = excerpt
  }
}

public enum ProofSetupLoad: Equatable, Sendable {
  case missing
  case invalid(issues: [ProofSetupIssue], root: String)
  case valid(ProofSetup, root: String)

  public var setup: ProofSetup? { if case .valid(let s, _) = self { return s }; return nil }
  public var root: String? {
    switch self {
    case .missing: nil
    case .invalid(_, let root), .valid(_, let root): root
    }
  }
}

public enum ProofSetupFile {
  public static let relativePath = ".glance/proof.json"

  /// The nearest folder at or above `cwd` with a setup file. The walk stops at the repository root (a folder holding
  /// `.git`) and at `/`. In a linked worktree with no setup file of its own (an untracked `proof.json` only exists
  /// in the main worktree), the main worktree is checked next and, if it has one, is the root.
  public static func root(from cwd: String) -> String? {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: cwd).standardizedFileURL
    while true {
      if fm.fileExists(atPath: dir.appendingPathComponent(relativePath).path) { return dir.path }
      if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
        guard let main = mainWorktree(ofLinked: dir), main.path != dir.path,
              fm.fileExists(atPath: main.appendingPathComponent(relativePath).path) else { return nil }
        return main.path
      }
      if dir.path == "/" { return nil }
      dir = dir.deletingLastPathComponent()
    }
  }

  /// The main worktree of a linked worktree at `dir`: its `.git` is a file `gitdir: <repo>/.git/worktrees/<name>`, and
  /// that folder's `commondir` points back at `<repo>/.git`. Nil for a main worktree (`.git` is a folder) or anything
  /// unreadable.
  private static func mainWorktree(ofLinked dir: URL) -> URL? {
    guard let found = GitCommonDir.of(root: dir), found.linked, found.commonDir.lastPathComponent == ".git" else { return nil }
    return found.commonDir.deletingLastPathComponent()
  }

  public static func load(cwd: String) -> ProofSetupLoad {
    guard let root = root(from: cwd),
          let text = try? String(contentsOfFile: root + "/" + relativePath, encoding: .utf8) else { return .missing }
    return parse(text, root: root)
  }

  public static func parse(_ text: String, root: String) -> ProofSetupLoad {
    let lines = text.components(separatedBy: "\n")
    let data = Data(text.utf8)
    let raw: Any
    do {
      raw = try JSONSerialization.jsonObject(with: data)
    } catch let error as NSError {
      let offset = (error.userInfo["NSJSONSerializationErrorIndex"] as? Int) ?? 0
      let prefix = text.utf8.prefix(offset)
      let line = prefix.reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
      let lineText = lines.indices.contains(line - 1) ? lines[line - 1].trimmingCharacters(in: .whitespaces) : nil
      return .invalid(issues: [ProofSetupIssue(line: line, message: "proof.json isn't valid JSON.", excerpt: lineText)],
                      root: root)
    }
    // Lines come from the JSON's structure (a path like checks[1].env), never from searching the text, so repeated
    // names, compact formatting and nested values all land on the right line.
    let locator = JSONLineLocator(text)
    func issue(_ message: String, at path: [JSONStep]) -> ProofSetupIssue {
      let line = locator.line(of: path)
      return ProofSetupIssue(line: line, message: message,
                             excerpt: line.flatMap { lines.indices.contains($0 - 1) ? lines[$0 - 1].trimmingCharacters(in: .whitespaces) : nil })
    }
    func entry(_ section: String, _ index: Int, _ key: String? = nil) -> [JSONStep] {
      [.key(section), .index(index)] + (key.map { [.key($0)] } ?? [])
    }
    if let object = raw as? [String: Any], (object["version"] as? Int) != 1 {
      return .invalid(issues: [issue("version must be 1.", at: [.key("version")])], root: root)
    }
    let setup: ProofSetup
    do {
      setup = try JSONDecoder().decode(ProofSetup.self, from: data)
    } catch let DecodingError.keyNotFound(key, context) {
      let owner = JSONStep.path(context.codingPath)
      return .invalid(issues: [issue("\(JSONStep.describe(owner, in: raw)) needs \"\(key.stringValue)\".", at: owner)], root: root)
    } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
      let path = JSONStep.path(context.codingPath)
      return .invalid(issues: [issue("\(JSONStep.describe(path, in: raw)) has the wrong type.", at: path)], root: root)
    } catch {
      return .invalid(issues: [issue("proof.json couldn't be read.", at: [])], root: root)
    }
    var issues: [ProofSetupIssue] = []
    let envNames = setup.environments.map(\.name)
    for (i, env) in setup.environments.enumerated() {
      if env.name.trimmingCharacters(in: .whitespaces).isEmpty {
        issues.append(issue("environment \(i + 1) needs a name.", at: entry("environments", i, "name")))
      } else if envNames[..<i].contains(env.name) {
        issues.append(issue("environment \(env.name) is defined twice.", at: entry("environments", i, "name")))
      }
      if env.url == nil && env.urlScript == nil {
        issues.append(issue("environment \(env.name) needs url or urlScript.", at: entry("environments", i, "name")))
      }
      if let script = env.urlScript, script != "gh-deployments",
         script.hasPrefix("/") || script.split(separator: "/").contains("..") {
        issues.append(issue("environment \(env.name)'s urlScript must be a path inside the repository.",
                            at: entry("environments", i, "urlScript")))
      }
    }
    let checkNames = setup.checks.map(\.name)
    for (i, check) in setup.checks.enumerated() {
      if (try? NSRegularExpression(pattern: check.match)) == nil {
        issues.append(issue("check \(check.name)'s match isn't a valid regular expression.", at: entry("checks", i, "match")))
      }
      if check.env == nil && check.envFrom == nil {
        issues.append(issue("check \(check.name) needs env or envFrom.", at: entry("checks", i, "name")))
      }
      if let env = check.env, !envNames.contains(env) {
        issues.append(issue("check \(check.name) names environment \(env), which isn't defined.", at: entry("checks", i, "env")))
      }
    }
    for (i, requirement) in setup.required.enumerated() {
      let at = [JSONStep.key("required"), .index(i)]
      guard let (check, env) = ProofSetup.requirement(requirement) else {
        issues.append(issue("required \(requirement) must look like Check@Environment.", at: at))
        continue
      }
      if !checkNames.contains(check) {
        issues.append(issue("required \(requirement) names check \(check), which isn't defined.", at: at))
      }
      if !envNames.contains(env) {
        issues.append(issue("required \(requirement) names environment \(env), which isn't defined.", at: at))
      }
    }
    return issues.isEmpty ? .valid(setup, root: root) : .invalid(issues: issues, root: root)
  }
}

/// One step down a JSON document: an object key or an array index.
private enum JSONStep: Hashable {
  case key(String)
  case index(Int)

  /// A decoding error's coding path as steps (array positions carry an `intValue`).
  static func path(_ codingPath: [CodingKey]) -> [JSONStep] {
    codingPath.map { $0.intValue.map(JSONStep.index) ?? .key($0.stringValue) }
  }

  /// A phrase for the value at `path`, naming list entries by their `name` when they have one:
  /// `check "E2E"'s match entry 1`, `environment 2`, `required entry 1`, `proof.json`.
  static func describe(_ path: [JSONStep], in raw: Any) -> String {
    guard let first = path.first else { return "proof.json" }
    var rest = path.dropFirst()
    var text: String
    if case .key(let section) = first, let label = ["environments": "environment", "checks": "check"][section],
       case .index(let i)? = rest.first {
      let node = value(at: Array(path.prefix(2)), in: raw)
      if let name = (node as? [String: Any])?["name"] as? String, !name.isEmpty { text = "\(label) \"\(name)\"" } else { text = "\(label) \(i + 1)" }
      rest = rest.dropFirst()
    } else {
      text = first.phrase
      if case .index = first { text = "entry \(text)" }
      rest = rest.dropFirst()
    }
    for step in rest {
      switch step {
      case .key(let key): text += "'s \(key)"
      case .index(let i): text += " entry \(i + 1)"
      }
    }
    return text
  }

  private var phrase: String {
    switch self {
    case .key(let key): key
    case .index(let i): "\(i + 1)"
    }
  }

  private static func value(at path: [JSONStep], in raw: Any) -> Any? {
    var node: Any? = raw
    for step in path {
      switch step {
      case .key(let key): node = (node as? [String: Any])?[key]
      case .index(let i):
        guard let array = node as? [Any], array.indices.contains(i) else { return nil }
        node = array[i]
      }
    }
    return node
  }
}

/// Maps each position in a JSON document (`checks[1].env`) to the line it starts on: an object member to the line of its
/// key, an array element to the line where it begins. Reads the same text `JSONSerialization` has already accepted, so
/// it doesn't validate; on anything unexpected it just stops.
private struct JSONLineLocator {
  private var lines: [[JSONStep]: Int] = [:]
  private let bytes: [UInt8]
  private var position = 0
  private var line = 1

  init(_ text: String) {
    bytes = Array(text.utf8)
    skipWhitespace()
    lines[[]] = line
    readValue(at: [])
  }

  /// The line of `path`, or of its nearest ancestor that was found (a missing key reports where its owner starts).
  func line(of path: [JSONStep]) -> Int? {
    var path = path
    while true {
      if let found = lines[path] { return found }
      if path.isEmpty { return nil }
      path.removeLast()
    }
  }

  private mutating func skipWhitespace() {
    while position < bytes.count {
      switch bytes[position] {
      case UInt8(ascii: "\n"): line += 1; position += 1
      case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"): position += 1
      default: return
      }
    }
  }

  private mutating func readValue(at path: [JSONStep]) {
    skipWhitespace()
    guard position < bytes.count else { return }
    switch bytes[position] {
    case UInt8(ascii: "{"):
      position += 1
      while true {
        skipWhitespace()
        guard position < bytes.count else { return }
        switch bytes[position] {
        case UInt8(ascii: "}"): position += 1; return
        case UInt8(ascii: ","): position += 1
        case UInt8(ascii: "\""):
          let keyLine = line
          guard let key = readString() else { position = bytes.count; return }
          skipWhitespace()
          guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { position = bytes.count; return }
          position += 1
          lines[path + [.key(key)]] = keyLine
          readValue(at: path + [.key(key)])
        default: position = bytes.count; return
        }
      }
    case UInt8(ascii: "["):
      position += 1
      var index = 0
      while true {
        skipWhitespace()
        guard position < bytes.count else { return }
        switch bytes[position] {
        case UInt8(ascii: "]"): position += 1; return
        case UInt8(ascii: ","): position += 1
        default:
          lines[path + [.index(index)]] = line
          readValue(at: path + [.index(index)])
          index += 1
        }
      }
    case UInt8(ascii: "\""):
      _ = readString()
    default:
      while position < bytes.count, !Self.delimiters.contains(bytes[position]) { position += 1 }
    }
  }

  private static let delimiters = Set(",]} \n\t\r".utf8)

  /// Reads the string starting at the opening quote and returns its decoded value.
  private mutating func readString() -> String? {
    let start = position
    position += 1
    while position < bytes.count {
      switch bytes[position] {
      case UInt8(ascii: "\\"): position += 2
      case UInt8(ascii: "\""):
        position += 1
        let token = Data(bytes[start..<position])
        return (try? JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed)) as? String
      default: position += 1
      }
    }
    return nil
  }
}
