import Darwin
import Foundation
import Testing
@testable import GlanceCore

private func procArgs(argc: Int32, executable: String, padding: Int = 3, arguments: [String], environment: [String] = ["HOME=/x"]) -> Data {
  var data = Data()
  var count = argc
  withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
  data.append(contentsOf: Array(executable.utf8) + [0])
  data.append(contentsOf: [UInt8](repeating: 0, count: padding))
  for argument in arguments + environment { data.append(contentsOf: Array(argument.utf8) + [0]) }
  return data
}

@Test func aProcessArgsBufferParsesIntoExecutableAndArguments() {
  let data = procArgs(argc: 3, executable: "/bin/ls", arguments: ["ls", "-l", "/tmp"])
  let parsed = ProcessArguments.parse(data)
  #expect(parsed?.executable == "/bin/ls")
  #expect(parsed?.arguments == ["ls", "-l", "/tmp"]) // the environment after argc arguments is ignored
}

@Test func aShortOrBrokenBufferIsNil() {
  #expect(ProcessArguments.parse(Data()) == nil)
  #expect(ProcessArguments.parse(Data([1, 0, 0])) == nil)
  #expect(ProcessArguments.parse(procArgs(argc: -1, executable: "/bin/ls", arguments: [])) == nil)
}

@Test func fewerArgumentsThanArgcAreReturnedAsFarAsTheyGo() {
  let data = procArgs(argc: 5, executable: "/bin/ls", arguments: ["ls"], environment: [])
  #expect(ProcessArguments.parse(data)?.arguments == ["ls"])
}

@Test func theRunningProcessCanBeRead() {
  let read = ProcessArguments.read(pid: Int(getpid()))
  let executable = read?.executable ?? ""
  let arguments = read?.arguments ?? []
  #expect(read != nil)
  #expect(!executable.isEmpty)
  #expect(!arguments.isEmpty)
}

@Test func aMissingProcessIsNil() {
  #expect(ProcessArguments.read(pid: 999_999) == nil)
}

@Test func shellsAreNotShownAsCommands() {
  #expect(CommandName.chip(executable: "/bin/zsh", arguments: ["-zsh"], loginShell: nil) == nil)
  #expect(CommandName.chip(executable: "/bin/bash", arguments: ["bash"], loginShell: nil) == nil)
  #expect(CommandName.chip(executable: "/usr/local/bin/nu", arguments: ["nu"], loginShell: nil) == nil)
  #expect(CommandName.chip(executable: "/opt/tools/mysh", arguments: ["mysh"], loginShell: "/opt/tools/mysh") == nil)
}

@Test func programsShowTheirNameAndShortenedArguments() {
  #expect(CommandName.chip(executable: "/opt/homebrew/bin/npm", arguments: ["npm", "run", "dev"], loginShell: nil) == "npm run dev")
  #expect(CommandName.chip(executable: "/usr/bin/vim", arguments: ["vim", "notes.txt"], loginShell: nil) == "vim notes.txt")
  #expect(CommandName.chip(executable: "/usr/local/bin/claude", arguments: ["claude"], loginShell: nil) == "claude")
  #expect(CommandName.chip(executable: "/usr/local/bin/node", arguments: ["node", "/Users/me/app/server.js"], loginShell: nil) == "node server.js")
}

@Test func studiosChannelFlagIsLeftOutOfTheChip() {
  let arguments = ["claude", "--dangerously-load-development-channels", "server:glance"]
  #expect(CommandName.chip(executable: "/usr/local/bin/claude", arguments: arguments, loginShell: nil) == "claude")
}

@Test func withoutArgumentsTheExecutableNameIsUsed() {
  #expect(CommandName.chip(executable: "/usr/bin/top", arguments: [], loginShell: nil) == "top")
}

@Test func longCommandsAreCutWithAnEllipsis() {
  let chip = CommandName.chip(executable: "/usr/bin/tail", arguments: ["tail", "-f", "a-very-long-file-name-that-keeps-going.log"], loginShell: nil, limit: 20)
  #expect(chip?.count == 20)
  #expect(chip?.hasSuffix("…") == true)
}
