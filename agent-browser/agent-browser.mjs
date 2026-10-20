#!/usr/bin/env node
// Glance browser broker (spec docs/superpowers/specs/2026-10-14-agent-browser-design.md). Glance Studio runs it
// with the user's node; it has no dependencies of its own. It runs headless Chromium browsers with Playwright's
// launchServer:
//   - Glance browser, Glance's pinned Playwright, for the glance-browser MCP (CDP on --cdp-port);
//   - one test browser per Playwright version that connects to --client-port (PW_TEST_CONNECT_WS_ENDPOINT), since a
//     Playwright client only talks to a server of its own version.
// Studio reads one JSON line per event on stdout and sends commands on stdin: claude, stop, resume, quit.
//
//   node agent-browser.mjs --home <folder> --client-port <port> --cdp-port <port>
//   node agent-browser.mjs install --home <folder>     installs Glance's pinned packages and Chromium, then exits

import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import { createRequire } from "node:module";
import net from "node:net";
import path from "node:path";
import readline from "node:readline";

// Keep in step with AgentBrowserPackages in Sources/GlanceCore/AgentBrowser/AgentBrowserCore.swift.
export const GLANCE_PINS = { playwrightCore: "1.64.1", mcp: "0.0.83" };
const STOPPED = "The user stopped the Glance browser";
const CHROMIUM_ONLY = "The Glance browser runs Chromium only; set the project to chromium";

function args(argv) {
  const out = { command: "serve" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "install") out.command = "install";
    else if (a === "--home") out.home = argv[++i];
    else if (a === "--client-port") out.clientPort = Number(argv[++i]);
    else if (a === "--cdp-port") out.cdpPort = Number(argv[++i]);
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

/** Installs playwright-core@version (and, for Glance's pin, @playwright/mcp) plus its headless Chromium. */
export function ensurePlaywright(home, version) {
  const folder = folderFor(home, version);
  if (installedVersion(folder) === version && fs.existsSync(path.join(folder, ".chromium-ok"))) return Promise.resolve(folder);
  if (installs.has(folder)) return installs.get(folder);
  const work = (async () => {
    fs.mkdirSync(folder, { recursive: true });
    const unlock = await lock(folder);
    try {
      if (installedVersion(folder) === version && fs.existsSync(path.join(folder, ".chromium-ok"))) return folder;
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
  // Without .chromium-ok an earlier install didn't finish: its node_modules may be half written, so start over.
  fs.rmSync(path.join(folder, "node_modules"), { recursive: true, force: true });
  {
    emit({ event: "installing", what: `Playwright ${version}` });
    const packages = [`playwright-core@${version}`];
    if (version === GLANCE_PINS.playwrightCore) packages.push(`@playwright/mcp@${GLANCE_PINS.mcp}`);
    const npmArgs = ["install", "--no-audit", "--no-fund", "--loglevel=error", "--save-exact", ...packages];
    await run(npm(), npmArgs, folder);
  }
  emit({ event: "installing", what: "Chromium" });
  const cli = path.join(folder, "node_modules/playwright-core/cli.js");
  try {
    await run(process.execPath, [cli, "install", "chromium-headless-shell"], folder);
  } catch {
    await run(process.execPath, [cli, "install", "chromium"], folder); // Playwright before 1.49 has no headless shell
  }
  fs.writeFileSync(path.join(folder, ".chromium-ok"), version + "\n");
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

async function launch(home, id, kind, version, cdpPort) {
  const folder = await ensurePlaywright(home, version);
  const { chromium } = createRequire(path.join(folder, "package.json"))("playwright-core");
  const port = cdpPort ?? (await freePort());
  const server = await chromium.launchServer({
    headless: true,
    args: [`--remote-debugging-port=${port}`, "--remote-debugging-address=127.0.0.1"],
  });
  const browser = { id, kind, version, cdpPort: port, server, wsEndpoint: server.wsEndpoint() };
  browsers.set(id, browser);
  server.process().once("exit", () => {
    if (browsers.get(id) === browser) {
      browsers.delete(id);
      emit({ event: "browserGone", id });
    }
  });
  emit({ event: "browser", id, kind, version, cdpPort: port });
  return browser;
}

function browser(home, id, kind, version, cdpPort) {
  if (stopped) return Promise.reject(new Error(STOPPED));
  if (browsers.has(id)) return Promise.resolve(browsers.get(id));
  if (launching.has(id)) return launching.get(id);
  const work = launch(home, id, kind, version, cdpPort).finally(() => launching.delete(id));
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
        browser(options.home, "claude", "claude", GLANCE_PINS.playwrightCore, cdpPort).catch((error) =>
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
