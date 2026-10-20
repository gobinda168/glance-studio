/// How a reply's narration lines up with its diagrams.
public enum Narration {
  /// Maps a spoken block index to the diagrams that draw while it is spoken. A diagram draws with the
  /// first prose after it (the voice "arrives" at the picture and explains it), or with the last prose
  /// before it when nothing follows. Key -1 holds diagrams with no prose at all.
  public static func diagramAnchors(blocks: [Block], spokenBlocks: [Int]) -> [Int: [Int]] {
    var anchors: [Int: [Int]] = [:]
    for (index, block) in blocks.enumerated() where block.kind == .mermaid {
      let anchor = spokenBlocks.first { $0 > index } ?? spokenBlocks.last { $0 < index } ?? -1
      anchors[anchor, default: []].append(index)
    }
    return anchors
  }

  /// The paragraphs either side of `index`, which some voices use to keep intonation flowing across requests.
  public static func context(texts: [String], index: Int) -> SpeechContext {
    SpeechContext(previous: index > 0 ? texts[index - 1] : nil,
                  next: index + 1 < texts.count ? texts[index + 1] : nil)
  }
}

public struct SpeechContext: Equatable, Sendable {
  public let previous: String?
  public let next: String?

  public init(previous: String?, next: String?) {
    self.previous = previous
    self.next = next
  }
}
