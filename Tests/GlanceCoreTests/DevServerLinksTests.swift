import Darwin
import Foundation
import Testing
@testable import GlanceCore

private func devServer(_ text: String) -> String? {
  DevServerLinks.devServerURL(text)?.absoluteString
}

@Test func addressesOnThisMacAreDevServers() {
  for text in ["http://localhost:5173/", "http://localhost", "https://localhost:3000/app?x=1#top", "HTTP://LocalHost:8080",
               "http://127.0.0.1:8000", "http://127.1.2.3:9000/", "http://[::1]:3000/", "http://app.localhost:5173",
               "  http://localhost:4321/  "] {
    #expect(devServer(text) != nil, "\(text) is a dev server")
  }
  #expect(devServer("http://localhost:5173/") == "http://localhost:5173/")
  #expect(devServer("http://[::1]:3000/") == "http://[::1]:3000/")
}

@Test func everyAddressServersAreShownOnLocalhost() {
  #expect(devServer("http://0.0.0.0:3000/docs?q=1") == "http://localhost:3000/docs?q=1")
  #expect(devServer("https://0.0.0.0:8443") == "https://localhost:8443")
  #expect(devServer("http://[::]:4000/") == "http://localhost:4000/")
}

@Test func otherAddressesAreNotDevServers() {
  for text in ["https://github.com/apple/swift", "http://192.168.1.4:3000", "http://10.0.0.1", "http://localhost.evil.com",
               "http://mylocalhost:3000", "http://128.0.0.1", "http://127.0.0", "file:///Users/me/index.html",
               "ws://localhost:5173", "localhost:3000", "Sources/App.swift", "", "mailto:a@localhost"] {
    #expect(devServer(text) == nil, "\(text) isn't a dev server")
  }
}

@Test func sameOriginMeansSchemeHostAndPort() {
  func same(_ a: String, _ b: String) -> Bool { DevServerLinks.sameOrigin(URL(string: a)!, URL(string: b)!) }
  #expect(same("http://localhost:5173/about", "http://localhost:5173/"))
  #expect(same("http://LOCALHOST:5173", "http://localhost:5173/x?y"))
  #expect(same("http://localhost/", "http://localhost:80/"))
  #expect(same("https://localhost/", "https://localhost:443/a"))
  #expect(same("http://[::1]:3000/", "http://[::1]:3000/b"))
  #expect(!same("http://localhost:5173/", "http://localhost:5174/"))
  #expect(!same("http://localhost:5173/", "https://localhost:5173/"))
  #expect(!same("http://localhost:3000/", "http://127.0.0.1:3000/"))
}

@Test func aTabOnTheServerReloadsForItsFrontPageOrItsOwnPage() {
  func reloads(_ current: String, _ url: String) -> Bool {
    DevServerLinks.reloads(URL(string: current)!, for: URL(string: url)!)
  }
  #expect(reloads("http://localhost:5173/about", "http://localhost:5173/"))
  #expect(reloads("http://localhost:5173/about", "http://localhost:5173"))
  #expect(reloads("http://localhost:5173/about?tab=2", "http://localhost:5173/about?tab=2"))
  #expect(!reloads("http://localhost:5173/", "http://localhost:5173/about"))
  #expect(!reloads("http://localhost:5173/about", "http://localhost:5173/?login=1"))
}

@Test func theSettingIsOnUntilSwitchedOff() throws {
  let suite = "dev.glance.tests.devserver.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  #expect(DevServerLinks.isEnabled(in: defaults))
  defaults.set(false, forKey: DevServerLinks.settingKey)
  #expect(!DevServerLinks.isEnabled(in: defaults))
  defaults.set(true, forKey: DevServerLinks.settingKey)
  #expect(DevServerLinks.isEnabled(in: defaults))
}

@Test func theHelperTalksTheShellBridgesWire() {
  #expect(ShellEvent(line: "browse\tTAB-1\thttp://localhost:5173/") == .browse(tab: "TAB-1", url: "http://localhost:5173/"))
  #expect(ShellEvent(line: "browse\t\thttp://localhost:5173/") == .browse(tab: "", url: "http://localhost:5173/"))
  #expect(ShellEvent(line: "browse\tTAB-1\t") == nil)
  #expect(ShellEvent(line: "browse\tTAB-1") == nil)
  #expect(ShellCommand.browsed(true).line == "browsed\tyes\n")
  #expect(ShellCommand.browsed(false).line == "browsed\tno\n")
}

// MARK: The helper, run for real

/// Runs the helper with sh as `BROWSER` would, with a socket playing Studio that answers `reply` (nil: no Studio).
/// Returns what Studio was sent and what the stand-in for `open` printed.
private func runHelper(_ arguments: [String], reply: String?) throws -> (sent: [String], opened: String) {
  let folder = URL(fileURLWithPath: "/tmp/gdl-\(UUID().uuidString.prefix(8))", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let helper = folder.appendingPathComponent(DevServerLinks.helperName)
  try DevServerLinks.helperScript.write(to: helper, atomically: true, encoding: .utf8)
  let socketPath = folder.appendingPathComponent("s").path

  let listener = socket(AF_UNIX, SOCK_STREAM, 0)
  defer { close(listener) }
  if reply != nil {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in path.withUnsafeBytes { raw.copyMemory(from: $0) } }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    #expect(bound == 0 && listen(listener, 4) == 0)
  }

  // Studio's side, on its own thread: read one line, answer, close.
  let sent = LockedLines()
  let served = DispatchSemaphore(value: 0)
  if let reply {
    Thread.detachNewThread {
      defer { served.signal() }
      var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      guard poll(&poller, 1, 5_000) == 1 else { return }
      let connection = accept(listener, nil, nil)
      defer { close(connection) }
      var lines = ShellLines()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while sent.isEmpty {
        let n = read(connection, &buffer, buffer.count)
        guard n > 0 else { return }
        sent.append(lines.append(Data(buffer[0..<n])))
      }
      let bytes = Array(reply.utf8)
      _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
    }
  }

  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [helper.path] + arguments
  process.environment = ["PATH": "/usr/bin:/bin", "GLANCE_SHELL_SOCKET": socketPath, "GLANCE_SHELL_TAB": "TAB-7",
                         "GLANCE_BROWSER_FALLBACK": "/bin/echo"]
  process.standardOutput = output
  try process.run()
  process.waitUntilExit()
  if reply != nil { served.wait() }
  let opened = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  return (sent.lines, opened.trimmingCharacters(in: .whitespacesAndNewlines))
}

private final class LockedLines: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var lines: [String] { lock.withLock { stored } }
  var isEmpty: Bool { lock.withLock { stored.isEmpty } }
  func append(_ new: [String]) { lock.withLock { stored += new } }
}

@Test func theHelperHandsTheAddressToStudio() throws {
  let run = try runHelper(["--new-tab", "http://localhost:5173/"], reply: ShellCommand.browsed(true).line)
  #expect(run.sent == ["browse\tTAB-7\thttp://localhost:5173/"])
  #expect(run.opened.isEmpty)
}

@Test func theHelperOpensTheAddressItselfWhenStudioDoesNot() throws {
  let refused = try runHelper(["https://example.com/"], reply: ShellCommand.browsed(false).line)
  #expect(refused.sent == ["browse\tTAB-7\thttps://example.com/"])
  #expect(refused.opened == "https://example.com/")
  let noStudio = try runHelper(["http://localhost:3000"], reply: nil)
  #expect(noStudio.sent.isEmpty)
  #expect(noStudio.opened == "http://localhost:3000")
}

@Test func theHelperIsJavaScriptToo() throws {
  let script = DevServerLinks.helperScript
  #expect(script.hasPrefix("#!/bin/sh\n\":\" /*\n"))
  // sh's part sits in one block comment for node; nothing in it may end that comment early.
  let shell = try #require(script.components(separatedBy: "\":\" /*\n").last?.components(separatedBy: "\n*/\n").first)
  #expect(!shell.contains("*/"))
  #expect(script.contains("\n*/\nconst { spawnSync } = require(\"child_process\");"))
}
