import Foundation
import GlanceCore

/// Format Document's Swift half (`CodeFormatter` decides; this finds the tools on this Mac and runs them). Blocking:
/// call it off the main thread.
enum FormatRunner {
  enum Outcome {
    case prettier(parser: String, options: [String: Any])
    case formatted(String)
  }

  /// The login shell's PATH, looked up once (it takes a moment).
  private static let loginPath: String? = ClaudeLocator.loginPath()

  /// How to format `relative` (inside `root`): `text` run through the project's own formatter (its Prettier, ruff,
  /// gofmt…), or, for a web language in a project without Prettier installed, Prettier's options for the page.
  static func format(root: String, relative: String, text: String?, range: Range<Int>? = nil) -> Result<Outcome, CodeFormatter.Failure> {
    guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
      return .failure(.failed("That file isn't in the project."))
    }
    let file = (root as NSString).appendingPathComponent(relative)
    switch CodeFormatter.plan(for: file) {
    case nil:
      return .failure(.noFormatter("No formatter for \(CodeFormatter.languageName(for: file)) files."))
    case .prettier(let parser):
      let isExecutable = { (path: String) in FileManager.default.isExecutableFile(atPath: path) }
      if let text, let prettier = CodeFormatter.projectPrettier(file: file, root: root, isExecutable: isExecutable) {
        let folders = CodeFormatter.searchFolders(file: file, root: root, loginPath: loginPath, home: NSHomeDirectory())
        // It runs where it is installed: Prettier reads `.prettierignore` from its working folder.
        let project = ((prettier as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return CodeFormatter.run(executable: prettier, arguments: CodeFormatter.prettierArguments(for: file, range: range),
                                 text: text, directory: (project as NSString).deletingLastPathComponent,
                                 path: folders.joined(separator: ":"))
          .map { .formatted($0) }
          .mapError { failure in
            // "[error] /abs/path/a.ts: SyntaxError: …" → "prettier: SyntaxError: …"
            guard case .failed(let message) = failure else { return failure }
            return .failed(message.replacingOccurrences(of: "[error] \(file): ", with: "").replacingOccurrences(of: "[error] ", with: ""))
          }
      }
      let options = PrettierConfig.options(for: file) { module, folder in evaluate(module, folder: folder, root: root, file: file) }
      return .success(.prettier(parser: parser, options: options))
    case .tools(let tools):
      guard let text else { return .failure(.failed("Nothing to format.")) }
      let folders = CodeFormatter.searchFolders(file: file, root: root, loginPath: loginPath, home: NSHomeDirectory())
      let isExecutable = { (path: String) in FileManager.default.isExecutableFile(atPath: path) }
      guard let (tool, executable) = CodeFormatter.find(tools, in: folders, isExecutable: isExecutable) ?? xcodeTool(tools) else {
        return .failure(CodeFormatter.missing(tools, for: file))
      }
      return CodeFormatter.run(executable: executable, arguments: tool.arguments, text: text,
                               directory: directory(for: file, root: root), path: folders.joined(separator: ":")).map { .formatted($0) }
    }
  }

  /// Formatters run in the file's folder (where they look for their config), or the root for a file not saved yet.
  private static func directory(for file: String, root: String) -> String {
    let folder = (file as NSString).deletingLastPathComponent
    return FileManager.default.fileExists(atPath: folder) ? folder : root
  }

  /// Apple's swift-format ships with Xcode 16 and later, outside any PATH.
  private static func xcodeTool(_ tools: [CodeFormatter.Tool]) -> (CodeFormatter.Tool, String)? {
    guard let tool = tools.first(where: { $0.name == "swift-format" }) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--find", "swift-format"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: path) else { return nil }
    return (tool, path)
  }

  /// A JavaScript Prettier config (or a shared config package), loaded with the project's node.
  private static func evaluate(_ module: String, folder: String, root: String, file: String) -> [String: Any]? {
    let folders = CodeFormatter.searchFolders(file: file, root: root, loginPath: loginPath, home: NSHomeDirectory())
    guard let (_, node) = CodeFormatter.find([CodeFormatter.Tool(name: "node", arguments: [])], in: folders,
                                             isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
    let script = """
      const { createRequire } = require("module"); const { pathToFileURL } = require("url");
      const [module, folder] = process.argv.slice(1);
      const resolved = createRequire(folder + "/").resolve(module);
      import(pathToFileURL(resolved).href).then((m) => process.stdout.write(JSON.stringify(m.default ?? m)));
      """
    let result = CodeFormatter.run(executable: node, arguments: ["-e", script, module, folder], text: "", directory: folder,
                                   path: folders.joined(separator: ":"), timeout: 5)
    guard case .success(let json) = result else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
  }
}
