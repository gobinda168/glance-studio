import Foundation
import Testing
@testable import GlanceCore

private let cli = "/Applications/Glance Studio.app/Contents/MacOS/glance"

@Test func thePluginHasItsManifestServerSkillAndReferences() {
  let files = AutomationPlugin.files(cli: cli)
  for path in [".claude-plugin/plugin.json", ".mcp.json", "skills/glance-automations/SKILL.md",
               "skills/glance-automations/references/manifest.md", "skills/glance-automations/references/events.md",
               "skills/glance-automations/references/ui.md"] {
    #expect(files[path]?.isEmpty == false, "\(path)")
  }
  for (id, package) in AutomationStarters.all {
    for path in package.keys {
      #expect(files["skills/glance-automations/references/starters/\(id)/\(path)"] == package[path])
    }
  }
  #expect(files["skills/glance-automations/references/events.md"] == AutomationEvents.markdown())
}

@Test func theServerIsThisCLIsAutomationMCP() {
  let mcp = AutomationValue.decode(Data(AutomationPlugin.mcpJSON(cli: cli).utf8))
  #expect(mcp == .object(["mcpServers": .object(["glance": .object([
    "command": .string(cli), "args": .array([.string("automation"), .string("mcp")]),
  ])])]))
  let plugin = AutomationValue.decode(Data(AutomationPlugin.pluginJSON.utf8))?.object
  #expect(plugin?["name"] == .string("glance"))
  #expect(plugin?["version"] == .string(AutomationPlugin.version))
}

@Test func theSkillStatesItsRulesAndFacts() {
  let skill = AutomationPluginDocs.skill(cli: cli)
  #expect(skill.hasPrefix("---\nname: glance-automations\ndescription: "))
  for tool in ["automations_search", "automation_get", "automation_run", "automation_runs", "automation_save",
               "automation_events"] {
    #expect(skill.contains("`\(tool)`"), "\(tool)")
  }
  for rule in 1...8 { #expect(skill.contains("\n\(rule). "), "rule \(rule)") }
  #expect(skill.contains("\"\(cli)\" automation check"))
  #expect(skill.contains("never `'{{inputs.pr}}'` or `\"{{inputs.pr}}\"`"))
  #expect(skill.contains("GLANCE_INPUTS_FILE"))
  #expect(skill.contains("only up to 64 KB"))
  #expect(skill.contains("there is no direct internet access"))
  #expect(skill.contains("never call an automation \"sandboxed\""))
  #expect(skill.contains("at least `10s`"))
  #expect(skill.contains("Saving never approves"))
  #expect(skill.contains("`state` is reserved"))
}

// The skill, its references and the starters are text Claude reads: no em or en dashes as punctuation (house rule).
@Test func theDocsUseNoDashPunctuation() {
  for (path, text) in AutomationPlugin.files(cli: cli) {
    #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), "\(path)")
  }
}

@Test func theHashChangesWithTheContentOnly() {
  let files = AutomationPlugin.files(cli: cli)
  #expect(AutomationPlugin.contentHash(files) == AutomationPlugin.contentHash(files))
  #expect(AutomationPlugin.contentHash(files).count == 64)
  #expect(AutomationPlugin.contentHash(files) != AutomationPlugin.contentHash(AutomationPlugin.files(cli: "/x/glance")))
  var moved = files
  moved["a"] = "bc"
  var split = files
  split["ab"] = "c"
  #expect(AutomationPlugin.contentHash(moved) != AutomationPlugin.contentHash(split))
}

@Test func theDocsStateTheEngineFactsThatBite() {
  let docs = AutomationPlugin.files(cli: cli)
  let skill = docs["skills/glance-automations/SKILL.md"] ?? ""
  let manifest = docs["skills/glance-automations/references/manifest.md"] ?? ""
  let ui = docs["skills/glance-automations/references/ui.md"] ?? ""
  #expect(skill.contains("a later `{{steps.<skipped>.…}}` fails the run"))
  #expect(manifest.contains("referencing `{{steps.<skipped>.…}}` fails the run"))
  #expect(skill.contains("A watcher sees the inputs' defaults only"))
  #expect(skill.contains("It is not a full sandbox"))
  #expect(skill.contains("An entry can't contain a comma"))
  #expect(skill.contains("`\"outward\": true`"))
  #expect(skill.contains("Script paths stay inside the package"))
  #expect(skill.contains("Search the library first"))
  #expect(ui.contains("Every link out asks the user first"))
}

@Test func onlyGlancesOwnManifestCountsAsItsPluginFolder() {
  #expect(AutomationPlugin.isGlancePluginManifest(AutomationPlugin.pluginJSON))
  #expect(!AutomationPlugin.isGlancePluginManifest("{\"name\": \"other\"}"))
  #expect(!AutomationPlugin.isGlancePluginManifest("not json"))
  #expect(!AutomationPlugin.isGlancePluginManifest("[]"))
}

@Test func onlyAnInstalledAppMayRewriteStudiosPluginFolder() {
  #expect(AutomationPlugin.isInsideAppBundle(cli))
  #expect(!AutomationPlugin.isInsideAppBundle("/Users/me/Code/glance/.build/debug/glance"))
  #expect(!AutomationPlugin.isInsideAppBundle("/Users/me/Code/glance.app"))
}

@Test func theSkillSaysAParkedRunWaitsForTheUser() {
  let skill = AutomationPluginDocs.skill(cli: cli)
  #expect(skill.contains("result of `parked` means the run is waiting for the user's approval"))
  #expect(skill.contains("never report it as finished"))
  #expect(!skill.contains("in the words below"))
}

@Test func theSkillSaysWhereASaveReadsItsDraftFrom() {
  let skill = AutomationPluginDocs.skill(cli: cli)
  #expect(skill.contains("`.drafts/<id>` means `<library>/.drafts/<id>`"))
  #expect(skill.contains("`files` alone to change the current package"))
  #expect(skill.contains("drafts live in `<library>/.drafts/<id>/`"))
  #expect(skill.contains("it must hold that automation's automation.json"))
  #expect(!skill.contains("any folder you can write"))
}
