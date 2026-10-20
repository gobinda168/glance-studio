import { test } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { SessionEvent, TranscriptWatcher, readTail } from "../src/watcher";
import { lastReply } from "../src/core/transcript";

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function until(check: () => boolean, ms = 3000) {
  const end = Date.now() + ms;
  while (!check() && Date.now() < end) await wait(25);
}

test("follows a session: history is ignored, a prompt means thinking, end_turn means the reply is ready", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "glance-watch-"));
  const project = path.join(root, "-work-app");
  fs.mkdirSync(project);
  const file = path.join(project, "s1.jsonl");
  fs.writeFileSync(file, `{"type":"user","cwd":"/work/app","message":{"content":"old question"}}\n`);

  const events: SessionEvent[] = [];
  const watcher = new TranscriptWatcher(root, (cwd) => cwd === "/work/app", (e) => events.push(e));
  watcher.start();
  try {
    await wait(100);
    fs.appendFileSync(file, `{"type":"user","cwd":"/work/app","message":{"content":"how does auth work?"}}\n`);
    await until(() => events.length >= 1);
    assert.deepEqual(events.map((e) => e.kind), ["prompt"]);

    // A session elsewhere is ignored.
    const other = path.join(project, "s2.jsonl");
    fs.writeFileSync(other, `{"type":"user","cwd":"/elsewhere","message":{"content":"hi"}}\n`);

    fs.appendFileSync(file, `{"type":"assistant","cwd":"/work/app","message":{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"x"}]}}\n`);
    fs.appendFileSync(file, `{"type":"assistant","cwd":"/work/app","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Login is a three-hop dance."}]}}`);
    fs.appendFileSync(file, `\n`);
    await until(() => events.length >= 2);
    await wait(600);
    assert.deepEqual(events.map((e) => e.kind), ["prompt", "done"], "one done for the whole burst");
    assert.equal(events[1].file, file);
    assert.equal(lastReply(readTail(file)), "Login is a three-hop dance.");
  } finally {
    watcher.dispose();
    fs.rmSync(root, { recursive: true, force: true });
  }
});
