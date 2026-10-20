import Foundation

/// Just enough HTTP/1.1 to receive hook events from curl on localhost.
public struct HTTPRequest: Equatable, Sendable {
  public var method: String
  public var path: String
  /// Header names lowercased.
  public var headers: [String: String]
  public var body: Data

  public enum Parse: Equatable, Sendable {
    case incomplete, invalid
    case complete(HTTPRequest)
  }

  public static let maxBody = 1 << 20

  public static func parse(_ data: Data) -> Parse {
    let separator = Data("\r\n\r\n".utf8)
    guard let headEnd = data.range(of: separator) else {
      return data.count > 16 * 1024 ? .invalid : .incomplete
    }
    let head = String(decoding: data[data.startIndex..<headEnd.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { return .invalid }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    var length = 0
    if let value = headers["content-length"] {
      guard let parsed = Int(value), (0...maxBody).contains(parsed) else { return .invalid }
      length = parsed
    }
    let body = data[headEnd.upperBound...]
    guard body.count >= length else { return .incomplete }
    return .complete(HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                                 body: Data(body.prefix(length))))
  }

  public static func response(status: Int, reason: String, body: String = "", contentType: String = "text/plain")
    -> Data {
    Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
  }
}

/// The fields Glance uses from a Claude Code hook's JSON input.
public struct HookEvent: Decodable, Equatable, Sendable {
  public var name: String
  public var sessionID: String?
  public var transcriptPath: String?
  public var cwd: String?

  enum CodingKeys: String, CodingKey {
    case name = "hook_event_name", sessionID = "session_id", transcriptPath = "transcript_path", cwd
  }

  public init(name: String, sessionID: String?, transcriptPath: String?, cwd: String?) {
    self.name = name
    self.sessionID = sessionID
    self.transcriptPath = transcriptPath
    self.cwd = cwd
  }

  /// Only Claude Code transcripts may be read: anything local can POST to the server.
  public func isTranscriptPathAllowed(home: String) -> Bool {
    guard let path = transcriptPath, path.hasSuffix(".jsonl") else { return false }
    let standardized = (path as NSString).standardizingPath
    return standardized == path && standardized.hasPrefix(home + "/.claude/projects/")
  }
}
