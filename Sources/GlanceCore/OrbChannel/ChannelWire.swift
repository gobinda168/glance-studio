import Foundation

/// The orb channel's own wire (spec "Parts"): one JSON object per line between each `glance mcp` and Studio, over
/// `orb.sock`. The shim says hello once, then forwards tool calls and permission requests; Studio welcomes it and
/// answers calls, pushes the user's messages and sends permission verdicts.
public enum ChannelWire {
  public struct Hello: Equatable, Sendable {
    public var pid: Int32
    /// The `claude` that started the shim.
    public var ppid: Int32
    /// `CLAUDE_PROJECT_DIR`, when Claude Code passes it.
    public var projectDir: String?
    public var cwd: String

    public init(pid: Int32, ppid: Int32, projectDir: String?, cwd: String) {
      self.pid = pid
      self.ppid = ppid
      self.projectDir = projectDir
      self.cwd = cwd
    }
  }

  public struct PermissionRequest: Equatable, Sendable {
    public var requestID: String
    public var tool: String
    public var description: String
    /// The tool's arguments as text (untrusted: shown, never run).
    public var input: String

    public init(requestID: String, tool: String, description: String, input: String) {
      self.requestID = requestID
      self.tool = tool
      self.description = description
      self.input = input
    }
  }

  public enum ToStudio: Equatable, Sendable {
    case hello(Hello)
    case call(callID: String, tool: String, arguments: JSONValue)
    case permissionRequest(PermissionRequest)

    public var line: String {
      let value: JSONValue
      switch self {
      case .hello(let hello):
        value = ["type": "hello", "pid": .number(Double(hello.pid)), "ppid": .number(Double(hello.ppid)),
                 "projectDir": hello.projectDir.map(JSONValue.string) ?? .null, "cwd": .string(hello.cwd)]
      case .call(let callID, let tool, let arguments):
        value = ["type": "call", "callID": .string(callID), "tool": .string(tool), "arguments": arguments]
      case .permissionRequest(let request):
        value = ["type": "permission", "requestID": .string(request.requestID), "tool": .string(request.tool),
                 "description": .string(request.description), "input": .string(request.input)]
      }
      return value.text + "\n"
    }

    public init?(line: String) {
      guard let value = JSONValue.parse(line) else { return nil }
      switch value["type"]?.string {
      case "hello":
        guard let pid = value["pid"]?.int.flatMap({ Int32(exactly: $0) }), pid > 0,
              let ppid = value["ppid"]?.int.flatMap({ Int32(exactly: $0) }), ppid > 0,
              let cwd = value["cwd"]?.string else {
          return nil
        }
        self = .hello(Hello(pid: pid, ppid: ppid, projectDir: value["projectDir"]?.string, cwd: cwd))
      case "call":
        guard let callID = value["callID"]?.string, let tool = value["tool"]?.string else { return nil }
        self = .call(callID: callID, tool: tool, arguments: value["arguments"] ?? [:])
      case "permission":
        guard let id = value["requestID"]?.string, let tool = value["tool"]?.string else { return nil }
        self = .permissionRequest(PermissionRequest(requestID: id, tool: tool,
                                                    description: value["description"]?.string ?? "",
                                                    input: value["input"]?.string ?? ""))
      default:
        return nil
      }
    }
  }

  public enum ToShim: Equatable, Sendable {
    case welcome(assistant: Bool, label: String)
    case result(callID: String, value: JSONValue, isError: Bool)
    case push(content: String, meta: [String: String])
    case verdict(requestID: String, allow: Bool)

    public var line: String {
      let value: JSONValue
      switch self {
      case .welcome(let assistant, let label):
        value = ["type": "welcome", "assistant": .bool(assistant), "label": .string(label)]
      case .result(let callID, let result, let isError):
        value = ["type": "result", "callID": .string(callID), "value": result, "isError": .bool(isError)]
      case .push(let content, let meta):
        value = ["type": "push", "content": .string(content), "meta": .object(meta.mapValues(JSONValue.string))]
      case .verdict(let requestID, let allow):
        value = ["type": "verdict", "requestID": .string(requestID), "allow": .bool(allow)]
      }
      return value.text + "\n"
    }

    public init?(line: String) {
      guard let value = JSONValue.parse(line) else { return nil }
      switch value["type"]?.string {
      case "welcome":
        guard let assistant = value["assistant"]?.bool else { return nil }
        self = .welcome(assistant: assistant, label: value["label"]?.string ?? "")
      case "result":
        guard let callID = value["callID"]?.string, let result = value["value"] else { return nil }
        self = .result(callID: callID, value: result, isError: value["isError"]?.bool ?? false)
      case "push":
        guard let content = value["content"]?.string else { return nil }
        self = .push(content: content, meta: (value["meta"]?.object ?? [:]).compactMapValues(\.string))
      case "verdict":
        guard let id = value["requestID"]?.string, let allow = value["allow"]?.bool else { return nil }
        self = .verdict(requestID: id, allow: allow)
      default:
        return nil
      }
    }
  }
}

/// Where the channel's socket lives.
public enum ChannelPaths {
  public static func socket(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: String = NSHomeDirectory()) -> String {
    if let path = environment["GLANCE_ORB_SOCKET"], !path.isEmpty { return path }
    return home + "/Library/Application Support/Glance/orb.sock"
  }
}

/// How a `claude` gets the channel (spec "Setup and Settings"): the launch flag Studio adds, and how to tell a running
/// `claude` has it.
public enum ChannelLaunch {
  /// Confirmed by the stage 1 spike (Task 0).
  public static let flag = ["--dangerously-load-development-channels", "server:glance"]

  public static func hasChannel(arguments: [String]) -> Bool {
    arguments.contains { argument in
      ["--channels", "--dangerously-load-development-channels"].contains { argument == $0 || argument.hasPrefix($0 + "=") }
    }
  }

  /// The shell line that starts `claude` with the channel, and a first prompt when there is one. The prompt comes
  /// before the flag so a channel option that takes several values can't swallow it as a channel name.
  public static func command(prompt: String?) -> String {
    var words = ["claude"]
    if let prompt { words.append(AutomationTemplate.shellQuoted(prompt)) }
    return (words + flag).joined(separator: " ")
  }

  /// A tab title with Studio's channel flag left out: the shell titles the tab with the line Studio typed, and the
  /// flag is noise there.
  public static func hidingFlag(in title: String) -> String {
    title.replacingOccurrences(of: " " + flag.joined(separator: " "), with: "")
  }

  /// A command's arguments with Studio's channel flag left out, for the sidebar's command chip.
  public static func hidingFlag(arguments: [String]) -> [String] {
    var shown: [String] = []
    var index = arguments.startIndex
    while index < arguments.endIndex {
      if arguments[index...].starts(with: flag) {
        index += flag.count
      } else {
        shown.append(arguments[index])
        index += 1
      }
    }
    return shown
  }
}
