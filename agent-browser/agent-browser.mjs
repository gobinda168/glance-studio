#!/usr/bin/env node
// Glance browser broker (spec docs/superpowers/specs/2026-10-14-agent-browser-design.md, real windows since
// 2026-10-29). Glance Studio runs it with the user's node; it has no dependencies of its own. It runs Chromium in real,
// visible windows:
//   - Glance browser: Glance's pinned Playwright's Chromium, started directly with its own lasting profile (sign-ins
//     stay) and CDP on --cdp-port, for the glance-browser MCP;
//   - one test browser per Playwright version that connects to --client-port (PW_TEST_CONNECT_WS_ENDPOINT), through
//     Playwright's launchServer, since a Playwright client only talks to a server of its own version.
// With --engine lightpanda, Claude's browser is Lightpanda instead (headless, no window, no screenshots), downloaded
// once into <home>/lightpanda/<version>; test browsers stay Chromium (Lightpanda speaks CDP, not Playwright's protocol).
// GLANCE_AGENT_BROWSER_HEADLESS=1 runs them headless (the broker test).
// Studio reads one JSON line per event on stdout and sends commands on stdin: claude, stop, resume, quit.
//
//   node agent-browser.mjs --home <folder> --client-port <port> --cdp-port <port> [--engine chromium|lightpanda]
//   node agent-browser.mjs install --home <folder>     installs Glance's pinned packages and Chromium, then exits

import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import { createRequire } from "node:module";
import net from "node:net";
import path from "node:path";
import readline from "node:readline";

// Keep in step with AgentBrowserPackages in Sources/GlanceCore/AgentBrowser/AgentBrowserCore.swift.
export const GLANCE_PINS = { playwrightCore: "1.64.1", mcp: "0.0.83", lightpanda: "1.0.2" };
const STOPPED = "The user stopped the Glance browser";
const HEADLESS = process.env.GLANCE_AGENT_BROWSER_HEADLESS === "1";
/** How long to wait on a Chromium that is asked to quit, at each step (the test shortens it). */
const QUIT_WAIT_MS = Number(process.env.GLANCE_AGENT_BROWSER_QUIT_WAIT_MS) || 5000;
/** Marks a folder whose Playwright has its full Chromium (real windows; the headless shell can't show one). */
const CHROMIUM_OK = ".chromium-window-ok";
/** The Glance browser's DevTools port and pid, in its profile while it runs (Chromium writes its port only for 0). */
const PORT_FILE = "GlanceDevToolsPort";
const CHROMIUM_ONLY = "The Glance browser runs Chromium only; set the project to chromium";

function args(argv) {
  const out = { command: "serve", engine: "chromium" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "install") out.command = "install";
    else if (a === "--home") out.home = argv[++i];
    else if (a === "--client-port") out.clientPort = Number(argv[++i]);
    else if (a === "--cdp-port") out.cdpPort = Number(argv[++i]);
    else if (a === "--engine") out.engine = argv[++i];
    else if (a === "--session-windows") out.sessionWindows = true;
  }
  if (!out.home) throw new Error("--home is required");
  return out;
}

const emit = (event) => process.stdout.write(JSON.stringify(event) + "\n");

// ── Packages ────────────────────────────────────────────────────────────────

/** Where a Playwright version lives: Glance's pin in the home folder (beside @playwright/mcp), others in pw/<version>. */
const folderFor = (home, version) => (version === GLANCE_PINS.playwrightCore ? home : path.join(home, "pw", version));

function installedVersion(folder) {
  try {
    return JSON.parse(fs.readFileSync(path.join(folder, "node_modules/playwright-core/package.json"), "utf8")).version;
  } catch {
    return null;
  }
}

function run(command, commandArgs, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, commandArgs, { cwd, stdio: ["ignore", "pipe", "pipe"], env: process.env });
    let output = "";
    child.stdout.on("data", (d) => (output += d));
    child.stderr.on("data", (d) => (output += d));
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0 ? resolve(output) : reject(new Error(`${command} ${commandArgs.join(" ")} failed:\n${output.slice(-2000)}`)),
    );
  });
}

const npm = () => path.join(path.dirname(process.execPath), "npm");
const installs = new Map(); // folder → Promise

/** Installs playwright-core@version (and, for Glance's pin, @playwright/mcp) plus its Chromium. */
export function ensurePlaywright(home, version) {
  const folder = folderFor(home, version);
  if (installedVersion(folder) === version && fs.existsSync(path.join(folder, CHROMIUM_OK))) return Promise.resolve(folder);
  if (installs.has(folder)) return installs.get(folder);
  const work = (async () => {
    fs.mkdirSync(folder, { recursive: true });
    const unlock = await lock(folder);
    try {
      if (installedVersion(folder) === version && fs.existsSync(path.join(folder, CHROMIUM_OK))) return folder;
      await install(folder, version);
    } finally {
      unlock();
    }
    return folder;
  })().finally(() => installs.delete(folder));
  installs.set(folder, work);
  return work;
}

/** One install per folder across processes (Studio's broker and `glance agent-browser mcp` can start together). */
async function lock(folder) {
  const lockPath = path.join(folder, ".installing");
  for (;;) {
    try {
      fs.mkdirSync(lockPath);
      return () => fs.rmSync(lockPath, { recursive: true, force: true });
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      const age = Date.now() - (fs.statSync(lockPath, { throwIfNoEntry: false })?.mtimeMs ?? Date.now());
      if (age > 10 * 60_000) fs.rmSync(lockPath, { recursive: true, force: true }); // left by a crash
      else await new Promise((r) => setTimeout(r, 1000));
    }
  }
}

async function install(folder, version) {
  if (!fs.existsSync(path.join(folder, "package.json"))) {
    fs.writeFileSync(path.join(folder, "package.json"), JSON.stringify({ name: "glance-agent-browser", private: true }) + "\n");
  }
  // A folder from the headless days (.chromium-ok) has its packages: it only needs the full Chromium. Otherwise an
  // earlier install didn't finish and its node_modules may be half written, so start over.
  const packagesDone = installedVersion(folder) === version && fs.existsSync(path.join(folder, ".chromium-ok"));
  if (!packagesDone) {
    fs.rmSync(path.join(folder, "node_modules"), { recursive: true, force: true });
    emit({ event: "installing", what: `Playwright ${version}` });
    const packages = [`playwright-core@${version}`];
    if (version === GLANCE_PINS.playwrightCore) packages.push(`@playwright/mcp@${GLANCE_PINS.mcp}`);
    const npmArgs = ["install", "--no-audit", "--no-fund", "--loglevel=error", "--save-exact", ...packages];
    await run(npm(), npmArgs, folder);
  }
  emit({ event: "installing", what: "Chromium" });
  const cli = path.join(folder, "node_modules/playwright-core/cli.js");
  await run(process.execPath, [cli, "install", "chromium"], folder); // a no-op when the user already has it
  fs.writeFileSync(path.join(folder, CHROMIUM_OK), version + "\n");
}

// ── Browsers ────────────────────────────────────────────────────────────────

const browsers = new Map(); // id → { id, kind, version, cdpPort, server, wsEndpoint }
const launching = new Map(); // id → Promise
let stopped = false;

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function launch(home, id, kind, version, cdpPort, engine, sessionWindows) {
  if (kind === "claude" && engine === "lightpanda") {
    const port = cdpPort ?? (await freePort());
    const server = await lightpandaBrowser(await ensureLightpanda(home), port);
    return track({ id, kind, version: `Lightpanda ${GLANCE_PINS.lightpanda}`, cdpPort: port, server });
  }
  const folder = await ensurePlaywright(home, version);
  const { chromium } = createRequire(path.join(folder, "package.json"))("playwright-core");
  const port = cdpPort ?? (await freePort());
  const server =
    kind === "claude"
      ? await windowBrowser(chromium, path.join(home, "profile"), port, sessionWindows)
      : await chromium.launchServer({
          headless: HEADLESS,
          args: [`--remote-debugging-port=${port}`, "--remote-debugging-address=127.0.0.1"],
        });
  return track({ id, kind, version, cdpPort: port, server });
}

/** Keeps `browser` until its process exits, and tells Studio about it. */
function track({ id, kind, version, cdpPort: port, server }) {
  const browser = { id, kind, version, cdpPort: port, server, wsEndpoint: server.wsEndpoint() };
  browsers.set(id, browser);
  server.process().once("exit", () => {
    if (browsers.get(id) === browser) {
      browsers.delete(id);
      emit({ event: "browserGone", id });
    }
  });
  emit({ event: "browser", id, kind, version, cdpPort: port, pid: server.process().pid });
  return browser;
}

/**
 * The Glance browser: Chromium itself, not a Playwright server, so it's an ordinary window the user can use (DevTools,
 * sign-ins that stay in `profile`). No --enable-automation: no "controlled by automated software" bar. Returns the same
 * shape as launchServer's server for the rest of the broker. With `sessionWindows` (Command Center: a window for each
 * Claude session) Chromium also keeps painting windows another window covers, so a session's page doesn't freeze.
 */
async function windowBrowser(chromium, profile, port, sessionWindows = false) {
  fs.mkdirSync(profile, { recursive: true });
  await closeLeftover(chromium, profile);
  const flags = [
    `--remote-debugging-port=${port}`,
    "--remote-debugging-address=127.0.0.1",
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    // Chromium otherwise asks for the login keychain ("Chromium Safe Storage") to encrypt cookies and passwords, and
    // asks again whenever its binary changes (each Playwright update). Playwright's own browsers do the same.
    "--use-mock-keychain",
    ...(sessionWindows ? ["--disable-backgrounding-occluded-windows"] : []),
    ...(HEADLESS ? ["--headless=new"] : []),
  ];
  const child = spawn(chromium.executablePath(), flags, { stdio: "ignore" });
  const exited = new Promise((resolve) => child.once("exit", resolve));
  child.once("error", () => {});
  // Its DevTools server answers once Chromium is up (a profile left locked by a crash can take a few seconds).
  for (let tries = 0; ; tries++) {
    if (child.exitCode !== null) throw new Error(`Chromium quit as it started (exit ${child.exitCode})`);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (response.ok) break;
    } catch {}
    if (tries >= 100) {
      child.kill("SIGKILL");
      throw new Error("Chromium didn't open its DevTools port");
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  fs.writeFileSync(path.join(profile, PORT_FILE), `${port} ${child.pid}\n`);
  return {
    process: () => child,
    wsEndpoint: () => `http://127.0.0.1:${port}`,
    close: async () => {
      // Browser.close lets Chromium write its cookies out; a SIGTERM may not wait for that, and a sign-in is only as
      // lasting as the cookie file. The signals are the fallback, for a browser that doesn't answer; every wait is
      // bounded, since a Chromium can accept the DevTools socket and never reply.
      if (child.exitCode === null && (await askToQuit(chromium, port))) await within(exited, QUIT_WAIT_MS);
      if (child.exitCode === null) child.kill("SIGTERM"); // Chromium saves its session and quits
      await within(exited, QUIT_WAIT_MS);
      if (child.exitCode === null) child.kill("SIGKILL");
    },
  };
}

/** Resolves when `promise` does, or after `ms`, whichever comes first. */
function within(promise, ms) {
  let timer;
  return Promise.race([promise, new Promise((r) => (timer = setTimeout(r, ms)))]).finally(() => clearTimeout(timer));
}

/**
 * Asks the Chromium on `port` to quit through its DevTools port. False when nothing answers there, or not within
 * `bound` ms (a Chromium can accept the socket and stay silent). Its connection is closed either way.
 */
export async function askToQuit(chromium, port, bound = QUIT_WAIT_MS) {
  let browser;
  let gaveUp = false;
  const ask = (async () => {
    try {
      browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`, { timeout: bound });
      if (gaveUp) return false;
      const session = await browser.newBrowserCDPSession();
      await session.send("Browser.close").catch(() => {});
      return true;
    } catch {
      return false;
    } finally {
      browser?.close().catch(() => {}); // a broker that lives on mustn't keep this connection
    }
  })();
  const answered = await within(ask.then(() => true), bound);
  const result = answered ? await ask : false;
  if (!answered) {
    gaveUp = true;
    browser?.close().catch(() => {}); // frees the hung request too; a connect still pending closes itself above
  }
  return result;
}

/**
 * A Glance browser left running by a broker that died (Studio crashed) still holds the profile: a new Chromium would
 * hand its window to that one and exit. Close it through its DevTools port first.
 */
async function closeLeftover(chromium, profile) {
  let port, pid;
  try {
    [port, pid] = fs.readFileSync(path.join(profile, PORT_FILE), "utf8").trim().split(/\s+/).map(Number);
  } catch {
    return;
  }
  if (!port || !pid) return;
  // Only a browser that answers on its recorded port is ours: the pid alone may belong to another process by now.
  if (!(await askToQuit(chromium, port))) return; // nothing answers there: the file is stale
  // Its port closes before the process is done with the profile.
  const alive = () => {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  };
  for (let tries = 0; tries < 100 && alive(); tries++) await new Promise((r) => setTimeout(r, 100));
  if (alive()) process.kill(pid, "SIGKILL");
}

// ── Lightpanda ──────────────────────────────────────────────────────────────

/** The release file for this Mac, or null where Lightpanda has none. */
export function lightpandaAsset(platform = process.platform, arch = process.arch) {
  if (platform !== "darwin") return null;
  return { arm64: "lightpanda-aarch64-macos", x64: "lightpanda-x86_64-macos" }[arch] ?? null;
}

/** Lightpanda's pinned release in <home>/lightpanda/<version>, downloaded from its GitHub releases the first time. */
async function ensureLightpanda(home) {
  const version = GLANCE_PINS.lightpanda;
  const binary = path.join(home, "lightpanda", version, "lightpanda");
  if (fs.existsSync(binary)) return binary;
  const asset = lightpandaAsset();
  if (!asset) throw new Error("Lightpanda has no build for this Mac");
  emit({ event: "installing", what: `Lightpanda ${version}` });
  const response = await fetch(`https://github.com/lightpanda-io/browser/releases/download/${version}/${asset}`);
  if (!response.ok) throw new Error(`Couldn't download Lightpanda ${version} (HTTP ${response.status})`);
  fs.mkdirSync(path.dirname(binary), { recursive: true });
  const partial = binary + ".partial";
  fs.writeFileSync(partial, Buffer.from(await response.arrayBuffer()), { mode: 0o755 });
  fs.renameSync(partial, binary);
  return binary;
}

/** Lightpanda's CDP server on `port`, in launchServer's server shape. */
async function lightpandaBrowser(binary, port) {
  const child = spawn(binary, ["serve", "--host", "127.0.0.1", "--port", String(port)], {
    stdio: "ignore",
    env: { ...process.env, LIGHTPANDA_DISABLE_TELEMETRY: "true" },
  });
  const exited = new Promise((resolve) => child.once("exit", resolve));
  child.once("error", () => {});
  for (let tries = 0; ; tries++) {
    if (child.exitCode !== null) throw new Error(`Lightpanda quit as it started (exit ${child.exitCode})`);
    if (await listening(port)) break;
    if (tries >= 100) {
      child.kill("SIGKILL");
      throw new Error("Lightpanda didn't open its CDP port");
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  return {
    process: () => child,
    wsEndpoint: () => `ws://127.0.0.1:${port}`,
    close: async () => {
      if (child.exitCode === null) child.kill("SIGTERM");
      await Promise.race([exited, new Promise((r) => setTimeout(r, 3000))]);
      if (child.exitCode === null) child.kill("SIGKILL");
    },
  };
}

function listening(port) {
  return new Promise((resolve) => {
    const socket = net.connect(port, "127.0.0.1");
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("error", () => resolve(false));
  });
}

function browser(home, id, kind, version, cdpPort, engine = "chromium", sessionWindows = false) {
  if (stopped) return Promise.reject(new Error(STOPPED));
  if (browsers.has(id)) return Promise.resolve(browsers.get(id));
  if (launching.has(id)) return launching.get(id);
  const work = launch(home, id, kind, version, cdpPort, engine, sessionWindows).finally(() => launching.delete(id));
  launching.set(id, work);
  return work;
}

async function closeAll() {
  await Promise.all([...browsers.values()].map((b) => b.server.close().catch(() => {})));
}

// ── Playwright clients ──────────────────────────────────────────────────────

function refuse(socket, status, text) {
  const reason = { 400: "Bad Request", 403: "Forbidden", 500: "Internal Server Error" }[status] ?? "Error";
  socket.end(`HTTP/1.1 ${status} ${reason}\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n${text}\n`);
}

/** The client's upgrade request, sent on to the version's own server (same headers, the server's path). */
function pipeTo(endpoint, req, socket, head) {
  const url = new URL(endpoint);
  const upstream = net.connect(Number(url.port), url.hostname.replace(/^\[|\]$/g, ""));
  upstream.on("connect", () => {
    let request = `GET ${url.pathname}${url.search} HTTP/1.1\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const name = req.rawHeaders[i];
      request += `${name}: ${name.toLowerCase() === "host" ? url.host : req.rawHeaders[i + 1]}\r\n`;
    }
    upstream.write(request + "\r\n");
    if (head?.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  const close = () => {
    upstream.destroy();
    socket.destroy();
  };
  upstream.on("error", close);
  socket.on("error", close);
  upstream.on("close", close);
  socket.on("close", close);
}

export function clientServer(home) {
  const server = http.createServer((req, res) => {
    res.writeHead(400, { "Content-Type": "text/plain" });
    res.end("This is the Glance browser for Playwright clients (PW_TEST_CONNECT_WS_ENDPOINT).\n");
  });
  server.on("upgrade", async (req, socket, head) => {
    socket.on("error", () => {});
    const match = /^Playwright\/(\d+\.\d+\.\d+(?:-[\w.-]+)?)/.exec(req.headers["user-agent"] ?? "");
    if (!match) return refuse(socket, 400, "Not a Playwright client");
    const wanted = req.headers["x-playwright-browser"];
    if (wanted && wanted !== "chromium") return refuse(socket, 400, CHROMIUM_ONLY);
    if (stopped) return refuse(socket, 403, STOPPED);
    try {
      const b = await browser(home, `test-${match[1]}`, "test", match[1]);
      pipeTo(b.wsEndpoint, req, socket, head);
    } catch (error) {
      if (error.message !== STOPPED) emit({ event: "error", message: error.message });
      refuse(socket, error.message === STOPPED ? 403 : 500, error.message);
    }
  });
  return server;
}

// ── Main ────────────────────────────────────────────────────────────────────

async function serve(options) {
  const clients = clientServer(options.home);
  await new Promise((resolve) => clients.listen(options.clientPort ?? 0, "127.0.0.1", resolve));
  const cdpPort = options.cdpPort ?? (await freePort());
  emit({ event: "ready", clientPort: clients.address().port, cdpPort });

  let quitting = false;
  const quit = async () => {
    if (quitting) return;
    quitting = true;
    clients.close();
    await closeAll();
    process.exit(0);
  };
  const commands = readline.createInterface({ input: process.stdin });
  commands.on("line", async (line) => {
    switch (line.trim()) {
      case "claude":
        browser(options.home, "claude", "claude", GLANCE_PINS.playwrightCore, cdpPort, options.engine, options.sessionWindows).catch((error) =>
          emit(error.message === STOPPED ? { event: "stopped" } : { event: "error", message: error.message }),
        );
        break;
      case "stop":
        stopped = true;
        await closeAll();
        emit({ event: "stopped" });
        break;
      case "resume":
        stopped = false;
        emit({ event: "resumed" });
        break;
      case "quit":
        await quit();
        break;
    }
  });
  commands.on("close", quit); // Studio went away
  process.on("SIGTERM", quit);
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("agent-browser.mjs")) {
  const options = args(process.argv.slice(2));
  if (options.command === "install") {
    ensurePlaywright(options.home, GLANCE_PINS.playwrightCore).then(
      () => process.exit(0),
      (error) => {
        process.stderr.write(error.message + "\n");
        process.exit(1);
      },
    );
  } else {
    serve(options).catch((error) => {
      emit({ event: "error", message: error.message });
      process.exit(1);
    });
  }
}
