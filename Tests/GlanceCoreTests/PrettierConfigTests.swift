import Foundation
import Testing
@testable import GlanceCore

/// A temporary project folder with these files (relative path → contents).
private func project(_ files: [String: String]) throws -> String {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-fmt-\(UUID().uuidString)")
  for (path, text) in files {
    let url = dir.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }
  try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
  return dir.path
}

private func noNode(_: String, _: String) -> [String: Any]? { nil }

@Test func theNearestPrettierrcWinsAndItsOverridesApply() throws {
  let root = try project([
    ".prettierrc": #"{ "semi": false, "printWidth": 100, "overrides": [{ "files": "*.ts", "options": { "singleQuote": true } }] }"#,
    "package.json": #"{ "name": "x" }"#,
  ])
  let ts = PrettierConfig.options(for: root + "/src/a.ts", evaluate: noNode)
  #expect(ts["semi"] as? Bool == false)
  #expect(ts["printWidth"] as? Int == 100)
  #expect(ts["singleQuote"] as? Bool == true)
  #expect(ts["overrides"] == nil)
  #expect(PrettierConfig.options(for: root + "/src/a.js", evaluate: noNode)["singleQuote"] == nil)
}

@Test func packageJsonsPrettierKeyCountsButAPackageJsonWithoutOneDoesnt() throws {
  let root = try project([
    "package.json": #"{ "prettier": { "tabWidth": 4 } }"#,
    "src/package.json": #"{ "name": "inner" }"#,
  ])
  #expect(PrettierConfig.options(for: root + "/src/a.js", evaluate: noNode)["tabWidth"] as? Int == 4)
}

@Test func yamlPrettierrcsAreRead() throws {
  let root = try project([".prettierrc.yaml": "# style\nsemi: false\nsingleQuote: true # quotes\ntrailingComma: \"all\"\nprintWidth: 120\noverrides:\n  - files: x\n"])
  let options = PrettierConfig.options(for: root + "/src/a.js", evaluate: noNode)
  #expect(options["semi"] as? Bool == false)
  #expect(options["singleQuote"] as? Bool == true)
  #expect(options["trailingComma"] as? String == "all")
  #expect(options["printWidth"] as? Int == 120)
  #expect(options["overrides"] == nil)
}

@Test func javascriptAndSharedConfigsGoThroughNode() throws {
  let root = try project(["prettier.config.js": "export default { semi: false }", "sub/package.json": #"{ "prettier": "@acme/style" }"#])
  var asked: [String] = []
  let evaluate: PrettierConfig.Evaluate = { module, _ in asked.append(module); return ["useTabs": true] }
  #expect(PrettierConfig.options(for: root + "/src/a.js", evaluate: evaluate)["useTabs"] as? Bool == true)
  #expect(asked == [root + "/prettier.config.js"])
  #expect(PrettierConfig.options(for: root + "/sub/a.js", evaluate: evaluate)["useTabs"] as? Bool == true)
  #expect(asked.last == "@acme/style")
}

@Test func editorconfigFillsInWhatPrettierDoesntSay() throws {
  let root = try project([
    ".editorconfig": "root = true\n[*]\nindent_style = space\nindent_size = 4\nmax_line_length = 90\n[*.md]\nindent_size = 2\n[Makefile]\nindent_style = tab\n",
    ".prettierrc.json": #"{ "printWidth": 110 }"#,
  ])
  let js = PrettierConfig.options(for: root + "/src/a.js", evaluate: noNode)
  #expect(js["useTabs"] as? Bool == false)
  #expect(js["tabWidth"] as? Int == 4)
  #expect(js["printWidth"] as? Int == 110) // the Prettier config wins
  #expect(PrettierConfig.options(for: root + "/src/README.md", evaluate: noNode)["tabWidth"] as? Int == 2)
}

@Test func noConfigMeansPrettiersDefaults() throws {
  let root = try project(["src/a.js": "x"])
  #expect(PrettierConfig.editorConfig(for: root + "/src/a.js").isEmpty)
}

@Test func globsMatchLikePrettierAndEditorConfig() {
  #expect(Glob.matches("*.ts", "src/deep/a.ts"))
  #expect(!Glob.matches("*.ts", "src/a.tsx"))
  #expect(Glob.matches("*.{js,ts}", "a.js"))
  #expect(Glob.matches("src/**/*.css", "src/a/b/c.css"))
  #expect(Glob.matches("src/**/*.css", "src/c.css"))
  #expect(!Glob.matches("src/*.css", "src/a/c.css"))
  #expect(Glob.matches("**/*.md", "README.md"))
  #expect(Glob.matches("legacy/**", "legacy/x/y.js"))
  #expect(Glob.matches("[Mm]akefile", "Makefile"))
  #expect(Glob.matches("a?c.js", "abc.js"))
  #expect(!Glob.matches("a.js", "a_js"))
}
