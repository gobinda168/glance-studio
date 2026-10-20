import AppKit
import GlanceCore

/// The terminal's preferences in Settings (spec 2026-10-08-settings-design.md, "Terminal preferences"): read from
/// Glance's config file and written back one line at a time through `TerminalConfig`; after each write the terminal
/// reloads its config, so open terminals change at once.
@MainActor
final class TerminalSettingsModel: ObservableObject {
    static let shared = TerminalSettingsModel()

    static let defaultFamily = "JetBrains Mono"
    static let defaultSize = 13.0
    static let sizes = 8...32
    static let cursorStyles = ["block", "bar", "underline"]

    /// A write that failed: the row it came from, and why.
    struct Failure: Equatable {
        let row: String
        let message: String
    }

    @Published private(set) var config = TerminalConfig(text: "")
    /// The installed monospaced families, by name; the default isn't among them.
    @Published private(set) var families: [String] = []
    /// The bundled themes and the user's, by name.
    @Published private(set) var themes: [TerminalTheme] = []
    @Published private(set) var failure: Failure?
    private(set) var path: String?
    private var listed = false

    private init() {}

    // MARK: Reading

    /// Reads the file, which the terminal makes from the upstream one the first time (as Open Config does), and lists
    /// the fonts and themes once.
    func load() {
        guard let app = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        let path = app.configFilePath()
        guard !path.isEmpty else { return }
        self.path = path
        do {
            config = TerminalConfig(text: try Self.read(path))
        } catch {
            failure = Failure(row: "terminal.config", message: "Couldn't read \(Self.short(path)): \(error.localizedDescription)")
        }
        guard !listed else { return }
        listed = true
        families = Self.monospacedFamilies()
        DispatchQueue.global(qos: .userInitiated).async {
            let themes = Self.readThemes()
            DispatchQueue.main.async { MainActor.assumeIsolated { TerminalSettingsModel.shared.themes = themes } }
        }
    }

    /// The main font: the first `font-family` line; nil for the default.
    var fontFamily: String? { config.firstValue("font-family").flatMap { $0.isEmpty ? nil : $0 } }
    var fontSize: Double { config.value("font-size").flatMap(Double.init) ?? Self.defaultSize }
    /// The `theme` value as written (a name, or a light and dark pair); nil for Glance's colours.
    var theme: String? { config.value("theme").flatMap { $0.isEmpty ? nil : $0 } }
    var cursorStyle: String {
        config.value("cursor-style").flatMap { Self.cursorStyles.contains($0) ? $0 : nil } ?? "block"
    }
    var cursorBlink: Bool { config.value("cursor-style-blink").map { $0 != "false" } ?? true }

    /// The theme the terminal shows in `dark` or light appearance: a pair's half, or the one named.
    func shownTheme(dark: Bool) -> TerminalTheme? {
        guard let theme else { return nil }
        let name = Self.themeName(theme, dark: dark)
        return themes.first { $0.name == name }
    }

    /// A `theme` value's name for an appearance: `light:A,dark:B` gives A or B; a plain name is itself.
    static func themeName(_ value: String, dark: Bool) -> String {
        let prefix = dark ? "dark:" : "light:"
        for part in value.split(separator: ",") {
            let part = part.trimmingCharacters(in: .whitespaces)
            if part.hasPrefix(prefix) { return part.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
        }
        return value
    }

    // MARK: Writing

    /// Picks the main font; nil is the default. Fallback fonts (the later `font-family` lines) stay.
    func setFontFamily(_ family: String?) {
        write(row: "terminal.font") { config in
            if let family {
                config.set("font-family", family, first: true)
            } else if config.value("font-family") != config.firstValue("font-family") {
                config.set("font-family", Self.defaultFamily, first: true) // keep the fallbacks after it
            } else {
                config.remove("font-family")
            }
        }
    }

    func setFontSize(_ size: Double) {
        let size = min(max(size, Double(Self.sizes.lowerBound)), Double(Self.sizes.upperBound))
        write(row: "terminal.size") { $0.set("font-size", Self.format(size)) }
    }

    /// Picks a theme by name; nil is Glance's own colours.
    func setTheme(_ name: String?) {
        write(row: "terminal.theme") { config in
            if let name { config.set("theme", name) } else { config.remove("theme") }
        }
    }

    func setCursorStyle(_ style: String) {
        write(row: "terminal.cursor") { $0.set("cursor-style", style) }
    }

    func setCursorBlink(_ on: Bool) {
        write(row: "terminal.blink") { $0.set("cursor-style-blink", on ? "true" : "false") }
    }

    /// Changes the file as it is now (it may have been edited by hand since), writes it in place (a symlinked file
    /// stays a symlink), and reloads the terminal's config. A failure leaves the file and the rows as they were.
    private func write(row: String, _ change: (inout TerminalConfig) -> Void) {
        guard let path else { return }
        do {
            var fresh = TerminalConfig(text: try Self.read(path))
            change(&fresh)
            try fresh.text.write(toFile: path, atomically: false, encoding: .utf8)
            config = fresh
            failure = nil
            (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
        } catch {
            failure = Failure(row: row, message: "Couldn't save \(Self.short(path)): \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    /// The file's text; empty when it doesn't exist. A file that isn't UTF-8 is an error, so it's never overwritten.
    private static func read(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    static func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// "13", or "13.5".
    static func format(_ size: Double) -> String {
        size.rounded() == size ? String(Int(size)) : String(format: "%.1f", size)
    }

    private static func monospacedFamilies() -> [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
            .filter { !$0.hasPrefix(".") && $0 != defaultFamily }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The bundled themes, then the user's (`$XDG_CONFIG_HOME/ghostty/themes`, where the terminal looks), which win on
    /// a shared name.
    nonisolated private static func readThemes() -> [TerminalTheme] {
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL {
            directories.append(resources.appendingPathComponent("ghostty/themes"))
        }
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let config = xdg.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        directories.append(config.appendingPathComponent("ghostty/themes"))
        var byName: [String: TerminalTheme] = [:]
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where !file.lastPathComponent.hasPrefix(".") {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                byName[file.lastPathComponent] = TerminalTheme(name: file.lastPathComponent, text: text)
            }
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
