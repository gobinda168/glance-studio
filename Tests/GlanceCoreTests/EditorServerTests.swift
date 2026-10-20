import Foundation
import Testing
@testable import GlanceCore

private let paths = EditorServer.Paths(appSupport: URL(fileURLWithPath: "/Users/u/Library/Application Support/Glance Studio"))

@Test func pinsOneReleasePerMacArchitecture() throws {
  let arm = try #require(EditorServer.release(arch: "arm64"))
  #expect(arm.url.absoluteString == "https://github.com/VSCodium/vscodium/releases/download/1.135.06055/vscodium-reh-web-darwin-arm64-1.135.06055.tar.gz")
  #expect(arm.sha256 == "87ffebc1df7bde31b9e863d38fa6121cdebe3e5f9794d65f95f062f986dcfa73")
  #expect(arm.size == 130_799_447)
  let intel = try #require(EditorServer.release(arch: "x86_64"))
  #expect(intel.url.lastPathComponent == "vscodium-reh-web-darwin-x64-1.135.06055.tar.gz")
  #expect(intel.sha256 == "b0038f4ae482d6454bb293ae5b04d4af0834f8c7094f95dfeec3c6519d9fcb74")
  #expect(EditorServer.release(arch: "i386") == nil)
}

@Test func laysOutItsFilesUnderApplicationSupport() {
  #expect(paths.install.path == "/Users/u/Library/Application Support/Glance Studio/editor-server/1.135.06055")
  #expect(paths.staging.path.hasSuffix("editor-server/1.135.06055.partial"))
  #expect(paths.executable.path.hasSuffix("editor-server/1.135.06055/bin/codium-server"))
  #expect(paths.extensions.path.hasSuffix("editor-server/data/extensions"))
  #expect(paths.token.path.hasSuffix("editor-server/token"))
  #expect(paths.pidFile.path.hasSuffix("editor-server/server.pid"))
  #expect(paths.bridgeSocket.path == "/Users/u/Library/Application Support/Glance Studio/editor-bridge.sock")
}

@Test func startsOnLoopbackWithATokenFile() {
  let args = EditorServer.arguments(paths: paths, port: 47901)
  #expect(args.starts(with: ["--host", "127.0.0.1", "--port", "47901"]))
  #expect(args.contains("--accept-server-license-terms"))
  func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
  #expect(value("--connection-token-file") == paths.token.path)
  #expect(value("--extensions-dir") == paths.extensions.path)
  #expect(value("--server-data-dir") == paths.data.appendingPathComponent("server").path)
  #expect(value("--user-data-dir") == paths.data.appendingPathComponent("user").path)
  #expect(value("--reconnection-grace-time") == "30")
  #expect(value("--telemetry-level") == "off")
  #expect(!args.contains("0.0.0.0") && !args.contains("--without-connection-token"))
}

@Test func installsExtensionsIntoTheServersFolders() {
  let vsix = URL(fileURLWithPath: "/App/Contents/Resources/GlanceExtension.vsix")
  let args = EditorServer.installExtensionArguments(paths: paths, vsix: vsix)
  #expect(args.starts(with: ["--install-extension", vsix.path, "--force"]))
  #expect(args.contains(paths.extensions.path))
}

@Test func encodesTheFolderSoVSCodeOpensTheRightOne() throws {
  let url = EditorServer.workbenchURL(port: 47900, token: "abc123", root: "/Users/u/My Code/a&b #1/é")
  #expect(url.host == "127.0.0.1" && url.port == 47900 && url.scheme == "http")
  let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
  #expect(items.count == 2)
  #expect(items.first { $0.name == "tkn" }?.value == "abc123")
  #expect(items.first { $0.name == "folder" }?.value == "/Users/u/My Code/a&b #1/é")
}

@Test func onlyTheServersOwnPagesStayInTheEditor() {
  #expect(EditorServer.isWorkbench(URL(string: "http://127.0.0.1:47900/stable-x/static/out/x.js")!, port: 47900))
  #expect(EditorServer.isWorkbench(URL(string: "blob:http://127.0.0.1:47900/1234")!, port: 47900))
  #expect(EditorServer.isWorkbench(URL(string: "about:blank")!, port: 47900))
  #expect(!EditorServer.isWorkbench(URL(string: "http://127.0.0.1:47901/")!, port: 47900))
  #expect(!EditorServer.isWorkbench(URL(string: "https://open-vsx.org/extension/x")!, port: 47900))
  #expect(!EditorServer.isWorkbench(URL(string: "http://127.0.0.1:47900/")!, port: nil))
}

@Test func renamesTheProductAndTurnsTelemetryOff() {
  let product: [String: Any] = ["nameShort": "VSCodium", "nameLong": "VSCodium", "applicationName": "codium", "commit": "abc"]
  let patched = EditorServer.patchedProduct(product)
  #expect(patched["nameShort"] as? String == "GS Code")
  #expect(patched["nameLong"] as? String == "GS Code")
  #expect(patched["enableTelemetry"] as? Bool == false)
  #expect(patched["applicationName"] as? String == "codium") // the server's own CLI and folders use it
  #expect(patched["commit"] as? String == "abc")
}

@Test func renamesTheWorkbenchsBuiltInProduct() {
  let js = #"else nm={nameShort:"VSCodium",nameLong:"VSCodium",applicationName:"codium",win32DirName:"VSCodium"}"#
  #expect(EditorServer.patchedWorkbench(js)
    == #"else nm={nameShort:"GS Code",nameLong:"GS Code",applicationName:"codium",win32DirName:"VSCodium"}"#)
}

@Test func renamesAWorkbenchPatchedWhenTheEditorWasCalledGlanceCode() {
  let js = #"else nm={nameShort:"Glance Code",nameLong:"Glance Code",applicationName:"codium"}"#
  #expect(EditorServer.patchedWorkbench(js) == #"else nm={nameShort:"GS Code",nameLong:"GS Code",applicationName:"codium"}"#)
  #expect(EditorServer.brandedMessages(#"["Please restart Glance Code"]"#) == #"["Please restart GS Code"]"#)
}

@Test func renamesAWorkbenchPatchedWhenTheEditorWasCalledGlanceStudio() {
  let js = #"else nm={nameShort:"Glance Studio",nameLong:"Glance Studio",applicationName:"codium"}"#
  #expect(EditorServer.patchedWorkbench(js) == #"else nm={nameShort:"GS Code",nameLong:"GS Code",applicationName:"codium"}"#)
  #expect(EditorServer.brandedMessages(#"["Please restart Glance Studio"]"#) == #"["Please restart GS Code"]"#)
}

@Test func takesNewWindowOutOfTheMenusPaletteAndKeys() {
  let js = #"bOn=class extends U{constructor(){super({id:"workbench.action.newWindow",title:{...M(5896,"New Window"),mnemonicTitle:d(5888,null)},f1:!0,keybinding:{weight:200,primary:Qt?ss?Ki(2089,1068):3628:3116,secondary:Qt?[3116]:void 0},menu:{id:T.MenubarFileMenu,group:"1_new",order:3}})}run(i){"#
  #expect(EditorServer.patchedWorkbench(js)
    == #"bOn=class extends U{constructor(){super({id:"workbench.action.newWindow",title:{...M(5896,"New Window"),mnemonicTitle:d(5888,null)},f1:!1})}run(i){"#)
}

@Test func renamesTheMessagesButNotTheirLinks() {
  let messages = #"["Quality type of VSCodium","Please restart VSCodium before reinstalling {0}.","<a href=\"https://github.com/VSCodium/vscodium/wiki\">"]"#
  #expect(EditorServer.brandedMessages(messages)
    == #"["Quality type of GS Code","Please restart GS Code before reinstalling {0}.","<a href=\"https://github.com/VSCodium/vscodium/wiki\">"]"#)
}

@Test func keepsTheSavedPortWhenItIsFree() {
  #expect(EditorServer.choosePort(saved: 47905, isFree: { _ in true }) == .init(port: 47905, moved: false))
}

@Test func movesToTheNextFreePortWhenTheSavedOneIsTaken() {
  let choice = EditorServer.choosePort(saved: 47900, isFree: { $0 != 47900 && $0 != 47901 })
  #expect(choice == .init(port: 47902, moved: true))
}

@Test func firstLaunchTakesTheFirstFreePortWithoutCallingItAMove() {
  #expect(EditorServer.choosePort(saved: nil, isFree: { $0 >= 47903 }) == .init(port: 47903, moved: false))
  #expect(EditorServer.choosePort(saved: 12345, isFree: { _ in true }) == .init(port: 47900, moved: true))
  #expect(EditorServer.choosePort(saved: nil, isFree: { _ in false }) == nil)
}

@Test func hashesAFileInChunks() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try Data("abc".utf8).write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  #expect(try EditorServer.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func givesTheServerTheLoginPathAndTheBridge() {
  let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/u", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli"]
  let env = EditorServer.environment(base: base, path: "/opt/homebrew/bin:/usr/bin", bridge: "/tmp/b.sock")
  #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin")
  #expect(env["HOME"] == "/Users/u")
  #expect(env["GLANCE_BRIDGE"] == "/tmp/b.sock")
  #expect(env["CLAUDECODE"] == nil && env["CLAUDE_CODE_ENTRYPOINT"] == nil)
  let withMods = EditorServer.environment(base: base.merging(["CLAUDE_CODE_PLUGIN_DIRS": "/m/a"]) { $1 }, path: nil, bridge: "/b")
  #expect(withMods["CLAUDE_CODE_PLUGIN_DIRS"] == "/m/a")
  #expect(EditorServer.environment(base: base, path: nil, bridge: "/b")["PATH"] == "/usr/bin:/bin")
}

@Test func readsThePathBetweenMarkersDespiteShellNoise() {
  let m = EditorServer.pathMarker
  #expect(EditorServer.pathFromShellOutput("Last login: today\n\(m)/opt/homebrew/bin:/usr/bin\(m)\n") == "/opt/homebrew/bin:/usr/bin")
  #expect(EditorServer.pathFromShellOutput("no markers here") == nil)
  #expect(EditorServer.pathFromShellOutput("\(m)\(m)") == nil)
}
