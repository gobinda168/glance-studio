// The broker end to end: node --test agent-browser/test.mjs
// Needs the network the first time (npm and Chromium go to GLANCE_AGENT_BROWSER_TEST_HOME, default
// ~/Library/Caches/glance-agent-browser-test, kept between runs). Headless (GLANCE_AGENT_BROWSER_HEADLESS), so no windows
// open while it runs.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import net from "node:net";
import { askToQuit, lightpandaAsset } from "./agent-browser.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const home = process.env.GLANCE_AGENT_BROWSER_TEST_HOME ?? path.join(os.homedir(), "Library/Caches/glance-agent-browser-test");

function startBroker(extraArgs = [], env = {}) {
  const child = spawn(process.execPath, [path.join(here, "agent-browser.mjs"), "--home", home, ...extraArgs], {
    stdio: ["pipe", "pipe", "inherit"],
    env: { ...process.env, GLANCE_AGENT_BROWSER_HEADLESS: "1", ...env },
  });
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
    assert.ok(claude.pid > 0, JSON.stringify(claude));
    const version = await (await fetch(`http://127.0.0.1:${claude.cdpPort}/json/version`)).json();
    assert.match(version.webSocketDebuggerUrl, /^ws:\/\/127\.0\.0\.1:/);
    // Chromium itself on its own lasting profile, not a Playwright server's temporary one.
    assert.equal(fs.readFileSync(path.join(home, "profile", "GlanceDevToolsPort"), "utf8").trim(), `${claude.cdpPort} ${claude.pid}`);

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

test("broker: a Glance browser left by a broker that died is closed, not reused", { timeout: 600_000 }, async () => {
  const first = startBroker();
  first.send("claude");
  const left = await first.next((e) => e.event === "browser" && e.kind === "claude");
  first.child.kill("SIGKILL"); // Studio crashed: its Chromium keeps running and holds the profile
  await new Promise((r) => first.child.once("exit", r));
  const alive = (pid) => {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  };
  assert.ok(alive(left.pid));

  const second = startBroker();
  try {
    await second.next((e) => e.event === "ready", 10_000);
    second.send("claude");
    const fresh = await second.next((e) => e.event === "browser" && e.kind === "claude");
    assert.notEqual(fresh.pid, left.pid);
    assert.ok(!alive(left.pid));
    const version = await (await fetch(`http://127.0.0.1:${fresh.cdpPort}/json/version`)).json();
    assert.ok(version.Browser, JSON.stringify(version));
  } finally {
    second.send("quit");
    await new Promise((r) => second.child.once("exit", r));
  }
});

const commandLine = (pid) => execFileSync("ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8" });

test("broker: a sign-in (a persistent cookie) survives a stop and start", { timeout: 600_000 }, async () => {
  const broker = startBroker();
  const { chromium } = createRequire(path.join(home, "package.json"))("playwright-core");
  const cookie = { name: "glance_signin", value: `kept-${process.pid}`, url: "http://localhost/", expires: Math.floor(Date.now() / 1000) + 3600 };
  try {
    await broker.next((e) => e.event === "ready", 10_000);
    broker.send("claude");
    const first = await broker.next((e) => e.event === "browser" && e.kind === "claude");
    assert.ok(!commandLine(first.pid).includes("--disable-backgrounding-occluded-windows"), "flag off: no occlusion flag");
    const attached = await chromium.connectOverCDP(`http://127.0.0.1:${first.cdpPort}`);
    await attached.contexts()[0].addCookies([cookie]);
    await attached.close(); // drops our connection only; the browser is Studio's

    // Stop asks Chromium to quit (Browser.close), so the cookie reaches the profile's cookie file before the process goes.
    broker.send("stop");
    await broker.next((e) => e.event === "stopped");
    await broker.next((e) => e.event === "browserGone" && e.id === "claude");
    broker.send("resume");
    await broker.next((e) => e.event === "resumed");
    broker.send("claude");
    const second = await broker.next((e) => e.event === "browser" && e.kind === "claude" && e.pid !== first.pid);
    const again = await chromium.connectOverCDP(`http://127.0.0.1:${second.cdpPort}`);
    const kept = (await again.contexts()[0].cookies("http://localhost/")).find((c) => c.name === cookie.name);
    assert.equal(kept?.value, cookie.value);
    await again.close();
  } finally {
    broker.send("quit");
    await new Promise((r) => broker.child.once("exit", r));
  }
});

test("broker: --session-windows adds the occluded-windows flag (the test above has it off)", { timeout: 600_000 }, async () => {
  const broker = startBroker(["--session-windows"]);
  try {
    await broker.next((e) => e.event === "ready", 10_000);
    broker.send("claude");
    const claude = await broker.next((e) => e.event === "browser" && e.kind === "claude");
    assert.ok(commandLine(claude.pid).includes("--disable-backgrounding-occluded-windows"), commandLine(claude.pid));
  } finally {
    broker.send("quit");
    await new Promise((r) => broker.child.once("exit", r));
  }
});

test("askToQuit: a DevTools port that accepts and never answers is given up on, and its connection closed", { timeout: 60_000 }, async () => {
  const { chromium } = createRequire(path.join(home, "package.json"))("playwright-core");
  const sockets = [];
  const silent = net.createServer((socket) => sockets.push(socket)); // accepts, reads nothing, says nothing
  await new Promise((r) => silent.listen(0, "127.0.0.1", r));
  try {
    const started = Date.now();
    assert.equal(await askToQuit(chromium, silent.address().port, 600), false);
    assert.ok(Date.now() - started < 3000, `took ${Date.now() - started} ms`);
  } finally {
    for (const socket of sockets) socket.destroy();
    silent.close();
  }
});

test("broker: stop on a Chromium that stopped answering still ends it, within the bound", { timeout: 120_000 }, async () => {
  const broker = startBroker([], { GLANCE_AGENT_BROWSER_QUIT_WAIT_MS: "600" });
  try {
    await broker.next((e) => e.event === "ready", 10_000);
    broker.send("claude");
    const claude = await broker.next((e) => e.event === "browser" && e.kind === "claude");
    process.kill(claude.pid, "SIGSTOP"); // its DevTools socket still accepts (the kernel does that), nothing answers
    const started = Date.now();
    broker.send("stop");
    await broker.next((e) => e.event === "stopped", 20_000);
    await broker.next((e) => e.event === "browserGone" && e.id === "claude", 20_000);
    assert.ok(Date.now() - started < 10_000, `took ${Date.now() - started} ms`);
    assert.throws(() => process.kill(claude.pid, 0), "the stopped Chromium was killed");
    // The broker is still serving after that: resume and start a browser again.
    broker.send("resume");
    await broker.next((e) => e.event === "resumed");
  } finally {
    broker.send("quit");
    await new Promise((r) => broker.child.once("exit", r));
  }
});

test("lightpanda: the release file for each Mac", () => {
  assert.equal(lightpandaAsset("darwin", "arm64"), "lightpanda-aarch64-macos");
  assert.equal(lightpandaAsset("darwin", "x64"), "lightpanda-x86_64-macos");
  assert.equal(lightpandaAsset("darwin", "ppc"), null);
  assert.equal(lightpandaAsset("linux", "arm64"), null);
});
