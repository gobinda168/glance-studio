import Testing
@testable import GlanceCore

private func blocks(_ kinds: [Block.Kind]) -> [Block] { kinds.map { Block(kind: $0, markdown: "x") } }

@Test func diagramsDrawWithTheProseThatFollowsThem() {
  let reply = blocks([.paragraph, .mermaid, .paragraph, .code, .mermaid, .paragraph])
  #expect(Narration.diagramAnchors(blocks: reply, spokenBlocks: [0, 2, 5]) == [2: [1], 5: [4]])
}

@Test func trailingDiagramsDrawWithTheLastProse() {
  let reply = blocks([.paragraph, .mermaid, .mermaid])
  #expect(Narration.diagramAnchors(blocks: reply, spokenBlocks: [0]) == [0: [1, 2]])
}

@Test func diagramsWithoutProseHaveNoAnchor() {
  #expect(Narration.diagramAnchors(blocks: blocks([.mermaid]), spokenBlocks: []) == [-1: [0]])
}

@Test func contextIsTheNeighbouringParagraphs() {
  let texts = ["One.", "Two.", "Three."]
  #expect(Narration.context(texts: texts, index: 0) == SpeechContext(previous: nil, next: "Two."))
  #expect(Narration.context(texts: texts, index: 1) == SpeechContext(previous: "One.", next: "Three."))
  #expect(Narration.context(texts: texts, index: 2) == SpeechContext(previous: "Two.", next: nil))
  #expect(Narration.context(texts: ["Only."], index: 0) == SpeechContext(previous: nil, next: nil))
}
