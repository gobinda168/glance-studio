import Foundation
import Testing

private let script = URL(fileURLWithPath: #filePath) // <package>/Tests/GlanceCoreTests/StatusLineScriptTests.swift
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("hooks/statusline.sh")

private func makeDirectory() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("statusline-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

/// Runs the script with `input` on stdin and `GLANCE_DIR` set; returns its stdout and exit status.
private func run(_ input: String, in dir: URL) throws -> (output: String, status: Int32) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [script.path]
  process.environment = ["GLANCE_DIR": dir.path, "PATH": "/usr/bin:/bin"]
  let stdin = Pipe(), stdout = Pipe()
  process.standardInput = stdin
  process.standardOutput = stdout
  try process.run()
  stdin.fileHandleForWriting.write(Data(input.utf8))
  try stdin.fileHandleForWriting.close()
  let data = stdout.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (String(decoding: data, as: UTF8.self), process.terminationStatus)
}

private let withLimits = #"{"session_id":"a","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1700009999}}}"#
private let withoutLimits = #"{"session_id":"b","model":{"id":"x"}}"#

@Test func aPayloadWithRateLimitsIsSaved() throws {
  let dir = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let result = try run(withLimits, in: dir)
  #expect(result.status == 0)
  #expect(result.output == "") // nothing wrapped: the footer is untouched
  let saved = try String(contentsOf: dir.appendingPathComponent("usage.json"), encoding: .utf8)
  #expect(saved == withLimits)
  let permissions = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("usage.json").path)[.posixPermissions] as? Int
  #expect(permissions == 0o600)
  let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp") }
  #expect(leftovers.isEmpty)
}

@Test func aPayloadWithoutRateLimitsKeepsTheLastGoodFile() throws {
  let dir = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  _ = try run(withLimits, in: dir)
  let result = try run(withoutLimits, in: dir) // a fresh session, before its first response
  #expect(result.status == 0)
  #expect(try String(contentsOf: dir.appendingPathComponent("usage.json"), encoding: .utf8) == withLimits)
}

@Test func anExistingStatusLineStillRunsAndItsOutputPassesThrough() throws {
  let dir = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  // Quotes, spaces and a pipe in the wrapped command; it reads the same payload from stdin.
  try "grep -o '\"session_id\":\"[a-z]*\"' | tr a-z A-Z".write(to: dir.appendingPathComponent("statusline.inner"), atomically: true, encoding: .utf8)
  let result = try run(withLimits, in: dir)
  #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "\"SESSION_ID\":\"A\"")
  #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("usage.json").path))
}

@Test func theWrappedCommandsExitStatusIsKept() throws {
  let dir = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  try "cat >/dev/null; exit 3".write(to: dir.appendingPathComponent("statusline.inner"), atomically: true, encoding: .utf8)
  #expect(try run(withLimits, in: dir).status == 3)
}

@Test func anUnwritableDirectoryNeverFailsClaudeCode() throws {
  // GLANCE_DIR is a regular file, so the directory can't be created or written.
  let parent = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: parent) }
  let blocker = parent.appendingPathComponent("blocker")
  try "x".write(to: blocker, atomically: true, encoding: .utf8)
  let result = try run(withLimits, in: blocker)
  #expect(result.status == 0)
  #expect(result.output == "")
}

@Test func theWrappedCommandGetsTheExactPayloadIncludingItsNewline() throws {
  let dir = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  try "wc -c".write(to: dir.appendingPathComponent("statusline.inner"), atomically: true, encoding: .utf8)
  let input = withLimits + "\n"
  let count = try run(input, in: dir).output.trimmingCharacters(in: .whitespacesAndNewlines)
  #expect(Int(count) == input.utf8.count)
}
