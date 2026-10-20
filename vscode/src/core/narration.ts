// Port of Sources/GlanceCore/Narration.swift: how a reply's narration lines up with its diagrams.
import { Block } from "./blocks";

/** Maps a spoken block index to the diagrams that draw while it is spoken. A diagram draws with the first prose
 * after it, or with the last prose before it when nothing follows. Key -1 holds diagrams with no prose at all. */
export function diagramAnchors(blocks: Block[], spokenBlocks: number[]): Map<number, number[]> {
  const anchors = new Map<number, number[]>();
  blocks.forEach((block, index) => {
    if (block.kind !== "mermaid") return;
    const after = spokenBlocks.find((s) => s > index);
    const before = [...spokenBlocks].reverse().find((s) => s < index);
    const anchor = after ?? before ?? -1;
    anchors.set(anchor, [...(anchors.get(anchor) ?? []), index]);
  });
  return anchors;
}

/** The paragraphs either side of `index`, which some voices use to keep intonation flowing across requests. */
export function speechContext(texts: string[], index: number): { previous: string | null; next: string | null } {
  return { previous: index > 0 ? texts[index - 1] : null, next: index + 1 < texts.length ? texts[index + 1] : null };
}
