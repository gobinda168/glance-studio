// The broker end to end: node --test agent-browser/test.mjs
// Needs the network the first time (npm and Chromium go to GLANCE_AGENT_BROWSER_TEST_HOME, default
// ~/Library/Caches/glance-agent-browser-test, kept between runs).
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const home = process.env.GLANCE_AGENT_BROWSER_TEST_HOME ?? path.join(os.homedir(), "Library/Caches/glance-agent-browser-test");

function startBroker() {
  const child = spawn(process.execPath, [path.join(here, "agent-browser.mjs"), "--home", home], { stdio: ["pipe", "pipe", "inherit"] });
  const events = [];
  const waiters = [];
  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    const event = JSON.parse(line);
    events.push(event);
    for (const w of [...waiters]) if (w.match(event)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(event); }
  });
  const next = (match, ms = 300_000) =>
    new Promise((resolve, reject) => {
      const found = events.find(match);
      if (found) return resolve(found);
      waiters.push({ match, resolve });
      setTimeout(() => reject(new Error("timed out waiting; events: " + JSON.stringify(events))), ms).unref();
    });
  return { child, events, next, send: (line) => child.stdin.write(line + "\n") };
}

async function cdp(port, method, params = {}) {
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  return targets;
}

test("broker: the Glance browser, a test client, stop and resume", { timeout: 600_000 }, async () => {
  const broker = startBroker();
  try {
    const ready = await broker.next((e) => e.event === "ready", 10_000);

    // Glance browser on the CDP port Studio gave (here: the one the broker chose).
    broker.send("claude");
    const claude = await broker.next((e) => e.event === "browser" && e.kind === "claude");
    assert.equal(claude.cdpPort, ready.cdpPort);
    const version = await (await fetch(`http://127.0.0.1:${claude.cdpPort}/json/version`)).json();
    assert.match(version.webSocketDebuggerUrl, /^ws:\/\/127\.0\.0\.1:/);

    // A Playwright client of Glance's version, through the client port: its own test browser.
    const { chromium } = createRequire(path.join(home, "package.json"))("playwright-core");
    const client = await chromium.connect(`ws://127.0.0.1:${ready.clientPort}/`);
    const test = await broker.next((e) => e.event === "browser" && e.kind === "test");
    const page = await client.newPage();
    await page.goto("data:text/html,<title>hello</title><h1>hi</h1>");
    const targets = await cdp(test.cdpPort);
    assert.ok(targets.some((t) => t.type === "page" && t.title === "hello"), JSON.stringify(targets));

    // Not a Playwright client.
    const curl = await fetch(`http://127.0.0.1:${ready.clientPort}/`, { headers: { Upgrade: "websocket", Connection: "Upgrade" } }).catch((e) => e);
    assert.ok(!(curl instanceof Error) ? curl.status === 400 : true);

    // Stop closes every browser and refuses new clients; resume lets them in again.
    broker.send("stop");
    await broker.next((e) => e.event === "stopped");
    await broker.next((e) => e.event === "browserGone" && e.id === "claude");
    await assert.rejects(chromium.connect(`ws://127.0.0.1:${ready.clientPort}/`), /stopped the Glance browser/);
    broker.send("resume");
    await broker.next((e) => e.event === "resumed");
    const again = await chromium.connect(`ws://127.0.0.1:${ready.clientPort}/`);
    await again.close();
    await client.close().catch(() => {});
  } finally {
    broker.send("quit");
    await new Promise((r) => broker.child.once("exit", r));
  }
});
