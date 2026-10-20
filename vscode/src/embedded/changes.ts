// Claude's changed lines as Glance Studio sends them, and the F7 order through them.

export interface ChangeMark {
  /** 1-based, inclusive. A deleted mark is the line the deletion sits above. */
  start: number;
  end: number;
  kind: "added" | "modified" | "deleted";
}

export interface MarkPosition {
  path: string;
  line: number;
}

/** Every mark's first line, ordered by path, then line. */
export function markPositions(files: Record<string, ChangeMark[]>): MarkPosition[] {
  const out: MarkPosition[] = [];
  for (const path of Object.keys(files).sort()) {
    for (const line of files[path].map((m) => m.start).sort((a, b) => a - b)) out.push({ path, line });
  }
  return out;
}

/** The next (1) or previous (-1) mark from `here`, across files, wrapping around. Undefined without marks. */
export function nextMark(list: MarkPosition[], here: MarkPosition | undefined, direction: 1 | -1): MarkPosition | undefined {
  if (!list.length) return undefined;
  if (!here) return direction > 0 ? list[0] : list[list.length - 1];
  const compare = (a: MarkPosition, b: MarkPosition) => (a.path === b.path ? a.line - b.line : a.path < b.path ? -1 : 1);
  const found = direction > 0 ? list.find((p) => compare(p, here) > 0) : [...list].reverse().find((p) => compare(p, here) < 0);
  return found ?? (direction > 0 ? list[0] : list[list.length - 1]);
}
