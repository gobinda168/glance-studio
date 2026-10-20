import Foundation
import Testing
@testable import GlanceCore

@Test func recordsOnlyTheDroppedImages() throws {
  let data = try #require(ImageDrops.record(paths: ["/a/shot.PNG", "/a/notes.txt", "/a/photo.jpeg"], at: Date(timeIntervalSince1970: 100)))
  let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(json["at"] as? Double == 100)
  #expect(json["paths"] as? [String] == ["/a/shot.PNG", "/a/photo.jpeg"])
  #expect(ImageDrops.record(paths: ["/a/notes.txt"], at: Date()) == nil)
}

@Test func savesWhereTheModLooks() throws {
  let caches = FileManager.default.temporaryDirectory.appendingPathComponent("caches-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: caches) }
  ImageDrops.save(paths: ["/a/b.png"], caches: caches, now: Date(timeIntervalSince1970: 5))
  let url = caches.appendingPathComponent("Glance Studio/image-drops.json")
  #expect(try String(contentsOf: url, encoding: .utf8) == #"{"at":5,"paths":["\/a\/b.png"]}"#)
}
