import AppKit
import Combine
import Darwin
import GlanceCore
import WebKit

/// Runs the VSCodium server behind the editor tabs: downloads it the first time, then starts it when the first editor
/// tab opens and stops it when the app quits. One server serves every editor tab.
@MainActor
final class EditorServerManager: ObservableObject {
    static let shared = EditorServerManager()

    enum State: Equatable {
        case idle
        case downloading(fraction: Double)
        case installing
        case starting
        case running(port: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The saved port was taken, so the editor moved and its saved UI state (settings, open files) stayed behind.
    @Published private(set) var portMoved = false
    private(set) var token = ""
    let paths = EditorServer.Paths(appSupport: EditorServerManager.appSupportDirectory())
    let downloadSize: Int64 = EditorServer.release(arch: EditorServerManager.machine())?.size ?? 0
    /// The first GS Code tab asks before downloading; the answer holds until the app quits.
    private(set) var downloadAgreed = false

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: paths.executable.path) }
    var needsDownloadConsent: Bool { !isInstalled && !downloadAgreed }

    private var process: Process?
    private var stopping = false
    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard
    private static let portKey = "editorServerPort"

    /// `~/Library/Application Support/Glance Studio`. The app was called Glance Terminal first; its folder (the
    /// 130 MB editor install, the editor's settings) moves over once instead of being downloaded again.
    private static func appSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent("Glance Studio")
        let previous = base.appendingPathComponent("Glance Terminal")
        if !FileManager.default.fileExists(atPath: current.path), FileManager.default.fileExists(atPath: previous.path) {
            try? FileManager.default.moveItem(at: previous, to: current)
        }
        return current
    }

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EditorServerManager.shared.stop() }
        }
    }

    /// Starts the server unless it is running or already on its way; every editor tab waits for the same start.
    func ensureRunning() {
        switch state {
        case .running, .downloading, .installing, .starting: return
        case .idle, .failed: break
        }
        state = .starting
        Task { await start() }
    }

    func restart() {
        stop()
        state = .idle
        ensureRunning()
    }

    func acknowledgePortMoved() { portMoved = false }

    func agreeToDownload() { downloadAgreed = true }

    /// SIGTERM now and SIGKILL after 3 s. At quit the app may be gone before the kill: the next launch cleans up
    /// (`killLeftoverServer`).
    func stop() {
        guard let process, process.isRunning else { return }
        stopping = true
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
    }

    // MARK: Start

    private func start() async {
        do {
            try await installIfNeeded()
            try await patchPageIfNeeded()
            try await installGlanceExtensionIfNeeded()
            try await launch()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func installIfNeeded() async throws {
        let fm = FileManager.default
        if isInstalled { return }
        guard let release = EditorServer.release(arch: Self.machine()) else {
            throw EditorError("The editor isn't available for this Mac's processor.")
        }
        state = .downloading(fraction: 0)
        let archive = try await EditorDownload.download(release.url) { [weak self] fraction in
            self?.state = .downloading(fraction: fraction)
        }
        defer { try? fm.removeItem(at: archive) }
        state = .installing
        let digest = try await Task.detached { try EditorServer.sha256(of: archive) }.value
        guard digest == release.sha256 else {
            throw EditorError("The editor download was damaged (its checksum doesn't match). Try again.")
        }
        try? fm.removeItem(at: paths.staging)
        try fm.createDirectory(at: paths.staging, withIntermediateDirectories: true)
        _ = try await EditorProcess.run("/usr/bin/tar", ["-xzf", archive.path, "-C", paths.staging.path])
        let productURL = paths.staging.appendingPathComponent("product.json")
        let product = (try JSONSerialization.jsonObject(with: Data(contentsOf: productURL)) as? [String: Any]) ?? [:]
        try JSONSerialization.data(withJSONObject: EditorServer.patchedProduct(product), options: [.prettyPrinted])
            .write(to: productURL, options: .atomic)
        try fm.moveItem(at: paths.staging, to: paths.install)
        // Older versions go once this one is in place.
        for item in (try? fm.contentsOfDirectory(at: paths.base, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.first?.isNumber == true && item.lastPathComponent != EditorServer.version {
            try? fm.removeItem(at: item)
        }
    }

    /// Renames VSCodium to GS Code in the page's own files and takes out New Window, once per install (and
    /// again when the patch changes). The web view may have cached the old files, so its cache goes too; settings and
    /// backups stay.
    private func patchPageIfNeeded() async throws {
        let stamp = paths.install.appendingPathComponent(".glance-page-patch")
        if (try? String(contentsOf: stamp, encoding: .utf8)) == EditorServer.pagePatchRevision { return }
        let install = paths.install
        try await Task.detached {
            func patch(_ file: String, _ transform: (String) -> String) throws {
                let url = install.appendingPathComponent(file)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                let branded = transform(text)
                if branded != text { try branded.write(to: url, atomically: true, encoding: .utf8) }
            }
            try patch(EditorServer.workbenchFile, EditorServer.patchedWorkbench)
            for file in EditorServer.messageFiles { try patch(file, EditorServer.brandedMessages) }
        }.value
        await WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast)
        try EditorServer.pagePatchRevision.write(to: stamp, atomically: true, encoding: .utf8)
    }

    /// The Glance extension inside the app, installed when the app's copy changed since the last install.
    private func installGlanceExtensionIfNeeded() async throws {
        guard let vsix = Bundle.main.url(forResource: "GlanceExtension", withExtension: "vsix") else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: vsix.path)
        let stamp = "\(attributes[.size] as? Int ?? 0)-\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let stampFile = paths.extensions.appendingPathComponent(".glance-vsix")
        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp { return }
        state = .installing
        _ = try await EditorProcess.run(paths.executable.path, EditorServer.installExtensionArguments(paths: paths, vsix: vsix))
        try FileManager.default.createDirectory(at: paths.extensions, withIntermediateDirectories: true)
        try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
    }

    private func launch() async throws {
        state = .starting
        token = try loadToken()
        await killLeftoverServer()
        let saved = Self.defaults.object(forKey: Self.portKey) as? Int
        guard let choice = EditorServer.choosePort(saved: saved, isFree: Self.isPortFree) else {
            throw EditorError("No free port for the editor between 47900 and 47999.")
        }
        portMoved = choice.moved
        Self.defaults.set(choice.port, forKey: Self.portKey)

        try EditorBridgeServer.shared.start(socket: paths.bridgeSocket)
        let loginPath = try? await EditorProcess.run(
            "/bin/zsh", ["-lic", "printf '\(EditorServer.pathMarker)%s\(EditorServer.pathMarker)' \"$PATH\""], timeout: 5)
        let environment = EditorServer.environment(base: ProcessInfo.processInfo.environment,
                                                   path: loginPath.flatMap(EditorServer.pathFromShellOutput),
                                                   bridge: paths.bridgeSocket.path)

        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let logURL = paths.logs.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = paths.executable
        process.arguments = EditorServer.arguments(paths: paths, port: choice.port)
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { _ in Task { @MainActor in EditorServerManager.shared.processEnded() } }
        try process.run()
        self.process = process
        try? String(process.processIdentifier).write(to: paths.pidFile, atomically: true, encoding: .utf8)
        try await waitUntilReady(port: choice.port, log: logURL)
        state = .running(port: choice.port)
    }

    private func waitUntilReady(port: Int, log: URL) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/version")!
        for _ in 0..<120 {
            guard process?.isRunning == true else {
                throw EditorError("The editor stopped while starting. Its log is at \(log.path).")
            }
            if let (_, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw EditorError("The editor didn't start within 30 seconds. Its log is at \(log.path).")
    }

    private func processEnded() {
        process = nil
        try? FileManager.default.removeItem(at: paths.pidFile)
        if stopping {
            stopping = false
            if case .running = state { state = .idle }
            return
        }
        state = .failed("The editor stopped. Restart it to carry on; unsaved changes come back.")
    }

    // MARK: Helpers

    private func loadToken() throws -> String {
        if let saved = try? String(contentsOf: paths.token, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count >= 64 { return saved }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw EditorError("Couldn't make the editor's access token.")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: paths.base, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: paths.token)
        guard FileManager.default.createFile(atPath: paths.token.path, contents: Data(token.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw EditorError("Couldn't save the editor's access token.")
        }
        return token
    }

    /// A server left running by a crash keeps the saved port, and moving to another port would lose the user's
    /// settings. Stop it first, if the pid file still names our server.
    private func killLeftoverServer() async {
        guard let text = try? String(contentsOf: paths.pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 else { return }
        let command = (try? await EditorProcess.run("/bin/ps", ["-o", "command=", "-p", String(pid)], timeout: 3)) ?? ""
        guard command.contains(paths.install.path) || command.contains(paths.base.path) else { return }
        kill(pid, SIGTERM)
        for _ in 0..<20 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    nonisolated private static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    nonisolated static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}
