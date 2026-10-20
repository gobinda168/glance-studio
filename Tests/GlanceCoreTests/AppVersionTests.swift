import Testing
@testable import GlanceCore

@Test func aStampedBuildShowsVersionBuildAndCommit() {
  let version = AppVersion(info: ["GlanceVersion": "0.1.0", "GlanceBuild": "151", "GlanceCommit": "f53fb74"])
  #expect(version.short == "0.1.0 (151)")
  #expect(version.full == "0.1.0 (151, f53fb74)")
}

@Test func theGlanceKeysWinOverTheBundlesOwn() {
  // Glance Studio keeps Ghostty's CFBundle versions; Glance's own are stamped beside them.
  let version = AppVersion(info: ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "9000",
                                  "GlanceVersion": "0.1.0", "GlanceBuild": "151"])
  #expect(version.full == "0.1.0 (151)")
}

@Test func anUnstampedBundleFallsBackToItsCFBundleVersions() {
  let version = AppVersion(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"])
  #expect(version.full == "0.1.0 (1)")
}

@Test func aDevelopmentBuildIsStampedSoAnythingElseCountsAsARelease() {
  #expect(AppVersion(info: ["GlanceVersion": "0.1.0", "GlanceDevelopment": "1"]).isDevelopment)
  #expect(!AppVersion(info: ["GlanceVersion": "0.1.0", "GlanceBuild": "151"]).isDevelopment)
  #expect(!AppVersion(info: ["GlanceDevelopment": "0"]).isDevelopment)
  #expect(!AppVersion(info: nil).isDevelopment)
}

@Test func noBundleIsADevBuild() {
  #expect(AppVersion(info: [:]).short == "dev")
  #expect(AppVersion(info: nil).full == "dev")
  #expect(AppVersion(info: ["GlanceVersion": "0.1.0"]).full == "0.1.0")
}
