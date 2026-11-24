import Foundation
import Testing
@testable import GlanceCore

/// The glance-proof mod (mods/glance-proof): what its skills teach has to be what Glance reads.
private let mods = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mods")
private let mod = mods.appendingPathComponent("glance-proof")

private func skill(_ name: String) throws -> String {
  try String(contentsOf: mod.appendingPathComponent("skills/\(name)/SKILL.md"), encoding: .utf8)
}

struct ProofSkillTests {
  @Test func theModIsOneClaudeCodeLoadsFromTheBundle() throws {
    #expect(ClaudeMods.bundled(in: mods).map(\.lastPathComponent).contains("glance-proof"))
    let manifest = try JSONSerialization.jsonObject(
      with: Data(contentsOf: mod.appendingPathComponent(".claude-plugin/plugin.json"))) as? [String: Any]
    #expect(manifest?["name"] as? String == "glance-proof")
    for name in ["glance-proof-setup", "glance-proof"] {
      let text = try skill(name)
      #expect(text.hasPrefix("---\nname: \(name)\ndescription: "))
    }
  }

  @Test func theSetupSkillsSampleIsTheFormatTheDecoderReads() throws {
    let text = try skill("glance-proof-setup")
    // The sample is the 4-space indented block that starts at `{` and ends at the matching `}`.
    let lines = text.components(separatedBy: "\n")
    let start = try #require(lines.firstIndex(of: "    {"))
    let end = try #require(lines[start...].firstIndex(of: "    }"))
    let json = lines[start...end].map { String($0.dropFirst(4)) }.joined(separator: "\n")
    let load = ProofSetupFile.parse(json, root: "/repo")
    guard case .valid(let setup, _) = load else {
      Issue.record("The skill's sample isn't a valid proof.json: \(load)")
      return
    }
    #expect(setup.version == 1)
    #expect(setup.environments.count == 2)
    #expect(setup.environments[0].url != nil && setup.environments[1].urlScript != nil)
    #expect(setup.checks.map(\.env) == ["Local", nil])
    #expect(setup.checks[1].envFrom != nil)
    #expect(setup.required == ["Unit@Local", "E2E@Preview"])
    #expect(setup.sections.count == 1)
  }

  @Test func theSampleNamesNoRealCommandsOrTools() throws {
    // Nothing static: the sample's values are placeholders the project's own files replace.
    let text = try skill("glance-proof-setup")
    let lines = text.components(separatedBy: "\n")
    let start = try #require(lines.firstIndex(of: "    {"))
    let end = try #require(lines[start...].firstIndex(of: "    }"))
    let sample = lines[start...end].joined(separator: "\n").lowercased()
    for runner in ["npm", "pnpm", "yarn", "playwright", "jest", "vitest", "pytest", "cargo", "swift test", "firebase"] {
      #expect(!sample.contains(runner), "the sample mentions \(runner)")
    }
    #expect(text.contains("format only"))
  }

  @Test func theSkillsTeachTheProofToolsGlanceHas() throws {
    let all = try skill("glance-proof-setup") + skill("glance-proof")
    // Every tool a skill names exists, and the proof skill covers each of the five.
    let named = Set(all.matches(of: /proof_[a-z]+/).map { String($0.output) })
    #expect(named.isSubset(of: ProofTools.names))
    let proof = try skill("glance-proof")
    for tool in ProofTools.names { #expect(proof.contains(tool), "glance-proof never mentions \(tool)") }
    // The values the tools accept.
    for kind in ["tried", "found", "problem", "resolved"] { #expect(proof.contains(kind)) }
    for verdict in ["merge", "hold", "not-ready"] { #expect(proof.contains(verdict)) }
    #expect(proof.contains("purpose: \"outcome\""))
  }

  @Test func theArgumentsTheSkillsUseAreTheToolsOwn() throws {
    // Argument name -> the tool that takes it.
    func properties(_ tool: String) throws -> Set<String> {
      let definition = try #require(ProofTools.definitions.first { $0["name"]?.string == tool })
      return Set(definition["inputSchema"]?["properties"]?.object?.keys.map { $0 } ?? [])
    }
    let proof = try skill("glance-proof")
    for (tool, argument) in [("proof_note", "section"), ("proof_note", "kind"), ("proof_pending", "done"),
                             ("proof_verdict", "reasons"), ("proof_verdict", "verdict"), ("proof_capture", "path"),
                             ("proof_capture", "caption"), ("proof_capture", "url"), ("proof_capture", "purpose")] {
      #expect(try properties(tool).contains(argument), "\(tool) has no \(argument)")
      #expect(proof.contains("`\(argument)`") || proof.contains("\(argument): ") || proof.contains("\(argument)`"),
              "glance-proof never uses \(argument)")
    }
    // The values the capture tool accepts (images, videos, logs) are the ones the skill names.
    #expect(proof.contains("log, txt"))
  }

  @Test func theProofSkillIsInertWithoutTheTools() throws {
    // The mod loads in every Studio session: its description must not fire for an ordinary project.
    let proof = try skill("glance-proof")
    let description = try #require(proof.components(separatedBy: "\n").first { $0.hasPrefix("description: ") })
    #expect(description.contains("Use only when the Glance proof tools"))
    #expect(description.contains("Without those tools, ignore this skill."))
    #expect(proof.contains("carry on normally and say nothing about it"))
    // Only the setup skill, which the user asked for, explains that Command Center is off.
    #expect(!proof.contains("Command Center is off"))
    #expect(try skill("glance-proof-setup").contains("Command Center is off"))
    #expect(try skill("glance-proof-setup").contains("search for it first"))
  }
}
