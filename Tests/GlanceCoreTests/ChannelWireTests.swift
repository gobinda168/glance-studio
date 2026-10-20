import Testing
@testable import GlanceCore

@Suite struct ChannelWireTests {
  @Test func studioMessagesRoundTrip() {
    let messages: [ChannelWire.ToStudio] = [
      .hello(.init(pid: 10, ppid: 9, projectDir: "/Users/me/glance", cwd: "/Users/me/glance")),
      .hello(.init(pid: 10, ppid: 9, projectDir: nil, cwd: "/tmp")),
      .call(callID: "c1", tool: "ask", arguments: ["question": "Ship?", "choices": ["Yes", "No"]]),
      .permissionRequest(.init(requestID: "abcde", tool: "Bash", description: "Delete build", input: #"{"command":"rm -rf build"}"#)),
    ]
    for message in messages {
      #expect(message.line.hasSuffix("\n"))
      #expect(message.line.dropLast().contains("\n") == false)
      #expect(ChannelWire.ToStudio(line: String(message.line.dropLast())) == message)
    }
  }

  @Test func shimMessagesRoundTrip() {
    let messages: [ChannelWire.ToShim] = [
      .welcome(assistant: true, label: "glance"),
      .result(callID: "c1", value: ["answer": "Yes", "via": "voice"], isError: false),
      .result(callID: "c2", value: "Glance Studio closed.", isError: true),
      .push(content: "Also run lint.", meta: ["from": "glance", "via": "voice"]),
      .verdict(requestID: "abcde", allow: false),
    ]
    for message in messages {
      #expect(ChannelWire.ToShim(line: String(message.line.dropLast())) == message)
    }
  }

  @Test func junkIsNotAMessage() {
    #expect(ChannelWire.ToStudio(line: "nope") == nil)
    #expect(ChannelWire.ToStudio(line: #"{"type":"hello"}"#) == nil)
    #expect(ChannelWire.ToShim(line: #"{"type":"verdict","requestID":"x"}"#) == nil)
    #expect(ChannelWire.ToStudio(line: #"{"type":"hello","pid":3000000000,"ppid":9,"cwd":"/tmp"}"#) == nil)
    #expect(ChannelWire.ToStudio(line: #"{"type":"hello","pid":"10","ppid":9,"cwd":"/tmp"}"#) == nil)
    #expect(ChannelWire.ToStudio(line: #"{"type":"hello","pid":0,"ppid":9,"cwd":"/tmp"}"#) == nil)
  }

  @Test func socketPathAndOverride() {
    #expect(ChannelPaths.socket(environment: [:], home: "/Users/me")
      == "/Users/me/Library/Application Support/Glance/orb.sock")
    #expect(ChannelPaths.socket(environment: ["GLANCE_ORB_SOCKET": "/tmp/x.sock"], home: "/Users/me") == "/tmp/x.sock")
  }

  @Test func channelFlagIsSeenInClaudesArguments() {
    #expect(ChannelLaunch.hasChannel(arguments: ["claude", "--dangerously-load-development-channels", "server:glance"]))
    #expect(ChannelLaunch.hasChannel(arguments: ["claude", "--channels", "plugin:glance@glance"]))
    #expect(ChannelLaunch.hasChannel(arguments: ["claude", "--channels=plugin:glance@glance"]))
    #expect(!ChannelLaunch.hasChannel(arguments: ["claude", "-p", "hi"]))
    #expect(ChannelLaunch.command(prompt: nil) == "claude " + ChannelLaunch.flag.joined(separator: " "))
    let withPrompt = ChannelLaunch.command(prompt: "fix it's test")
    #expect(withPrompt.hasPrefix(#"claude 'fix it'\''s test' "#))
    #expect(withPrompt.hasSuffix(ChannelLaunch.flag.joined(separator: " ")))
  }

  @Test func tabsShowClaudeWithoutStudiosChannelFlag() {
    #expect(ChannelLaunch.hidingFlag(in: ChannelLaunch.command(prompt: nil)) == "claude")
    #expect(ChannelLaunch.hidingFlag(in: ChannelLaunch.command(prompt: "fix it")) == "claude 'fix it'")
    #expect(ChannelLaunch.hidingFlag(in: "✳ Fix the tests") == "✳ Fix the tests")
    #expect(ChannelLaunch.hidingFlag(in: "claude --dangerously-load-development-channels server:other")
      == "claude --dangerously-load-development-channels server:other")
    #expect(ChannelLaunch.hidingFlag(arguments: ["claude", "--dangerously-load-development-channels", "server:glance"])
      == ["claude"])
    #expect(ChannelLaunch.hidingFlag(arguments: ["claude", "-c", "--dangerously-load-development-channels", "server:glance"])
      == ["claude", "-c"])
    #expect(ChannelLaunch.hidingFlag(arguments: ["claude", "--dangerously-load-development-channels", "server:other"])
      == ["claude", "--dangerously-load-development-channels", "server:other"])
  }
}
