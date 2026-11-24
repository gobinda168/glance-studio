#!/usr/bin/env node
// One Playwright MCP server per Claude session over the shared Glance browser (CDP): each session gets a window of its
// own and sees only its own pages, cookies and sign-ins stay shared. It reports what it owns to Glance Studio over a
// unix socket (spec docs/superpowers/specs/2026-11-01-command-center-design.md §4.1).
//
//   node session-mcp.mjs --cdp-endpoint http://127.0.0.1:PORT [--cdp-timeout MS] [--output-dir DIR]
//
//   env GLANCE_AB               the agent-browser folder where @playwright/mcp is installed (required)
//   env GLANCE_BROWSER_OPTIONS  path of options.json; its "socket" is Studio's listener, re-read on every attempt
//   env GLANCE_CLAUDE_PID       the claude process (falls back to this process's parent)
//   env CLAUDE_PROJECT_DIR      the session's folder for hello.cwd (falls back to this process's cwd)
//
// Socket protocol, one JSON object per line, one lasting connection. On every connect: hello, a page for each owned
// target, then a tool start for each call in flight. Nothing is queued while Studio is away: a target is announced once
// per connection and what happened meanwhile is simply not reported.
//   {"type":"hello","wrapperPid":1,"claudePid":2,"session":"uuid","cwd":"/path"}
//   {"type":"page","targetId":"T","openerId":"T?","adopted":false}     openerId only when there is one
//   {"type":"pageGone","targetId":"T"}
//   {"type":"tool","name":"browser_click","phase":"start"|"end"}
//
// The browser is connected on the first tool call, never at startup (a session that never browses must not open
// Chromium), and again after it went away. This process exits only when stdin closes, on a signal or on a crash (which
// closes this client's windows). stdout is the MCP stream: everything else goes to stderr.
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import net from "node:net";
import path from "node:path";

const log = (...args) => console.error("session-mcp:", ...args);

const AB = process.env.GLANCE_AB;
if (!AB) {
  log("GLANCE_AB (the agent-browser folder) is required");
  process.exit(1);
}
const req = createRequire(`${AB}/package.json`);
const mcpEntry = req.resolve("@playwright/mcp");
const { createConnection } = req("@playwright/mcp");
const { chromium } = createRequire(mcpEntry)("playwright-core"); // the copy the MCP itself uses

// The facade below leans on the MCP's internals (the context it asks for, the Tab/page listeners, once("close")), so a
// different version may break it. Keep in step with GLANCE_PINS.mcp in agent-browser.mjs.
const MCP_PIN = "0.0.83";
try {
  const version = JSON.parse(fs.readFileSync(path.join(path.dirname(mcpEntry), "package.json"), "utf8")).version;
  if (version !== MCP_PIN)
    log(`warning: @playwright/mcp ${version} is installed but this wrapper was written for ${MCP_PIN}; windows per session may misbehave until session-mcp.mjs is checked against it`);
} catch {}

const argv = process.argv.slice(2);
const opt = (name) => (argv.includes(name) ? argv[argv.indexOf(name) + 1] : undefined);
const endpoint = opt("--cdp-endpoint");
const cdpTimeout = Number(opt("--cdp-timeout")) || 30000;
const optionsPath = process.env.GLANCE_BROWSER_OPTIONS;
const claudePid = Number(process.env.GLANCE_CLAUDE_PID) || process.ppid;

// Closing or closed targets fail CDP calls in the ordinary course of things; those aren't worth a line.
const targetGone = (e) => /closed|No target|not found|No window|Session with given id|disconnected|went away/i.test(String(e?.message ?? e));

// ---- Studio socket -----------------------------------------------------------------------------------------------

let sock = null; // connected socket
let dialing = false;
let nextTry = 0;
let backoff = 500;
let retryTimer;
const announced = new Set(); // targets reported on the current connection

function socketPath() {
  if (!optionsPath) return null;
  try { return JSON.parse(fs.readFileSync(optionsPath, "utf8")).socket || null; } catch { return null; }
}

function write(message) { sock.write(JSON.stringify(message) + "\n"); }

function announce(targetId) {
  if (!sock || announced.has(targetId)) return;
  announced.add(targetId);
  const opener = openerOf.get(targetId);
  write({ type: "page", targetId, ...(opener ? { openerId: opener } : {}), adopted: adoptedIds.has(targetId) });
}

function announceGone(targetId) {
  if (sock && announced.delete(targetId)) write({ type: "pageGone", targetId });
}

/// Tool events go out only while connected: a start or end from before a reconnect would be stale.
function reportTool(name, phase) {
  if (sock) write({ type: "tool", name, phase });
}

function scheduleRetry() {
  clearTimeout(retryTimer);
  if (leaving || !optionsPath) return;
  retryTimer = setTimeout(connectSocket, Math.max(0, nextTry - Date.now()));
  retryTimer.unref();
}

function failed() {
  nextTry = Date.now() + backoff;
  backoff = Math.min(backoff * 2, 15000);
  scheduleRetry();
}

/// Never blocks anything: a tool call only kicks this off.
function connectSocket() {
  if (sock || dialing || leaving || !optionsPath || Date.now() < nextTry) return;
  const file = socketPath();
  if (!file) return failed();
  dialing = true;
  const s = net.createConnection(file);
  s.on("error", () => {});
  s.on("data", () => {}); // Studio sends nothing; keep the stream flowing
  s.once("connect", () => {
    dialing = false;
    backoff = 500;
    sock = s;
    announced.clear();
    write({ type: "hello", wrapperPid: process.pid, claudePid, session: process.env.CLAUDE_CODE_SESSION_ID, cwd: process.env.CLAUDE_PROJECT_DIR || process.cwd() });
    for (const targetId of owned) announce(targetId);
    for (const name of inflight.values()) reportTool(name, "start");
  });
  s.once("close", () => {
    const wasConnected = sock === s;
    if (wasConnected) { sock = null; announced.clear(); }
    if (wasConnected || dialing) { dialing = false; failed(); }
  });
}

// ---- Owned pages -------------------------------------------------------------------------------------------------

const owned = new Set(); // target ids
const adoptedIds = new Set(); // owned target ids the user opened in this client's window
const openerOf = new Map(); // target id -> opener target id
const ownedWindows = new Set(); // window ids this client's pages live in
const mine = new Set(); // Page objects
const pageById = new Map(); // target id -> Page, once claimed
const waiters = new Map(); // target id of a window being created -> {resolve, reject}
const tabWaiters = new Map(); // window name of a tab being opened -> {resolve, reject}
const abandoned = new Set(); // window names of tabs we gave up on; one that still turns up is closed
const pending = new Set(); // in-flight createTarget promises
const pageListeners = new Set();
const closeListeners = new Set(); // the MCP backend's once("close") hooks
let leaving = false;
let conn = null; // { browser, real, cdp, facade }
let connectPromise = null;
let creatingWindow = null; // the window being created for a client that owns no page yet

function forget(targetId) {
  const page = pageById.get(targetId);
  if (page) mine.delete(page);
  pageById.delete(targetId);
  adoptedIds.delete(targetId);
  openerOf.delete(targetId);
  if (owned.delete(targetId)) announceGone(targetId);
}

async function infoOf(c, page) {
  const s = await c.real.newCDPSession(page);
  try { return (await s.send("Target.getTargetInfo")).targetInfo; } finally { await s.detach().catch(() => {}); }
}

/// Playwright leaves a send that is in flight when the browser dies pending forever; this fails it with the connection.
const alive = (c, promise) => Promise.race([promise, c.dead]);

async function windowOf(c, targetId) {
  try { return (await alive(c, c.cdp.send("Browser.getWindowForTarget", { targetId }))).windowId; } catch (e) {
    if (!targetGone(e)) log(`Browser.getWindowForTarget(${targetId}) failed: ${e?.message ?? e}`);
    return undefined;
  }
}

/// A promise that settles when claim() or retire() settles it, or fails after `ms` with something to go on.
function expect(map, key, what, ms = 15000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      map.delete(key);
      reject(Object.assign(new Error(`${what} (see the session-mcp log on stderr)`), { timedOut: true }));
    }, ms);
    map.set(key, {
      resolve: (v) => { clearTimeout(timer); map.delete(key); resolve(v); },
      reject: (e) => { clearTimeout(timer); map.delete(key); reject(e); },
    });
  });
}

/// Every client sees every page event of the shared context: claim the ones that are ours.
async function onPage(c, page) {
  try {
    const info = await infoOf(c, page);
    await Promise.allSettled([...pending]); // a createTarget of ours may still be returning its id
    if (c !== conn) return;
    const { targetId, openerId } = info;
    let adopted = false;
    let windowId;
    let tabName;
    if (!owned.has(targetId)) {
      if (openerId && owned.has(openerId)) {
        // a target=_blank page or popup of ours, or the tab openTab asked for (found by the window name it was given)
        if (tabWaiters.size || abandoned.size) {
          tabName = await page.evaluate("window.name").catch(() => "");
          if (abandoned.delete(tabName)) {
            await alive(c, c.cdp.send("Target.closeTarget", { targetId })).catch(() => {}); // late, and its tab was made another way
            return;
          }
        }
      } else {
        // not opened by us: ours only if the user opened it in a window of ours (⌘T), or a client of Studio's did
        windowId = await windowOf(c, targetId);
        if (windowId === undefined || !ownedWindows.has(windowId)) return;
        adopted = true;
      }
      owned.add(targetId);
    }
    if (adopted) adoptedIds.add(targetId);
    if (openerId) openerOf.set(targetId, openerId);
    mine.add(page);
    pageById.set(targetId, page);
    page.once("close", () => forget(targetId));
    announce(targetId);
    for (const fn of [...pageListeners]) fn(page); // the MCP Context makes its Tab first...
    waiters.get(targetId)?.resolve(page); // ...then newPage() resolves
    if (tabName) tabWaiters.get(tabName)?.resolve(page);
    windowId ??= await windowOf(c, targetId);
    if (windowId !== undefined && c === conn) ownedWindows.add(windowId);
  } catch (e) {
    if (c === conn && !page.isClosed() && !targetGone(e)) log(`could not look at a new page: ${e?.stack ?? e}`);
  }
}

// browser_close disposes the MCP Context (which removes its "page" listener) but closes nothing: with a facade that
// means "close this client's windows and start a fresh backend", which we get by firing the backend's "close" hook.
// When the browser itself went away there is nothing to close.
function retire(closeWindows, why) {
  const targets = [...owned];
  const cdp = conn?.cdp;
  for (const targetId of targets) {
    forget(targetId);
    if (closeWindows) cdp?.send("Target.closeTarget", { targetId }).catch(() => {});
  }
  owned.clear(); mine.clear(); pageById.clear(); adoptedIds.clear(); openerOf.clear(); ownedWindows.clear(); pageListeners.clear();
  for (const w of [...waiters.values(), ...tabWaiters.values()]) w.reject(new Error(why));
  const hooks = [...closeListeners]; closeListeners.clear();
  for (const fn of hooks) fn();
}

// Windows. A client owns one: parallel first calls share the window being created, and later tabs open in it.
async function createWindow(c) {
  // focus: false so a new window doesn't take key focus from the terminal the user types in
  const create = alive(c, c.cdp.send("Target.createTarget", { url: "about:blank", newWindow: true, focus: false }))
    .then((r) => (owned.add(r.targetId), r.targetId));
  pending.add(create);
  const targetId = await create.finally(() => pending.delete(create));
  const windowId = await windowOf(c, targetId);
  if (windowId !== undefined) ownedWindows.add(windowId);
  if (c !== conn) throw new Error("the browser went away");
  return pageById.get(targetId) ?? (await expect(waiters, targetId, `the new window ${targetId} never produced a page`)); // the page event may have got here first
}

const ownPages = () => [...pageById].filter(([id, page]) => !adoptedIds.has(id) && !page.isClosed()).map(([, page]) => page);

function windowFor(c) { return (creatingWindow ??= createWindow(c).finally(() => { creatingWindow = null; })); }

function abandon(name) {
  abandoned.add(name);
  setTimeout(() => abandoned.delete(name), 60_000).unref();
}

let tabQueue = Promise.resolve();
/// A new tab in this client's window, one at a time.
function openTab(c) {
  const run = tabQueue.then(() => openTabNow(c));
  tabQueue = run.catch(() => {});
  return run;
}

/// Opened by one of the client's own pages (never one the user opened and we adopted: no script runs in those), so it
/// lands beside it and counts as its popup. It's given a unique window name, which is how its page is told from any
/// other popup. A page that won't let it open, or one that never shows up, costs a window instead of a tab.
async function openTabNow(c) {
  const opener = ownPages().at(-1);
  if (!opener) return windowFor(c);
  const name = `glance-tab-${randomUUID()}`;
  const fallBack = (why) => {
    abandon(name);
    log(`${why}; opening a window instead`);
    return windowFor(c);
  };
  let s, arrived;
  try {
    s = await alive(c, c.real.newCDPSession(opener));
    arrived = expect(tabWaiters, name, "the new tab never appeared", 5000);
    arrived.catch(() => {}); // awaited below; this keeps an early failure from being unhandled
    const { result } = await alive(c, s.send("Runtime.evaluate", {
      expression: `!!window.open('about:blank', ${JSON.stringify(name)})`, userGesture: true, returnByValue: true,
    }));
    if (result?.value !== true) throw new Error("the page wouldn't open a new tab");
  } catch (e) {
    tabWaiters.get(name)?.reject(e);
    if (conn !== c) throw e;
    return fallBack(e.message);
  } finally { await s?.detach().catch(() => {}); }
  try { return await arrived; } catch (e) {
    if (!e.timedOut || conn !== c) throw e;
    return fallBack(e.message);
  }
}

const eventNames = new Set(["on", "addListener", "once", "off", "removeListener"]);

function makeFacade(c) {
  const facade = new Proxy(c.real, {
    get(target, key) {
      if (key === "pages") return () => c.real.pages().filter((p) => mine.has(p));
      if (key === "newPage")
        return () => {
          return mine.size > 0 ? openTab(c) : windowFor(c);
        };
      if (eventNames.has(key))
        return (event, fn) => {
          const removing = key === "off" || key === "removeListener";
          if (event === "page") {
            if (removing) { if (pageListeners.delete(fn)) retire(true, "the browser session was closed"); } else pageListeners.add(fn); // once() on "page" is unused
          } else if (event === "close") {
            removing ? closeListeners.delete(fn) : closeListeners.add(fn);
          } else c.real[key](event, fn);
          return facade;
        };
      const value = Reflect.get(target, key, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  return facade;
}

function ensureBrowser() {
  if (conn) return Promise.resolve(conn.facade);
  connectPromise ??= connectBrowser().finally(() => { connectPromise = null; });
  return connectPromise;
}

async function connectBrowser() {
  if (!endpoint) throw new Error("session-mcp: no --cdp-endpoint");
  const browser = await chromium.connectOverCDP(endpoint, { timeout: cdpTimeout });
  try {
    const real = browser.contexts()[0]; // the default context: shared cookies / lasting profile
    if (!real) throw new Error("the browser has no default context");
    const cdp = await browser.newBrowserCDPSession();
    const c = { browser, real, cdp, facade: null, dead: null, die: null };
    c.dead = new Promise((_, reject) => { c.die = reject; });
    c.dead.catch(() => {}); // only ever raced
    c.facade = makeFacade(c);
    // Playwright dismisses a dialog nobody listens for. This process sees every client's pages, so without a listener it
    // would dismiss the other clients' dialogs before they can handle them. (Their own Tab listener does the handling.)
    real.on("dialog", () => {});
    real.on("page", (page) => onPage(c, page));
    browser.on("disconnected", () => {
      if (conn !== c) return;
      c.die(new Error("the browser went away"));
      retire(false, "the browser went away");
      conn = null; // the next tool call connects again
    });
    conn = c;
    return c.facade;
  } catch (e) {
    // A half-made connection would count as a client of the relay and hold off the broker's idle quit.
    await browser.close().catch(() => {});
    throw e;
  }
}

// ---- MCP over stdio ----------------------------------------------------------------------------------------------

const inflight = new Map(); // JSON-RPC id -> tool name

// Newline-delimited JSON-RPC on stdio (what the SDK's StdioServerTransport does), so the wrapper needs no SDK. Tool
// calls are reported to Studio on their way in (start) and out (end).
let buffer = "";
const transport = {
  onmessage: undefined, onclose: undefined, onerror: undefined,
  async start() {
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      buffer += chunk;
      for (let i; (i = buffer.indexOf("\n")) >= 0; ) {
        const line = buffer.slice(0, i).trim(); buffer = buffer.slice(i + 1);
        if (!line) continue;
        let message;
        try { message = JSON.parse(line); } catch (e) { transport.onerror?.(e); continue; }
        incoming(message);
        transport.onmessage?.(message);
      }
    });
    process.stdin.on("end", () => transport.onclose?.());
  },
  send(message) {
    outgoing(message);
    return new Promise((resolve) => process.stdout.write(JSON.stringify(message) + "\n", resolve));
  },
  close: async () => {},
};

function incoming(message) {
  if (message?.method === "tools/call" && message.id !== undefined) {
    const name = message.params?.name;
    inflight.set(message.id, name);
    connectSocket();
    reportTool(name, "start");
  } else if (message?.method === "notifications/cancelled" && inflight.has(message.params?.requestId)) {
    finished(message.params.requestId);
  }
}

function outgoing(message) {
  if (message?.id !== undefined && ("result" in message || "error" in message)) finished(message.id);
}

function finished(id) {
  if (!inflight.has(id)) return;
  const name = inflight.get(id);
  inflight.delete(id);
  reportTool(name, "end");
}

async function leave(code = 0) {
  if (leaving) return; leaving = true;
  clearTimeout(retryTimer);
  if (conn)
    await Promise.race([
      Promise.all([...owned].map((targetId) => conn.cdp.send("Target.closeTarget", { targetId }).catch(() => {}))),
      new Promise((r) => setTimeout(r, 3000)),
    ]);
  sock?.end();
  process.exit(code); // drops the CDP connection; Chromium keeps running
}
transport.onclose = () => leave();
for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(signal, () => leave());
process.stdout.on("error", () => leave());
process.on("uncaughtException", (e) => { log("crashed:", e?.stack ?? e); leave(1); });
process.on("unhandledRejection", (e) => { log("crashed (unhandled rejection):", e?.stack ?? e); leave(1); });

const server = await createConnection({ outputDir: opt("--output-dir") }, ensureBrowser);
await server.connect(transport);
connectSocket(); // hello at startup; pages follow when there are any
