import { test } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { Bridge, encode } from "../src/embedded/bridge";
import { EMBEDDED_DEFAULTS, defaultsToApply, isShellTerminal } from "../src/embedded/rules";

test("applies only the defaults the user hasn't set", () => {
  assert.deepEqual(defaultsToApply({}), Object.entries(EMBEDDED_DEFAULTS));
  const set = { "workbench.startupEditor": "welcomePage" };
  assert.ok(!defaultsToApply(set).some(([key]) => key === "workbench.startupEditor"));
  assert.equal(EMBEDDED_DEFAULTS["terminal.integrated.enablePersistentSessions"], false);
  assert.equal(EMBEDDED_DEFAULTS["terminal.integrated.hideOnStartup"], "always");
});

test("the editor tab's themes are the Glance themes the extension ships, follow the window, and resolve", () => {
  assert.equal(EMBEDDED_DEFAULTS["window.autoDetectColorScheme"], true);
  const root = path.join(__dirname, "..", "..");
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const themes = new Map<string, string>(
    manifest.contributes.themes.map((t: { id: string; path: string }) => [t.id, t.path]));
  for (const key of ["workbench.preferredDarkColorTheme", "workbench.preferredLightColorTheme"]) {
    const id = EMBEDDED_DEFAULTS[key] as string;
    assert.ok(themes.has(id), `${key} names a theme the extension contributes`);
    // Each theme and every file it includes exists and parses.
    let file: string | undefined = path.join(root, themes.get(id)!);
    while (file) {
      const theme = JSON.parse(fs.readFileSync(file, "utf8"));
      file = theme.include ? path.join(path.dirname(file), theme.include) : undefined;
    }
  }
});

test("a terminal nobody's task or debug session started is a shell", () => {
  assert.equal(isShellTerminal({ name: "zsh", runningTasks: [] }), true);
  assert.equal(isShellTerminal({ name: "zsh", runningTasks: ["watch"], msSinceTaskStart: 60_000 }), true);
});

test("task and debug terminals stay in VS Code", () => {
  assert.equal(isShellTerminal({ name: "build", runningTasks: ["build"] }), false);
  assert.equal(isShellTerminal({ name: "Task - build", runningTasks: [] }), false);
  assert.equal(isShellTerminal({ name: "zsh", runningTasks: [], msSinceTaskStart: 400 }), false);
  assert.equal(isShellTerminal({ name: "zsh", runningTasks: [], msSinceTaskStart: -300 }), false); // the event came late
  assert.equal(isShellTerminal({ name: "Python Debug Console", runningTasks: [], msSinceDebugStart: 900 }), false);
});

test("encodes the same lines the app decodes", () => {
  assert.equal(encode({ type: "openTerminal", cwd: "/a b" }), '{"type":"openTerminal","cwd":"/a b"}\n');
  assert.equal(encode({ type: "closeTab" }), '{"type":"closeTab"}\n');
});

test("says hello first, then sends messages queued while connecting", async () => {
  const socketPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "glance-")), "b.sock");
  const received: string[] = [];
  const server = net.createServer((client) => {
    client.on("data", (chunk) => received.push(...chunk.toString().split("\n").filter(Boolean)));
  });
  await new Promise<void>((resolve) => server.listen(socketPath, resolve));
  const bridge = new Bridge(socketPath, { type: "hello", folder: "/p" });
  bridge.send({ type: "openTerminal", cwd: "/p" });
  await new Promise((resolve) => setTimeout(resolve, 200));
  bridge.send({ type: "closeTab" });
  await new Promise((resolve) => setTimeout(resolve, 200));
  bridge.dispose();
  server.close();
  assert.deepEqual(received, ['{"type":"hello","folder":"/p"}', '{"type":"openTerminal","cwd":"/p"}', '{"type":"closeTab"}']);
});

test("reconnects when the app comes back", async () => {
  const socketPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "glance-")), "b.sock");
  const bridge = new Bridge(socketPath, { type: "hello", folder: "/p" }, 100);
  bridge.send({ type: "closeTab" });
  await new Promise((resolve) => setTimeout(resolve, 150)); // nothing listening yet
  const received: string[] = [];
  const server = net.createServer((client) => client.on("data", (c) => received.push(...c.toString().split("\n").filter(Boolean))));
  await new Promise<void>((resolve) => server.listen(socketPath, resolve));
  await new Promise((resolve) => setTimeout(resolve, 300));
  bridge.dispose();
  server.close();
  assert.deepEqual(received, ['{"type":"hello","folder":"/p"}', '{"type":"closeTab"}']);
});

import { decodeCommand, splitLines } from "../src/embedded/bridge";
import { markPositions, nextMark } from "../src/embedded/changes";

test("splits socket data into lines across chunks", () => {
  let r = splitLines("", '{"type":"op');
  assert.deepEqual(r, { lines: [], rest: '{"type":"op' });
  r = splitLines(r.rest, 'en","path":"/a"}\n{"type":"claudeChanges","files":{}}\n\n');
  assert.deepEqual(r.lines, ['{"type":"open","path":"/a"}', '{"type":"claudeChanges","files":{}}']);
  assert.equal(r.rest, "");
});

test("decodes the app's commands and ignores anything else", () => {
  assert.deepEqual(decodeCommand('{"type":"open","path":"/p/a b.swift","line":4,"column":2}'),
    { type: "open", path: "/p/a b.swift", line: 4, column: 2 });
  assert.deepEqual(decodeCommand('{"type":"open","path":"/p/a.swift"}'), { type: "open", path: "/p/a.swift", line: undefined, column: undefined });
  assert.deepEqual(decodeCommand('{"type":"claudeChanges","files":{"a.ts":[{"start":1,"end":2,"kind":"added"}]}}'),
    { type: "claudeChanges", files: { "a.ts": [{ start: 1, end: 2, kind: "added" }] } });
  assert.equal(decodeCommand("nope"), undefined);
  assert.equal(decodeCommand('{"type":"open"}'), undefined);
  assert.equal(decodeCommand('{"type":"explode"}'), undefined);
});

test("orders marks by path then line", () => {
  const list = markPositions({
    "b.ts": [{ start: 7, end: 9, kind: "modified" }],
    "a.ts": [{ start: 20, end: 20, kind: "deleted" }, { start: 3, end: 4, kind: "added" }],
  });
  assert.deepEqual(list, [{ path: "a.ts", line: 3 }, { path: "a.ts", line: 20 }, { path: "b.ts", line: 7 }]);
});

test("F7 goes to the next mark, wrapping around; ⇧F7 to the previous", () => {
  const list = [{ path: "a.ts", line: 3 }, { path: "a.ts", line: 20 }, { path: "b.ts", line: 7 }];
  assert.deepEqual(nextMark(list, { path: "a.ts", line: 3 }, 1), { path: "a.ts", line: 20 });
  assert.deepEqual(nextMark(list, { path: "a.ts", line: 25 }, 1), { path: "b.ts", line: 7 });
  assert.deepEqual(nextMark(list, { path: "b.ts", line: 7 }, 1), { path: "a.ts", line: 3 });
  assert.deepEqual(nextMark(list, { path: "a.ts", line: 3 }, -1), { path: "b.ts", line: 7 });
  assert.deepEqual(nextMark(list, { path: "c.ts", line: 1 }, -1), { path: "b.ts", line: 7 });
  assert.deepEqual(nextMark(list, undefined, 1), { path: "a.ts", line: 3 });
  assert.deepEqual(nextMark(list, undefined, -1), { path: "b.ts", line: 7 });
  assert.equal(nextMark([], { path: "a.ts", line: 1 }, 1), undefined);
});

test("the bridge hands the app's commands to the extension", async () => {
  const socketPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "glance-")), "b.sock");
  const server = net.createServer((client) => {
    client.write('{"type":"open","path":"/p/a.swift","line":2}\n{"type":"clau');
    setTimeout(() => client.write('deChanges","files":{}}\n'), 50);
  });
  await new Promise<void>((resolve) => server.listen(socketPath, resolve));
  const commands: unknown[] = [];
  const bridge = new Bridge(socketPath, { type: "hello", folder: "/p" }, 2000, (c) => commands.push(c));
  await new Promise((resolve) => setTimeout(resolve, 250));
  bridge.dispose();
  server.close();
  assert.deepEqual(commands, [
    { type: "open", path: "/p/a.swift", line: 2, column: undefined },
    { type: "claudeChanges", files: {} },
  ]);
});

import { stillChanged } from "../src/embedded/claudeFiles";

test("decodes Claude's files", () => {
  assert.deepEqual(decodeCommand('{"type":"claudeFiles","paths":["a b.ts","d/c.md"]}'), { type: "claudeFiles", paths: ["a b.ts", "d/c.md"] });
  assert.equal(decodeCommand('{"type":"claudeFiles","paths":"x"}'), undefined);
});

test("Claude's changes are Claude's files that git still lists", () => {
  assert.deepEqual(stillChanged(["b.ts", "a.ts", "gone.ts"], ["a.ts", "b.ts", "other.ts"]), ["a.ts", "b.ts"]);
  assert.deepEqual(stillChanged([], ["a.ts"]), []);
});
