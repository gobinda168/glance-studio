// The extension's end of Glance Studio's editor bridge: a unix socket, one JSON object per line
// (GlanceCore's EditorBridgeMessage on the app's side).
import * as net from "node:net";
import type { ChangeMark } from "./changes";

export type BridgeMessage =
  | { type: "hello"; folder: string }
  | { type: "openTerminal"; cwd: string }
  | { type: "closeTab" }
  | { type: "askStart"; id: string; path: string; start: number; end: number; text: string; before: string; after: string; question: string }
  | { type: "askFollowUp"; id: string; question: string }
  | { type: "askStop"; id: string };

/** What Claude is doing in an inline box (GlanceCore's InlineAsk.eventObject). `done` carries the selection it was
 *  asked about, and the selection's new text when a change was asked for. */
export type AskEvent =
  | { type: "askEvent"; id: string; kind: "text"; text: string }
  | { type: "askEvent"; id: string; kind: "tool"; label: string }
  | { type: "askEvent"; id: string; kind: "done"; replacement?: string; start: number; end: number; originalText: string }
  | { type: "askEvent"; id: string; kind: "failed"; message: string };

export type AppCommand =
  | { type: "open"; path: string; line?: number; column?: number }
  | { type: "claudeChanges"; files: Record<string, ChangeMark[]> }
  | { type: "claudeFiles"; paths: string[] }
  | AskEvent;

/** Complete lines from what's pending plus a new chunk, and what's left over. Blank lines are dropped. */
export function splitLines(pending: string, chunk: string): { lines: string[]; rest: string } {
  const parts = (pending + chunk).split("\n");
  const rest = parts.pop() ?? "";
  return { lines: parts.map((l) => l.trim()).filter(Boolean), rest };
}

/** One of the app's commands, or undefined for anything malformed or unknown. */
export function decodeCommand(line: string): AppCommand | undefined {
  let value: unknown;
  try { value = JSON.parse(line); } catch { return undefined; }
  if (!value || typeof value !== "object") return undefined;
  const o = value as Record<string, unknown>;
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : undefined);
  if (o.type === "open" && typeof o.path === "string") return { type: "open", path: o.path, line: num(o.line), column: num(o.column) };
  if (o.type === "claudeChanges" && o.files && typeof o.files === "object") {
    return { type: "claudeChanges", files: o.files as Record<string, ChangeMark[]> };
  }
  if (o.type === "claudeFiles" && Array.isArray(o.paths) && o.paths.every((p) => typeof p === "string")) {
    return { type: "claudeFiles", paths: o.paths as string[] };
  }
  if (o.type === "askEvent" && typeof o.id === "string") return decodeAskEvent(o.id, o);
  return undefined;
}

function decodeAskEvent(id: string, o: Record<string, unknown>): AskEvent | undefined {
  const str = (v: unknown) => (typeof v === "string" ? v : undefined);
  const num = (v: unknown) => (typeof v === "number" && Number.isInteger(v) ? v : undefined);
  if (o.kind === "text" && str(o.text) !== undefined) return { type: "askEvent", id, kind: "text", text: o.text as string };
  if (o.kind === "tool" && str(o.label) !== undefined) return { type: "askEvent", id, kind: "tool", label: o.label as string };
  if (o.kind === "failed" && str(o.message) !== undefined) return { type: "askEvent", id, kind: "failed", message: o.message as string };
  if (o.kind === "done" && num(o.start) !== undefined && num(o.end) !== undefined && str(o.originalText) !== undefined) {
    const done: AskEvent = { type: "askEvent", id, kind: "done", start: o.start as number, end: o.end as number, originalText: o.originalText as string };
    return typeof o.replacement === "string" ? { ...done, replacement: o.replacement } : done;
  }
  return undefined;
}

export function encode(message: BridgeMessage): string {
  return JSON.stringify(message) + "\n";
}

/** Connects to the app, says hello on every (re)connect, and sends messages, keeping them while disconnected. */
export class Bridge {
  private socket?: net.Socket;
  private connected = false;
  private queue: string[] = [];
  private closed = false;
  private retry?: NodeJS.Timeout;

  constructor(private readonly socketPath: string, private readonly hello: BridgeMessage, private readonly retryMs = 2000,
              private readonly onCommand?: (command: AppCommand) => void) {
    this.connect();
  }

  send(message: BridgeMessage) {
    const line = encode(message);
    if (this.connected && this.socket) this.socket.write(line);
    else this.queue.push(line);
  }

  dispose() {
    this.closed = true;
    clearTimeout(this.retry);
    this.socket?.destroy();
  }

  private connect() {
    if (this.closed) return;
    const socket = net.createConnection(this.socketPath);
    this.socket = socket;
    socket.on("connect", () => {
      this.connected = true;
      socket.write(encode(this.hello));
      for (const line of this.queue.splice(0)) socket.write(line);
    });
    socket.on("error", () => {}); // "close" follows and retries
    socket.on("close", () => {
      this.connected = false;
      if (this.socket === socket) this.socket = undefined;
      if (!this.closed) this.retry = setTimeout(() => this.connect(), this.retryMs);
    });
    let pending = "";
    socket.on("data", (chunk) => {
      const { lines, rest } = splitLines(pending, chunk.toString("utf8"));
      pending = rest;
      for (const line of lines) {
        const command = decodeCommand(line);
        if (command) this.onCommand?.(command);
      }
    });
  }
}
