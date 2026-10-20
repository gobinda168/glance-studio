// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Glance",
  platforms: [.macOS(.v15)],
  products: [
    // The `glance` command line helper that ships in Glance Studio's bundle: hook setup and the debug commands.
    .executable(name: "glance", targets: ["GlanceCLI"]),
    // The Glance engine and panel, for the overlay and Glance Studio (the Ghostty fork in terminal/).
    .library(name: "GlanceKit", targets: ["GlanceKit", "GlanceCore", "GlanceOverlay"]),
  ],
  dependencies: [
    // Kokoro-82M on Core ML (on-device narration). GlanceKit only; GlanceCore stays dependency-free.
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
  ],
  targets: [
    // Pure logic: transcript parsing, markdown blocks, speech text, HTTP, hook setup, dock geometry.
    .target(name: "GlanceCore"),
    // The Glance engine and panel: session, web content, narration and voices, dictation, settings, transcript watching.
    // It doesn't decide how the panel gets on screen; the app hosting it does.
    .target(
      name: "GlanceKit",
      dependencies: ["GlanceCore", .product(name: "FluidAudio", package: "FluidAudio")],
      // Swift 5 mode: Swift 6 traps at run time when AppKit/AVFAudio call a main-actor closure off the main thread.
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // The overlay: docking, the editor orb, the menu-bar item, hot keys, the hook event server (the host runs it). Hosted by Glance Studio.
    // No Sparkle: the host owns updates.
    .target(
      name: "GlanceOverlay",
      dependencies: ["GlanceCore", "GlanceKit"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // `glance`: setup of the hooks and status line, and the debug commands, bundled in Glance Studio.
    .executableTarget(
      name: "GlanceCLI",
      dependencies: ["GlanceCore", "GlanceKit"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(name: "GlanceCoreTests", dependencies: ["GlanceCore"]),
  ]
)
