// The per-session MCP wrapper against a real Chromium and real wrapper processes: node --test agent-browser/session-mcp.test.mjs
// Uses the Playwright packages and Chromium that agent-browser/test.mjs installs into GLANCE_AGENT_BROWSER_TEST_HOME
// (default ~/Library/Caches/glance-agent-browser-test) and skips with a message when they aren't there. Chromium runs
// headless on a temporary profile and free ports, so no window opens and nothing of the user's is touched.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import { createRequire } from "node:module";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const home = process.env.GLANCE_AGENT_BROWSER_TEST_HOME ?? path.join(os.homedir(), "Library/Caches/glance-agent-browser-test");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let chromiumPath;
const skip = (() => {
  try {
    const req = createRequire(path.join(home, "package.json"));
    req.resolve("@playwright/mcp");
    chromiumPath = req("playwright-core").chromium.executablePath();
    return fs.existsSync(chromiumPath) ? false : `Chromium isn't installed (${chromiumPath}); run node --test agent-browser/test.mjs once`;
  } catch {
    return `@playwright/mcp isn't installed in ${home}; run node --test agent-browser/test.mjs once`;
  }
})();
const lab = (name, fn) =>
  test(name, { skip, timeout: 180_000 }, async () => {
    const l = await Lab.create();
    try { await fn(l); } finally { await l.stop(); }
  });

// ---- helpers -----------------------------------------------------------------------------------------------------

const children = new Set();
process.on("exit", () => { for (const c of children) if (c.exitCode === null) c.kill("SIGKILL"); });

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer().listen(0, "127.0.0.1", () => { const { port } = s.address(); s.close(() => resolve(port)); });
  });
}

async function waitUntil(fn, what, ms = 15_000) {
  const end = Date.now() + ms;
  for (;;) {
    const value = await fn();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(100);
  }
}

/** A raw browser-level CDP connection: what Studio itself would hold. */
async function rawCdp(port) {
  const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  const ws = new WebSocket(webSocketDebuggerUrl);
  await new Promise((r) => (ws.onopen = r));
  let id = 0;
  const pend = new Map();
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && pend.has(d.id)) { const [res, rej] = pend.get(d.id); pend.delete(d.id); d.error ? rej(new Error(JSON.stringify(d.error))) : res(d.result); }
  };
  return {
    send: (method, params = {}) => new Promise((res, rej) => { const i = ++id; pend.set(i, [res, rej]); ws.send(JSON.stringify({ id: i, method, params })); }),
    close: () => ws.close(),
  };
}

/** The unix socket Studio would listen on: every line from every wrapper, tagged with the session its hello named. */
async function studioSocket(file) {
  const log = [];
  const connections = new Set();
  const server = net.createServer((c) => {
    connections.add(c);
    let session;
    let buf = "";
    c.on("data", (d) => {
      buf += d;
      for (let i; (i = buf.indexOf("\n")) >= 0; ) {
        const message = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
        if (message.type === "hello") session = message.session;
        log.push({ session, ...message });
      }
    });
    c.on("error", () => {});
    c.on("close", () => connections.delete(c));
  });
  await new Promise((r) => server.listen(file, r));
  return {
    file, log,
    of: (session) => log.filter((m) => m.session === session),
    waitFor: (match, what, ms) => waitUntil(() => log.find(match), what, ms),
    close: async () => { for (const c of connections) c.destroy(); await new Promise((r) => server.close(r)); },
  };
}

class Lab {
  static async create() {
    const l = new Lab();
    l.dir = fs.mkdtempSync(path.join(os.tmpdir(), "sm-"));
    l.options = path.join(l.dir, "options.json");
    l.studio = await studioSocket(path.join(l.dir, "a.sock"));
    l.useSocket(l.studio.file);
    l.port = await freePort();
    l.endpoint = `http://127.0.0.1:${l.port}`;
    l.web = http.createServer((req, res) => {
      res.setHeader("content-type", "text/html");
      if (req.url === "/set") { res.setHeader("Set-Cookie", ["sess=1; Path=/"]); res.end("<title>set</title><h1>cookies set</h1>"); }
      else if (req.url === "/show") res.end(`<title>show</title><h1>COOKIE[${req.headers.cookie ?? ""}]</h1>`);
      else if (req.url === "/pop") res.end(`<title>pop</title><a href="/child" target="_blank">blanklink</a>`);
      else if (req.url === "/sandboxed") { res.setHeader("Content-Security-Policy", "sandbox allow-scripts"); res.end("<title>sandboxed</title><h1>sandboxed</h1>"); }
      else if (req.url === "/nulled") res.end("<title>nulled</title><h1>nulled</h1><script>window.open = () => null</script>");
      else if (req.url === "/late") res.end("<title>late</title><h1>late</h1><script>const open = window.open.bind(window); window.open = (url, name) => { setTimeout(() => open(url, name), 7000); return {}; }</script>");
      else if (req.url === "/dialog") res.end(`<title>dialog</title><button onclick="alert('hi')">alertbtn</button>`);
      else res.end(`<title>t${req.url}</title><h1>page ${req.url}</h1>`);
    });
    await new Promise((r) => l.web.listen(0, "127.0.0.1", r));
    l.base = `http://127.0.0.1:${l.web.address().port}`;
    l.wrappers = [];
    await l.startChromium();
    return l;
  }

  /** Points the wrappers at a socket (they re-read options.json on every attempt). */
  useSocket(file) { fs.writeFileSync(this.options, JSON.stringify({ sessionWindows: true, socket: file })); }

  async startChromium() {
    this.chrome = spawn(chromiumPath, [`--remote-debugging-port=${this.port}`, "--remote-debugging-address=127.0.0.1",
      `--user-data-dir=${path.join(this.dir, "profile")}`, "--no-first-run", "--no-default-browser-check", "--use-mock-keychain", "--headless=new"],
      { stdio: "ignore" });
    children.add(this.chrome);
    await waitUntil(async () => (await fetch(`${this.endpoint}/json/version`).catch(() => null))?.ok, "Chromium to start");
  }

  async stopChromium(signal = "SIGTERM") {
    const chrome = this.chrome;
    if (chrome.exitCode !== null) return;
    const exited = new Promise((r) => chrome.once("exit", r));
    chrome.kill(signal);
    await Promise.race([exited, sleep(8000)]);
    if (chrome.exitCode === null) chrome.kill("SIGKILL");
  }

  async targets() { return (await (await fetch(`${this.endpoint}/json/list`)).json()).filter((t) => t.type === "page"); }

  /** The window id of a target. */
  async windowOf(targetId) {
    const c = await rawCdp(this.port);
    try { return (await c.send("Browser.getWindowForTarget", { targetId })).windowId; } finally { c.close(); }
  }

  /** A wrapper process, spoken to over its stdio with a JSON-RPC client of this file's own (no SDK). */
  async wrapper(name, { initialize = true, env = {}, ab = home } = {}) {
    const child = spawn(process.execPath, [path.join(here, "session-mcp.mjs"), "--cdp-endpoint", this.endpoint, "--output-dir", path.join(this.dir, "out", name)], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, CLAUDE_PROJECT_DIR: "", GLANCE_AB: ab, GLANCE_BROWSER_OPTIONS: this.options, GLANCE_CLAUDE_PID: String(process.pid), CLAUDE_CODE_SESSION_ID: name, ...env },
    });
    children.add(child);
    let stderr = "";
    child.stderr.on("data", (d) => (stderr += d));
    let id = 0;
    let buf = "";
    const pend = new Map();
    child.stdout.on("data", (d) => {
      buf += d;
      for (let i; (i = buf.indexOf("\n")) >= 0; ) {
        const m = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
        if (m.id !== undefined && pend.has(m.id)) { const [res, rej] = pend.get(m.id); pend.delete(m.id); m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result); }
      }
    });
    const exited = new Promise((r) => child.once("exit", r));
    const request = (method, params = {}) => new Promise((res, rej) => {
      const i = ++id;
      pend.set(i, [res, rej]);
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: i, method, params }) + "\n");
      setTimeout(() => rej(new Error(`${name}: ${method} timed out; stderr: ${stderr}`)), 90_000).unref();
    });
    const w = {
      name, child, exited, request, stderr: () => stderr,
      listTools: async () => (await request("tools/list")).tools,
      call: (tool, args = {}) => request("tools/call", { name: tool, arguments: args }),
      text: async (tool, args) => (await w.call(tool, args)).content.filter((c) => c.type === "text").map((c) => c.text).join("\n"),
      tabs: async () => (await w.text("browser_tabs", { action: "list" })).match(/^- \d+:.*$/gm) ?? [],
    };
    if (initialize) {
      await request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name, version: "1" } });
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
    }
    this.wrappers.push(w);
    return w;
  }

  /** Established TCP connections from a process to Chromium's debugging port. */
  cdpConnections(pid) {
    try {
      return execFileSync("lsof", ["-nP", "-a", "-p", String(pid), `-iTCP:${this.port}`], { encoding: "utf8" }).split("\n").filter((l) => l.includes("ESTABLISHED")).length;
    } catch { return 0; }
  }

  async stop() {
    for (const w of this.wrappers) if (w.child.exitCode === null) { w.child.kill("SIGTERM"); await Promise.race([w.exited, sleep(5000)]); }
    await this.stopChromium();
    await this.studio.close();
    await new Promise((r) => this.web.close(r));
    fs.rmSync(this.dir, { recursive: true, force: true });
  }
}

const ref = (snapshot, label) => snapshot.match(new RegExp(`${label}[^\\n]*\\[ref=([a-z0-9]+)\\]`))?.[1];

// ---- tests -------------------------------------------------------------------------------------------------------

lab("starting a wrapper opens no CDP connection and the first tool call does", async (l) => {
  const before = (await l.targets()).length;
  const a = await l.wrapper("A");
  await a.listTools();
  await l.studio.waitFor((m) => m.type === "hello" && m.session === "A", "hello at startup");
  assert.equal(l.cdpConnections(a.child.pid), 0, "no CDP connection before a tool call");
  assert.equal((await l.targets()).length, before, "no page opened before a tool call");
  await a.text("browser_navigate", { url: `${l.base}/x` });
  assert.ok(l.cdpConnections(a.child.pid) > 0, "a CDP connection after the first tool call");
});

lab("two clients list only their own pages, each in a window of its own", async (l) => {
  const a = await l.wrapper("A"), b = await l.wrapper("B");
  await a.text("browser_navigate", { url: "data:text/html,<title>Alpha</title><h1>ALPHA</h1>" });
  await b.text("browser_navigate", { url: "data:text/html,<title>Beta</title><h1>BETA</h1>" });
  const ta = (await a.tabs()).join("\n"), tb = (await b.tabs()).join("\n");
  assert.ok(/Alpha/.test(ta) && !/Beta/.test(ta), ta);
  assert.ok(/Beta/.test(tb) && !/Alpha/.test(tb), tb);
  assert.match(await a.text("browser_snapshot"), /ALPHA/);
  const pa = l.studio.of("A").find((m) => m.type === "page"), pb = l.studio.of("B").find((m) => m.type === "page");
  assert.ok(pa && pb && pa.targetId !== pb.targetId);
  assert.notEqual(await l.windowOf(pa.targetId), await l.windowOf(pb.targetId));
});

lab("a Set-Cookie from one client is sent by the other", async (l) => {
  const a = await l.wrapper("A"), b = await l.wrapper("B");
  await a.text("browser_navigate", { url: `${l.base}/set` });
  await b.text("browser_navigate", { url: `${l.base}/show` });
  assert.match(await b.text("browser_snapshot"), /COOKIE\[sess=1\]/);
});

lab("a target=_blank page joins its opener's list only", async (l) => {
  const a = await l.wrapper("A"), b = await l.wrapper("B");
  await b.text("browser_navigate", { url: `${l.base}/b` });
  await a.text("browser_navigate", { url: `${l.base}/pop` });
  await a.text("browser_click", { target: ref(await a.text("browser_snapshot"), 'link "blanklink"') });
  await waitUntil(async () => (await a.tabs()).length === 2, "the popup in A's list");
  assert.equal((await b.tabs()).length, 1);
  const popup = l.studio.of("A").find((m) => m.type === "page" && m.openerId);
  assert.ok(popup, JSON.stringify(l.studio.of("A")));
  assert.equal(popup.adopted, false);
  assert.ok(!l.studio.of("B").some((m) => m.type === "page" && m.targetId === popup.targetId));
});

lab("a tab created with Target.createTarget lands in the active window and is adopted by that client", async (l) => {
  // A new tab goes to the browser's active window. Our windows are created with focus: false, so which one is active
  // is the user's doing (clicking it, which is Target.activateTarget), not creation order.
  const a = await l.wrapper("A"), b = await l.wrapper("B");
  const foreign = await rawCdp(l.port);
  try {
    await a.text("browser_navigate", { url: `${l.base}/a` });
    await b.text("browser_navigate", { url: `${l.base}/b` });
    const aPage = l.studio.of("A").find((m) => m.type === "page"), bPage = l.studio.of("B").find((m) => m.type === "page");
    const [aWindow, bWindow] = [await l.windowOf(aPage.targetId), await l.windowOf(bPage.targetId)];

    // B's window active: the tab lands there and B adopts it.
    await foreign.send("Target.activateTarget", { targetId: bPage.targetId });
    const { targetId: t1 } = await foreign.send("Target.createTarget", { url: `${l.base}/foreign1` });
    const adoptedByB = await l.studio.waitFor((m) => m.session === "B" && m.type === "page" && m.targetId === t1, "B to adopt the tab");
    assert.equal(adoptedByB.adopted, true);
    assert.equal(await l.windowOf(t1), bWindow);
    assert.ok((await b.tabs()).some((t) => t.includes("foreign1")), "adopted tab is in B's list");
    assert.ok(!(await a.tabs()).some((t) => t.includes("foreign1")), "and not in A's");
    assert.ok(!l.studio.of("A").some((m) => m.type === "page" && m.targetId === t1));

    // The other order: A's window active.
    await foreign.send("Target.activateTarget", { targetId: aPage.targetId });
    const { targetId: t2 } = await foreign.send("Target.createTarget", { url: `${l.base}/foreign2` });
    const adoptedByA = await l.studio.waitFor((m) => m.session === "A" && m.type === "page" && m.targetId === t2, "A to adopt the tab");
    assert.equal(adoptedByA.adopted, true);
    assert.equal(await l.windowOf(t2), aWindow);
    assert.ok((await a.tabs()).some((t) => t.includes("foreign2")));
    assert.ok(!(await b.tabs()).some((t) => t.includes("foreign2")));
    assert.ok(!l.studio.of("B").some((m) => m.type === "page" && m.targetId === t2));

    // A window that browser_close retired is no longer ours: a tab landing in a new window of A's is, not the old one.
    await a.text("browser_close");
    await a.text("browser_navigate", { url: `${l.base}/a2` });
    const aPage2 = l.studio.of("A").filter((m) => m.type === "page").at(-1);
    await foreign.send("Target.activateTarget", { targetId: aPage2.targetId });
    const { targetId: t3 } = await foreign.send("Target.createTarget", { url: `${l.base}/foreign3` });
    await l.studio.waitFor((m) => m.session === "A" && m.type === "page" && m.targetId === t3 && m.adopted, "A to adopt in its fresh window");
  } finally { foreign.close(); }
});

lab("a dialog on A's page isn't dismissed by B's wrapper", async (l) => {
  const a = await l.wrapper("A"), b = await l.wrapper("B");
  await a.text("browser_navigate", { url: `${l.base}/dialog` });
  await b.text("browser_navigate", { url: `${l.base}/b` }); // B is connected, so B's wrapper sees A's dialog events
  const opened = await a.text("browser_click", { target: ref(await a.text("browser_snapshot"), 'button "alertbtn"') });
  assert.match(opened, /alert|dialog/i, opened);
  await sleep(1000); // time for B's wrapper to dismiss it, were it going to
  const handled = await a.call("browser_handle_dialog", { accept: true });
  assert.ok(!handled.isError, JSON.stringify(handled));
});

lab("A's stdin closing closes A's window and leaves B working", async (l) => {
  const a = await l.wrapper("A"), b = await l.wrapper("B");
  await a.text("browser_navigate", { url: `${l.base}/a-only` });
  await b.text("browser_navigate", { url: `${l.base}/b-only` });
  a.child.stdin.end();
  await Promise.race([a.exited, sleep(15_000)]);
  assert.equal(a.child.exitCode, 0);
  await waitUntil(async () => !(await l.targets()).some((t) => t.url.endsWith("/a-only")), "A's window to close");
  assert.ok((await l.targets()).some((t) => t.url.endsWith("/b-only")));
  assert.match(await b.text("browser_navigate", { url: `${l.base}/b-again` }), /b-again/);
});

lab("browser_close, then a new call, gets a fresh window", async (l) => {
  const a = await l.wrapper("A");
  await a.text("browser_navigate", { url: `${l.base}/one` });
  const first = l.studio.of("A").find((m) => m.type === "page");
  const firstWindow = await l.windowOf(first.targetId);
  await a.text("browser_close");
  await l.studio.waitFor((m) => m.session === "A" && m.type === "pageGone" && m.targetId === first.targetId, "pageGone");
  await waitUntil(async () => !(await l.targets()).some((t) => t.id === first.targetId), "the old window to close");
  await a.text("browser_navigate", { url: `${l.base}/two` });
  const second = l.studio.of("A").filter((m) => m.type === "page").at(-1);
  assert.notEqual(second.targetId, first.targetId);
  assert.notEqual(await l.windowOf(second.targetId), firstWindow);
  assert.equal((await a.tabs()).length, 1);
});

lab("killing Chromium doesn't end the wrapper, and the next call after a restart works", async (l) => {
  const a = await l.wrapper("A");
  await a.text("browser_navigate", { url: `${l.base}/one` });
  const page = l.studio.of("A").find((m) => m.type === "page");
  await l.stopChromium("SIGKILL");
  await l.studio.waitFor((m) => m.session === "A" && m.type === "pageGone" && m.targetId === page.targetId, "pageGone after Chromium died");
  assert.equal(a.child.exitCode, null, "the wrapper stays alive");
  const down = await a.call("browser_navigate", { url: `${l.base}/two` });
  assert.equal(down.isError, true, "a call while Chromium is gone is an error, not a hang");
  assert.equal(a.child.exitCode, null);
  await l.startChromium();
  assert.match(await a.text("browser_navigate", { url: `${l.base}/three` }), /three/);
  assert.ok(l.studio.of("A").filter((m) => m.type === "page").length >= 2, "the new window was reported");
});

lab("the socket carries hello, pages and tool calls in order, and a restarted Studio gets them again", async (l) => {
  const a = await l.wrapper("A");
  await l.studio.waitFor((m) => m.type === "hello", "hello");
  await a.text("browser_navigate", { url: `${l.base}/one` });
  const kinds = l.studio.of("A").map((m) => (m.type === "tool" ? `tool:${m.name}:${m.phase}` : m.type));
  assert.deepEqual(kinds, ["hello", "tool:browser_navigate:start", "page", "tool:browser_navigate:end"]);
  const hello = l.studio.of("A")[0];
  assert.equal(hello.claudePid, process.pid);
  assert.equal(hello.wrapperPid, a.child.pid);
  assert.equal(hello.cwd, process.cwd());
  const page = l.studio.of("A")[2];
  assert.equal(page.adopted, false);

  // Studio restarts at another path while a slow call is in flight: the wrapper reconnects with hello, its pages, then a
  // start for the call still running (the earlier events are gone, not replayed), and the end when it finishes.
  const second = await studioSocket(path.join(l.dir, "b.sock"));
  try {
    await l.studio.close();
    l.useSocket(second.file);
    const slow = a.text("browser_wait_for", { time: 3 });
    await slow;
    const again = second.log.map((m) => (m.type === "tool" ? `tool:${m.name}:${m.phase}` : m.type));
    assert.deepEqual(again, ["hello", "page", "tool:browser_wait_for:start", "tool:browser_wait_for:end"], again.join(" "));
    assert.equal(second.log[1].targetId, page.targetId);
    assert.equal(a.stderr(), "");
  } finally { await second.close(); }
});

lab("hello.cwd is CLAUDE_PROJECT_DIR when set", async (l) => {
  const dir = path.join(l.dir, "project");
  await l.wrapper("A", { env: { CLAUDE_PROJECT_DIR: dir } });
  const hello = await l.studio.waitFor((m) => m.type === "hello", "hello");
  assert.equal(hello.cwd, dir);
});

lab("a tool call with no Studio at all works and leaves nothing queued", async (l) => {
  l.useSocket(path.join(l.dir, "nobody-home.sock"));
  const a = await l.wrapper("A");
  assert.match(await a.text("browser_navigate", { url: `${l.base}/one` }), /one/);
  assert.match(await a.text("browser_snapshot"), /page \/one/);
  assert.deepEqual(l.studio.log, []);
  l.useSocket(l.studio.file);
  await l.studio.waitFor((m) => m.type === "hello", "hello once Studio is there", 30_000);
  await sleep(500);
  // hello and the page that exists; no tool event from the calls made while nobody listened
  assert.deepEqual(l.studio.of("A").map((m) => m.type), ["hello", "page"]);
});

lab("a page is reported once per connection", async (l) => {
  const a = await l.wrapper("A");
  await a.text("browser_navigate", { url: `${l.base}/one` });
  await a.text("browser_navigate", { url: `${l.base}/two` });
  await a.text("browser_tabs", { action: "list" });
  assert.equal(l.studio.of("A").filter((m) => m.type === "page").length, 1);
});

lab("parallel first calls share one window", async (l) => {
  const a = await l.wrapper("A");
  const [one, two] = await Promise.all([a.call("browser_navigate", { url: `${l.base}/p1` }), a.call("browser_navigate", { url: `${l.base}/p2` })]);
  // Both navigate the one tab they share, so the second can abort the first (net::ERR_ABORTED): that is not a failure here.
  assert.ok(!one.isError || !two.isError, JSON.stringify([one, two]));
  for (const r of [one, two]) if (r.isError) assert.match(JSON.stringify(r), /ERR_ABORTED/);
  const pages = l.studio.of("A").filter((m) => m.type === "page");
  assert.equal(pages.length, 1, JSON.stringify(pages));
  assert.equal((await a.tabs()).length, 1);
  assert.equal((await l.targets()).filter((t) => /\/p[12]$/.test(t.url)).length, 1, "one page, not two windows");
  assert.equal(a.stderr(), "");
});

lab("a new tab opens in the client's own window", async (l) => {
  const a = await l.wrapper("A");
  await a.text("browser_navigate", { url: `${l.base}/one` });
  await a.text("browser_tabs", { action: "new", url: `${l.base}/two` });
  await waitUntil(async () => (await a.tabs()).length === 2, "two tabs");
  const pages = l.studio.of("A").filter((m) => m.type === "page");
  assert.equal(pages.length, 2, JSON.stringify(pages));
  assert.equal(pages[1].openerId, pages[0].targetId);
  assert.equal(await l.windowOf(pages[1].targetId), await l.windowOf(pages[0].targetId), "same window");
  assert.match(await a.text("browser_snapshot"), /page \/two/, "the new tab is the current one");
  assert.equal(a.stderr(), "");
});

for (const [route, why] of [["sandboxed", "a Content-Security-Policy sandbox"], ["nulled", "a page that makes window.open return null"]])
  lab(`a new tab falls back to a window at once when ${why} blocks the popup`, async (l) => {
    const a = await l.wrapper("A");
    await a.text("browser_navigate", { url: `${l.base}/${route}` });
    const started = Date.now();
    await a.text("browser_tabs", { action: "new", url: `${l.base}/two` });
    assert.ok(Date.now() - started < 3000, `took ${Date.now() - started} ms`);
    await waitUntil(async () => (await a.tabs()).length === 2, "two tabs");
    assert.equal(l.studio.of("A").filter((m) => m.type === "page").length, 2);
    assert.match(a.stderr(), /opening a window instead/);
  });

lab("parallel new tabs each get a tab, in one window, with no fallback", async (l) => {
  const a = await l.wrapper("A");
  await a.text("browser_navigate", { url: `${l.base}/one` });
  const started = Date.now();
  const results = await Promise.all([1, 2, 3].map((n) => a.call("browser_tabs", { action: "new", url: `${l.base}/new${n}` })));
  assert.ok(results.every((r) => !r.isError), JSON.stringify(results));
  assert.ok(Date.now() - started < 4000, `took ${Date.now() - started} ms`);
  const tabs = (await a.tabs()).join("\n");
  assert.equal((await a.tabs()).length, 4, tabs);
  for (const n of [1, 2, 3]) assert.match(tabs, new RegExp(`new${n}`));
  const pages = l.studio.of("A").filter((m) => m.type === "page");
  assert.equal(pages.length, 4);
  assert.equal(new Set(await Promise.all(pages.map((m) => l.windowOf(m.targetId)))).size, 1, "one window");
  assert.equal(a.stderr(), "", "no fallback");
});

lab("a popup that turns up after the fallback is closed, not left in the extra window", async (l) => {
  const a = await l.wrapper("A");
  await a.text("browser_navigate", { url: `${l.base}/late` });
  const before = (await l.targets()).length;
  await a.text("browser_tabs", { action: "new", url: `${l.base}/two` }); // gives up after 5 s and opens a window
  assert.equal((await l.targets()).length, before + 1, "the fallback window");
  await sleep(4000); // the popup arrives at 7 s
  await waitUntil(async () => (await l.targets()).length === before + 1, "the late popup to be closed or never to show", 5000);
  assert.equal((await a.tabs()).length, 2);
  assert.equal(l.studio.of("A").filter((m) => m.type === "page").length, 2);
});

lab("a tab the user opened and we adopted is never the opener of a new tab", async (l) => {
  const a = await l.wrapper("A");
  const foreign = await rawCdp(l.port);
  try {
    await a.text("browser_navigate", { url: `${l.base}/one` });
    const own = l.studio.of("A").find((m) => m.type === "page");
    await foreign.send("Target.activateTarget", { targetId: own.targetId });
    const { targetId: adopted } = await foreign.send("Target.createTarget", { url: `${l.base}/mine-now` });
    await l.studio.waitFor((m) => m.session === "A" && m.type === "page" && m.targetId === adopted, "A to adopt the tab");
    await a.text("browser_tabs", { action: "close", index: 0 }); // only the adopted tab is left
    await l.studio.waitFor((m) => m.session === "A" && m.type === "pageGone" && m.targetId === own.targetId, "own page gone");
    await a.text("browser_tabs", { action: "new", url: `${l.base}/two` });
    const fresh = l.studio.of("A").filter((m) => m.type === "page").at(-1);
    assert.notEqual(fresh.targetId, adopted);
    assert.equal(fresh.openerId, undefined, "not opened by the adopted tab");
    assert.notEqual(await l.windowOf(fresh.targetId), await l.windowOf(adopted));
    assert.equal(a.stderr(), "");
  } finally { foreign.close(); }
});

lab("the browser dying while a window is being made fails the call at once", async (l) => {
  const a = await l.wrapper("A");
  for (const delay of [0, 10, 25, 50, 100]) {
    await a.text("browser_navigate", { url: `${l.base}/warm` }); // connected, with a window
    await a.text("browser_close"); // no page now, so the next call makes a window
    const started = Date.now();
    const call = a.call("browser_navigate", { url: `${l.base}/one` });
    await sleep(delay);
    await l.stopChromium("SIGKILL");
    await call.catch(() => {});
    assert.ok(Date.now() - started < 10_000, `a call ended ${Date.now() - started} ms after the browser died (delay ${delay}); stderr: ${a.stderr()}`);
    assert.equal(a.child.exitCode, null, "the wrapper stays alive");
    await l.startChromium();
  }
  assert.match(await a.text("browser_navigate", { url: `${l.base}/last` }), /last/);
});

lab("stdin closing after Chromium is gone exits promptly", async (l) => {
  const a = await l.wrapper("A");
  await a.text("browser_navigate", { url: `${l.base}/one` });
  const page = l.studio.of("A").find((m) => m.type === "page");
  await l.stopChromium("SIGKILL");
  await l.studio.waitFor((m) => m.type === "pageGone" && m.targetId === page.targetId, "pageGone");
  const started = Date.now();
  a.child.stdin.end();
  await Promise.race([a.exited, sleep(10_000)]);
  assert.equal(a.child.exitCode, 0);
  assert.ok(Date.now() - started < 3000, `took ${Date.now() - started} ms`);
});

lab("a different @playwright/mcp version is warned about, not refused", async (l) => {
  // A stand-in install: the real package under another version number.
  const mcpDir = path.dirname(createRequire(path.join(home, "package.json")).resolve("@playwright/mcp"));
  const fake = path.join(l.dir, "fake-ab");
  fs.mkdirSync(path.join(fake, "node_modules/@playwright/mcp"), { recursive: true });
  fs.writeFileSync(path.join(fake, "package.json"), "{}");
  fs.writeFileSync(path.join(fake, "node_modules/@playwright/mcp/package.json"), JSON.stringify({ name: "@playwright/mcp", version: "0.0.1" }));
  fs.writeFileSync(path.join(fake, "node_modules/@playwright/mcp/index.js"), `module.exports = require(${JSON.stringify(mcpDir)});`);
  fs.symlinkSync(path.join(home, "node_modules/playwright-core"), path.join(fake, "node_modules/playwright-core"));
  const drifted = await l.wrapper("drift", { ab: fake });
  assert.ok((await drifted.listTools()).length > 10, "still serves tools");
  assert.match(drifted.stderr(), /@playwright\/mcp 0\.0\.1 is installed but this wrapper was written for 0\.0\.83/);
  const fine = await l.wrapper("fine");
  await fine.listTools();
  assert.equal(fine.stderr(), "", "no warning on the pinned version");
});

lab("tools/list matches what Playwright's cli.js lists", async (l) => {
  const cli = path.join(path.dirname(createRequire(path.join(home, "package.json")).resolve("@playwright/mcp")), "cli.js");
  const out = path.join(l.dir, "out", "cli");
  const child = spawn(process.execPath, [cli, "--cdp-endpoint", `http://127.0.0.1:${await freePort()}`, "--output-dir", out], { stdio: ["pipe", "pipe", "ignore"] });
  children.add(child);
  try {
    const answer = new Promise((resolve) => {
      let buf = "";
      child.stdout.on("data", (d) => {
        buf += d;
        for (let i; (i = buf.indexOf("\n")) >= 0; ) {
          const m = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
          if (m.id === 2) resolve(m.result.tools);
        }
      });
    });
    const send = (m) => child.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\n");
    send({ id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "parity", version: "1" } } });
    send({ method: "notifications/initialized" });
    send({ id: 2, method: "tools/list" });
    const expected = await answer;
    const wrapper = await l.wrapper("A");
    const actual = await wrapper.listTools();
    const byName = (tools) => Object.fromEntries(tools.map((t) => [t.name, t]));
    assert.ok(actual.length > 10);
    assert.deepEqual(Object.keys(byName(actual)).sort(), Object.keys(byName(expected)).sort());
    assert.deepEqual(byName(actual), byName(expected));
  } finally { child.kill("SIGTERM"); }
});

lab("a screenshot response still has a Page URL and an output path the work observer parses", async (l) => {
  const a = await l.wrapper("A");
  const navigated = await a.text("browser_navigate", { url: `${l.base}/shot` });
  assert.match(navigated, /Page URL: \S+\/shot/, "tool responses still carry Page URL");
  const shot = await a.text("browser_take_screenshot", {});
  // WorkObserver's pattern: a markdown link to a png/jpeg/webp, relative to the MCP's folder or absolute.
  const link = shot.match(/\]\(([^)\s]+\.(?:png|jpe?g|webp))\)/i);
  assert.ok(link, shot);
  const file = path.isAbsolute(link[1]) ? link[1] : path.resolve(process.cwd(), link[1]);
  const inOutputDir = path.join(l.dir, "out", "A", path.basename(link[1]));
  assert.ok(fs.existsSync(file) || fs.existsSync(inOutputDir), `${link[1]} exists (${file} or ${inOutputDir})`);
});
