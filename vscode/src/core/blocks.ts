// Port of Sources/GlanceCore/Blocks.swift: one top-level markdown block per entry, so the panel can render and
// narrate a reply block by block.

export type BlockKind = "paragraph" | "heading" | "list" | "quote" | "code" | "mermaid" | "table" | "rule";

export interface Block {
  kind: BlockKind;
  /** The block's markdown; for code and mermaid blocks, the fence's contents only. */
  markdown: string;
  /** The fence's info string (first word), for code blocks. */
  lang?: string;
}

const trimSpaces = (s: string) => s.replace(/^[ \t]+|[ \t]+$/g, "");

export function splitBlocks(markdown: string): Block[] {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const blocks: Block[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const trimmed = trimSpaces(line);
    const fence = fenceMarker(trimmed);
    if (!trimmed) {
      i += 1;
    } else if (fence) {
      const lang = trimSpaces(trimmed.slice(fence.length)).split(" ").filter(Boolean)[0];
      const body: string[] = [];
      i += 1;
      while (i < lines.length && !closesFence(lines[i], fence)) body.push(lines[i++]);
      i += 1; // closing fence
      const isMermaid = lang?.toLowerCase() === "mermaid";
      const block: Block = { kind: isMermaid ? "mermaid" : "code", markdown: body.join("\n") };
      if (!isMermaid && lang) block.lang = lang;
      blocks.push(block);
    } else if (isHeading(trimmed)) {
      blocks.push({ kind: "heading", markdown: trimmed });
      i += 1;
    } else if (isRule(trimmed)) {
      blocks.push({ kind: "rule", markdown: trimmed });
      i += 1;
    } else if (trimmed.startsWith("|")) {
      const end = runEnd(lines, i, (l) => trimSpaces(l).startsWith("|"));
      blocks.push({ kind: "table", markdown: lines.slice(i, end).join("\n") });
      i = end;
    } else if (trimmed.startsWith(">")) {
      const end = runEnd(lines, i, (l) => trimSpaces(l).startsWith(">"));
      blocks.push({ kind: "quote", markdown: lines.slice(i, end).join("\n") });
      i = end;
    } else if (isListItem(line)) {
      let end = i + 1;
      while (end < lines.length) {
        const next = lines[end];
        if (isListItem(next) || ((next[0] === " " || next[0] === "\t") && trimSpaces(next) !== "")) {
          end += 1;
        } else if (trimSpaces(next) === "" && end + 1 < lines.length && isListItem(lines[end + 1])) {
          end += 1;
        } else {
          break;
        }
      }
      blocks.push({ kind: "list", markdown: lines.slice(i, end).join("\n") });
      i = end;
    } else {
      let end = i + 1;
      while (end < lines.length && startsParagraphContinuation(lines[end])) end += 1;
      blocks.push({ kind: "paragraph", markdown: lines.slice(i, end).join("\n") });
      i = end;
    }
  }
  return blocks;
}

function fenceMarker(trimmed: string): string | null {
  for (const char of ["`", "~"]) {
    if (trimmed.startsWith(char.repeat(3))) {
      let n = 0;
      while (trimmed[n] === char) n += 1;
      return char.repeat(n);
    }
  }
  return null;
}

function closesFence(line: string, fence: string): boolean {
  const trimmed = trimSpaces(line);
  return trimmed.startsWith(fence) && [...trimmed].every((c) => c === fence[0]);
}

function isHeading(trimmed: string): boolean {
  let hashes = 0;
  while (trimmed[hashes] === "#") hashes += 1;
  return hashes >= 1 && hashes <= 6 && trimmed[hashes] === " ";
}

function isRule(trimmed: string): boolean {
  const compact = trimmed.replace(/ /g, "");
  if (compact.length < 3 || !"-*_".includes(compact[0])) return false;
  return [...compact].every((c) => c === compact[0]);
}

export function isListItem(line: string): boolean {
  const trimmed = line.replace(/^ +/, "");
  if (trimmed && "-*+".includes(trimmed[0])) return trimmed[1] === " ";
  const digits = /^[0-9]*/.exec(trimmed)![0];
  if (!digits || digits.length > 9) return false;
  const rest = trimmed.slice(digits.length);
  return (rest[0] === "." || rest[0] === ")") && rest[1] === " ";
}

function startsParagraphContinuation(line: string): boolean {
  const trimmed = trimSpaces(line);
  return trimmed !== "" && fenceMarker(trimmed) === null && !isHeading(trimmed) && !isRule(trimmed)
    && !trimmed.startsWith("|") && !trimmed.startsWith(">") && !isListItem(line);
}

function runEnd(lines: string[], start: number, matches: (line: string) => boolean): number {
  let end = start;
  while (end < lines.length && matches(lines[end])) end += 1;
  return end;
}
