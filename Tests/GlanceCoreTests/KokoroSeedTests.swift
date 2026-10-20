import Foundation
import Testing
@testable import GlanceCore

@Suite struct KokoroSeedTests {
  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-seed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ text: String, _ path: String, in root: URL) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func read(_ path: String, in root: URL) -> String? {
    (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
  }

  @Test func copiesOnlyMissingFiles() throws {
    let bundle = try tempDir(), cache = try tempDir()
    try write("albert", "kokoro-82m-coreml/ANE/KokoroAlbert.mlmodelc/model.mil", in: bundle)
    try write("heart", "kokoro-82m-coreml/ANE/af_heart.bin", in: bundle)
    try write("vocab-bundle", "kokoro-82m-coreml/ANE/vocab.json", in: bundle)
    try write("vocab-cache!", "kokoro-82m-coreml/ANE/vocab.json", in: cache)   // same size: a complete copy

    #expect(KokoroSeed.missing(bundle: bundle, cache: cache)
      == ["kokoro-82m-coreml/ANE/KokoroAlbert.mlmodelc/model.mil", "kokoro-82m-coreml/ANE/af_heart.bin"])
    #expect(try KokoroSeed.seed(bundle: bundle, cache: cache) == 2)
    #expect(read("kokoro-82m-coreml/ANE/KokoroAlbert.mlmodelc/model.mil", in: cache) == "albert")
    #expect(read("kokoro-82m-coreml/ANE/af_heart.bin", in: cache) == "heart")
    #expect(read("kokoro-82m-coreml/ANE/vocab.json", in: cache) == "vocab-cache!")   // complete files are kept
  }

  @Test func secondSeedCopiesNothing() throws {
    let bundle = try tempDir(), cache = try tempDir()
    try write("x", "kokoro-82m-coreml/g2p/vocab.json", in: bundle)
    #expect(try KokoroSeed.seed(bundle: bundle, cache: cache) == 1)
    #expect(try KokoroSeed.seed(bundle: bundle, cache: cache) == 0)
  }

  @Test func replacesAFileCutShortByAnInterruptedCopy() throws {
    let bundle = try tempDir(), cache = try tempDir()
    try write("full voice pack", "kokoro-82m-coreml/ANE/af_heart.bin", in: bundle)
    try write("full voi", "kokoro-82m-coreml/ANE/af_heart.bin", in: cache)
    #expect(KokoroSeed.missing(bundle: bundle, cache: cache) == ["kokoro-82m-coreml/ANE/af_heart.bin"])
    #expect(try KokoroSeed.seed(bundle: bundle, cache: cache) == 1)
    #expect(read("kokoro-82m-coreml/ANE/af_heart.bin", in: cache) == "full voice pack")
  }

  @Test func copiesThroughAStagingFileAndClearsAStaleOne() throws {
    let bundle = try tempDir(), cache = try tempDir()
    try write("heart", "kokoro-82m-coreml/ANE/af_heart.bin", in: bundle)
    try write("he", "kokoro-82m-coreml/ANE/af_heart.bin.partial", in: cache)   // left by a copy that died
    #expect(try KokoroSeed.seed(bundle: bundle, cache: cache) == 1)
    #expect(read("kokoro-82m-coreml/ANE/af_heart.bin", in: cache) == "heart")
    #expect(read("kokoro-82m-coreml/ANE/af_heart.bin.partial", in: cache) == nil)
  }

  @Test func missingBundleThrowsWithAHint() throws {
    let cache = try tempDir()
    let bundle = cache.appendingPathComponent("nope")
    #expect(throws: KokoroSeedError.missingBundle(bundle.path)) { try KokoroSeed.seed(bundle: bundle, cache: cache) }
    #expect(KokoroSeedError.missingBundle("/x").errorDescription?.contains("scripts/build.sh") == true)
  }
}
