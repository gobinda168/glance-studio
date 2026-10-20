// Ported from Tests/GlanceCoreTests (Blocks, Speech, Transcript, Narration) so both hosts behave the same.
import { test } from "node:test";
import assert from "node:assert/strict";
import { Block, BlockKind, splitBlocks } from "../src/core/blocks";
import { speechText } from "../src/core/speech";
import { lastReply, turnEvent } from "../src/core/transcript";
import { diagramAnchors, speechContext } from "../src/core/narration";

const say = (kind: BlockKind, markdown: string) => speechText({ kind, markdown });

test("splits the common block kinds", () => {
  const md = [
    "# Login flow", "", "Okay, so login is a **three-hop** dance.", "It spans two lines.", "",
    "```mermaid", "sequenceDiagram", "  User->>API: POST /login", "```", "",
    "- first item", "- second item", "  continued", "",
    "```ts", "const a = 1", "", "const b = 2", "```", "",
    "| a | b |", "|---|---|", "| 1 | 2 |", "", "> a quote", "", "---", "Last words.",
  ].join("\n");
  const blocks = splitBlocks(md);
  assert.deepEqual(blocks.map((b) => b.kind),
    ["heading", "paragraph", "mermaid", "list", "code", "table", "quote", "rule", "paragraph"]);
  assert.equal(blocks[1].markdown, "Okay, so login is a **three-hop** dance.\nIt spans two lines.");
  assert.equal(blocks[2].markdown, "sequenceDiagram\n  User->>API: POST /login");
  assert.equal(blocks[3].markdown, "- first item\n- second item\n  continued");
  assert.equal(blocks[4].lang, "ts");
  assert.equal(blocks[4].markdown, "const a = 1\n\nconst b = 2");
  assert.equal(blocks[8].markdown, "Last words.");
});

test("an unclosed fence runs to the end", () => {
  const blocks = splitBlocks("Intro\n```mermaid\ngraph TD\n  A-->B");
  assert.deepEqual(blocks.map((b) => b.kind), ["paragraph", "mermaid"]);
  assert.equal(blocks[1].markdown, "graph TD\n  A-->B");
});

test("lists survive blank lines between items", () => {
  const blocks = splitBlocks("1. one\n\n2. two\n\nAfter.");
  assert.deepEqual(blocks.map((b) => b.kind), ["list", "paragraph"]);
  assert.equal(blocks[0].markdown, "1. one\n\n2. two");
});

test("empty input has no blocks", () => {
  assert.deepEqual(splitBlocks("\n\n  \n"), []);
});

test("strips inline markdown", () => {
  assert.equal(say("paragraph", "Okay, **login** is a _three-hop_ ~~dance~~ *flow*."), "Okay, login is a three-hop dance flow.");
  assert.equal(say("paragraph", "See [the docs](https://x.dev/a) or https://example.com/path now."), "See the docs or now.");
  assert.equal(say("paragraph", "An image ![diagram](a.png) here."), "An image here.");
  assert.equal(say("paragraph", "Keep snake_case_names intact."), "Keep snake_case_names intact.");
});

test("shortens inline code", () => {
  assert.equal(say("paragraph", "Open `src/auth/session.ts` and call `refresh()`."), "Open session.ts and call refresh.");
  assert.equal(say("paragraph", "Run `git rebase --onto main feature-branch-with-long-name`."), "Run that command.");
  assert.equal(say("paragraph", "Set `retries` to 3."), "Set retries to 3.");
});

test("reads arrows as words", () => {
  assert.equal(say("paragraph", "User → API -> DB"), "User to API to DB");
});

test("headings and lists become sentences", () => {
  assert.equal(say("heading", "## How it works"), "How it works.");
  assert.equal(say("list", "- first thing\n- second thing!\n  more detail\n1. third"), "First thing. Second thing! more detail. Third.");
  assert.equal(say("quote", "> quoted line\n> second"), "quoted line second");
});

test("silent blocks", () => {
  assert.equal(say("code", "let a = 1"), null);
  assert.equal(say("mermaid", "graph TD"), null);
  assert.equal(say("table", "| a |"), null);
  assert.equal(say("rule", "---"), null);
  assert.equal(say("paragraph", "`x/y.ts`  "), "y.ts");
  assert.equal(say("paragraph", "   "), null);
});

const transcript = [
  `{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}`,
  `{"type":"user","message":{"role":"user","content":"first question"}}`,
  `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Old answer."}]}}`,
  `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"how does auth work?"}]}}`,
  `{"type":"attachment","attachment":{}}`,
  `{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}`,
  `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Let me look."}]}}`,
  `{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{}}]}}`,
  `{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"file body"}]}}`,
  `{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"meta reminder"}]}}`,
  `{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}`,
  `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"So login is a three-hop dance."}]}}`,
  "not json at all",
  "",
].join("\n");

test("last reply joins text after the last real prompt", () => {
  assert.equal(lastReply(transcript), "Let me look.\n\nSo login is a three-hop dance.");
});

test("last reply is null when the turn has no text yet", () => {
  assert.equal(lastReply(transcript + "\n" + `{"type":"user","message":{"role":"user","content":"next"}}`), null);
});

test("last reply ignores garbage", () => {
  assert.equal(lastReply(""), null);
  assert.equal(lastReply("{\n}\n[1,2]"), null);
});

test("turn events: a prompt starts thinking, end_turn finishes, tool use and sidechains don't", () => {
  const cwd = "/work/app";
  assert.deepEqual(turnEvent(`{"type":"user","cwd":"${cwd}","message":{"content":"hi"}}`), { kind: "prompt", cwd });
  assert.deepEqual(turnEvent(`{"type":"assistant","cwd":"${cwd}","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"x"}]}}`),
    { kind: "done", cwd });
  assert.equal(turnEvent(`{"type":"assistant","cwd":"${cwd}","message":{"stop_reason":"tool_use","content":[]}}`), null);
  assert.equal(turnEvent(`{"type":"assistant","isSidechain":true,"message":{"stop_reason":"end_turn","content":[]}}`), null);
  assert.equal(turnEvent(`{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}`), null);
  assert.equal(turnEvent(`{"type":"user","isMeta":true,"message":{"content":"x"}}`), null);
  assert.equal(turnEvent("garbage"), null);
});

const kinds = (list: BlockKind[]): Block[] => list.map((kind) => ({ kind, markdown: "x" }));

test("diagrams draw with the prose that follows them", () => {
  const reply = kinds(["paragraph", "mermaid", "paragraph", "code", "mermaid", "paragraph"]);
  assert.deepEqual(diagramAnchors(reply, [0, 2, 5]), new Map([[2, [1]], [5, [4]]]));
});

test("trailing diagrams draw with the last prose", () => {
  assert.deepEqual(diagramAnchors(kinds(["paragraph", "mermaid", "mermaid"]), [0]), new Map([[0, [1, 2]]]));
});

test("diagrams without prose have no anchor", () => {
  assert.deepEqual(diagramAnchors(kinds(["mermaid"]), []), new Map([[-1, [0]]]));
});

test("context is the neighbouring paragraphs", () => {
  const texts = ["One.", "Two.", "Three."];
  assert.deepEqual(speechContext(texts, 0), { previous: null, next: "Two." });
  assert.deepEqual(speechContext(texts, 1), { previous: "One.", next: "Three." });
  assert.deepEqual(speechContext(texts, 2), { previous: "Two.", next: null });
});

import { clampPrefs, panelStatus } from "../src/core/status";

test("panel status matches the Mac app", () => {
  assert.equal(panelStatus("idle", false).header, "WAITING FOR CLAUDE");
  assert.equal(panelStatus("idle", true).header, "READY");
  assert.deepEqual(panelStatus("speaking", true), { mode: "speaking", header: "READING ALOUD", title: "Speaking", subtitle: "READING ALOUD" });
  assert.equal(panelStatus("paused", true).mode, "idle");
});

test("panel prefs are clamped and filled", () => {
  assert.deepEqual(clampPrefs({ theme: "light", speed: 3, size: 9, animate: false }),
    { theme: "light", speed: 1.5, size: 2, animate: false, follow: true });
  assert.deepEqual(clampPrefs(undefined), { theme: "dark", speed: 1, size: 1, animate: true, follow: true });
  assert.equal(clampPrefs({ speed: 0.1 }).speed, 0.75);
});
