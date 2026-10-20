// Inline Ask's diff in GS Code, without VS Code: Claude's new lines go in below the selected ones, the old ones
// in red and the new ones in green until Accept (the old lines go) or Reject (the new lines go). Lines are 1-based and
// inclusive unless a name says otherwise.

export interface Pending {
  oldStart: number;
  oldEnd: number;
  newStart: number;
  newEnd: number;
}

/** True when the selected lines no longer read as they did when the question was asked (`current` undefined: they
 *  are gone). */
export function isStale(current: string | undefined, original: string): boolean {
  return current !== original;
}

/** The diff once `replacement` is inserted after line `end`. */
export function pendingFor(start: number, end: number, replacement: string): Pending {
  const count = replacement.split("\n").length;
  return { oldStart: start, oldEnd: end, newStart: end + 1, newEnd: end + count };
}

export interface ZeroRange {
  startLine: number;
  startCharacter: number;
  endLine: number;
  endCharacter: number;
}

/** The range (0-based, as VS Code's) that deletes lines a..b with the line break that goes with them. */
export function lineDeletion(a: number, b: number, lineCount: number, lengthOf: (line0: number) => number): ZeroRange {
  if (b < lineCount) return { startLine: a - 1, startCharacter: 0, endLine: b, endCharacter: 0 };
  if (a > 1) return { startLine: a - 2, startCharacter: lengthOf(a - 2), endLine: b - 1, endCharacter: lengthOf(b - 1) };
  return { startLine: 0, startCharacter: 0, endLine: b - 1, endCharacter: lengthOf(b - 1) };
}

export interface LineChange {
  /** The changed range's first and last line, before the change. */
  startLine: number;
  endLine: number;
  /** Lines added (positive) or removed (negative) by it. */
  lineDelta: number;
}

/** The diff after the user's own edit: shifted by an edit above it, unchanged by one below it. An edit inside the
 *  new lines accepts them; inside the old lines it keeps those (reject). */
export function afterChange(pending: Pending, change: LineChange): Pending | "accept" | "reject" {
  if (change.endLine < pending.oldStart) {
    const d = change.lineDelta;
    return { oldStart: pending.oldStart + d, oldEnd: pending.oldEnd + d, newStart: pending.newStart + d, newEnd: pending.newEnd + d };
  }
  if (change.startLine > pending.newEnd) return pending;
  if (change.endLine >= pending.newStart) return "accept";
  return "reject";
}

/** A box's selected lines after an edit that isn't inside a diff: moved by an edit above, unchanged by one below, and
 *  stretched or shrunk by one inside them. */
export function shiftLines(start: number, end: number, change: LineChange): { start: number; end: number } {
  if (change.endLine < start) return { start: start + change.lineDelta, end: end + change.lineDelta };
  if (change.startLine > end) return { start, end };
  return { start, end: Math.max(start, end + change.lineDelta) };
}
