import { test } from "node:test";
import assert from "node:assert/strict";
import { afterChange, isStale, lineDeletion, pendingFor, shiftLines } from "../src/embedded/askDiff";
import { decodeCommand } from "../src/embedded/bridge";

const lengths = (lines: string[]) => (i: number) => lines[i].length;

test("the selection is stale once its text changed or it's gone", () => {
  assert.equal(isStale("a\nb", "a\nb"), false);
  assert.equal(isStale("a\nB", "a\nb"), true);
  assert.equal(isStale(undefined, "a"), true);
});

test("new lines go right below the selected ones", () => {
  assert.deepEqual(pendingFor(3, 4, "x\ny\nz"), { oldStart: 3, oldEnd: 4, newStart: 5, newEnd: 7 });
  assert.deepEqual(pendingFor(1, 1, ""), { oldStart: 1, oldEnd: 1, newStart: 2, newEnd: 2 });
});

test("deleting lines in the middle takes their line break", () => {
  const doc = ["a", "bb", "ccc", "d"];
  assert.deepEqual(lineDeletion(2, 3, doc.length, lengths(doc)), { startLine: 1, startCharacter: 0, endLine: 3, endCharacter: 0 });
});

test("deleting the last lines takes the line break before them", () => {
  const doc = ["a", "bb", "ccc"];
  assert.deepEqual(lineDeletion(2, 3, doc.length, lengths(doc)), { startLine: 0, startCharacter: 1, endLine: 2, endCharacter: 3 });
});

test("deleting every line empties the document", () => {
  const doc = ["a", "bb"];
  assert.deepEqual(lineDeletion(1, 2, doc.length, lengths(doc)), { startLine: 0, startCharacter: 0, endLine: 1, endCharacter: 2 });
});

test("an edit above the diff moves it, one below leaves it", () => {
  const p = { oldStart: 10, oldEnd: 11, newStart: 12, newEnd: 14 };
  assert.deepEqual(afterChange(p, { startLine: 2, endLine: 2, lineDelta: 2 }), { oldStart: 12, oldEnd: 13, newStart: 14, newEnd: 16 });
  assert.deepEqual(afterChange(p, { startLine: 3, endLine: 5, lineDelta: -2 }), { oldStart: 8, oldEnd: 9, newStart: 10, newEnd: 12 });
  assert.equal(afterChange(p, { startLine: 15, endLine: 15, lineDelta: 1 }), p);
});

test("typing in the new lines accepts them, in the old lines keeps those", () => {
  const p = { oldStart: 10, oldEnd: 11, newStart: 12, newEnd: 14 };
  assert.equal(afterChange(p, { startLine: 13, endLine: 13, lineDelta: 0 }), "accept");
  assert.equal(afterChange(p, { startLine: 14, endLine: 14, lineDelta: 0 }), "accept");
  assert.equal(afterChange(p, { startLine: 10, endLine: 10, lineDelta: 0 }), "reject");
  assert.equal(afterChange(p, { startLine: 11, endLine: 12, lineDelta: -1 }), "accept");
});

test("ask events from the app decode, junk doesn't", () => {
  assert.deepEqual(decodeCommand('{"type":"askEvent","id":"a1","kind":"text","text":"hi"}'),
    { type: "askEvent", id: "a1", kind: "text", text: "hi" });
  assert.deepEqual(decodeCommand('{"type":"askEvent","id":"a1","kind":"done","replacement":"x","start":2,"end":3,"originalText":"o"}'),
    { type: "askEvent", id: "a1", kind: "done", replacement: "x", start: 2, end: 3, originalText: "o" });
  assert.deepEqual(decodeCommand('{"type":"askEvent","id":"a1","kind":"done","start":2,"end":3,"originalText":"o"}'),
    { type: "askEvent", id: "a1", kind: "done", start: 2, end: 3, originalText: "o" });
  assert.equal(decodeCommand('{"type":"askEvent","id":"a1","kind":"nope"}'), undefined);
  assert.equal(decodeCommand('{"type":"askEvent","kind":"text","text":"hi"}'), undefined);
});

test("a box's lines follow edits above them and inside them", () => {
  assert.deepEqual(shiftLines(10, 12, { startLine: 3, endLine: 3, lineDelta: 2 }), { start: 12, end: 14 });
  assert.deepEqual(shiftLines(10, 12, { startLine: 20, endLine: 20, lineDelta: 5 }), { start: 10, end: 12 });
  assert.deepEqual(shiftLines(10, 12, { startLine: 11, endLine: 11, lineDelta: 1 }), { start: 10, end: 13 });
  assert.deepEqual(shiftLines(10, 12, { startLine: 10, endLine: 12, lineDelta: -5 }), { start: 10, end: 10 });
});
