// Follows Claude Code sessions by watching their transcripts (~/.claude/projects/<project>/<session>.jsonl): a new
// prompt means Claude is thinking, an assistant entry that ends the turn means the reply is ready. No hooks needed.
import * as fs from "node:fs";
import * as path from "node:path";
import { TurnEvent, turnEvent } from "./core/transcript";

export interface SessionEvent { kind: TurnEvent["kind"]; file: string; cwd?: string }

export class TranscriptWatcher {
  private watcher?: fs.FSWatcher;
  private offsets = new Map<string, number>();
  private partial = new Map<string, string>();
  private cwds = new Map<string, string>();
  private doneTimers = new Map<string, NodeJS.Timeout>();

  constructor(
    private readonly root: string,
    private readonly accepts: (cwd: string | undefined) => boolean,
    private readonly onEvent: (event: SessionEvent) => void,
  ) {}

  start() {
    fs.mkdirSync(this.root, { recursive: true });
    // Existing transcripts are history: only what's appended from now on counts.
    for (const project of safeList(this.root)) {
      const dir = path.join(this.root, project);
      for (const file of safeList(dir)) {
        if (file.endsWith(".jsonl")) this.offsets.set(path.join(dir, file), safeSize(path.join(dir, file)));
      }
    }
    this.watcher = fs.watch(this.root, { recursive: true }, (_event, name) => {
      if (name && name.toString().endsWith(".jsonl")) this.read(path.join(this.root, name.toString()));
    });
  }

  dispose() {
    this.watcher?.close();
    for (const timer of this.doneTimers.values()) clearTimeout(timer);
  }

  private read(file: string) {
    const size = safeSize(file);
    const from = this.offsets.get(file) ?? 0;
    if (size < from) this.offsets.set(file, 0); // rewritten
    if (size <= from) return;
    let chunk = "";
    try {
      const fd = fs.openSync(file, "r");
      const buffer = Buffer.alloc(size - from);
      fs.readSync(fd, buffer, 0, buffer.length, from);
      fs.closeSync(fd);
      chunk = buffer.toString("utf8");
    } catch {
      return;
    }
    this.offsets.set(file, size);
    const lines = ((this.partial.get(file) ?? "") + chunk).split("\n");
    this.partial.set(file, lines.pop() ?? "");
    for (const line of lines) {
      const event = turnEvent(line);
      if (!event) continue;
      if (event.cwd) this.cwds.set(file, event.cwd);
      const cwd = event.cwd ?? this.cwds.get(file);
      if (!this.accepts(cwd)) continue;
      if (event.kind === "prompt") {
        clearTimeout(this.doneTimers.get(file));
        this.onEvent({ kind: "prompt", file, cwd });
      } else {
        // A finished turn writes several entries (thinking, text, summaries): wait for the burst to end.
        clearTimeout(this.doneTimers.get(file));
        this.doneTimers.set(file, setTimeout(() => this.onEvent({ kind: "done", file, cwd }), 450));
      }
    }
  }
}

/** The last 4 MB of a transcript: long sessions grow large, and the last turn sits at the end. */
export function readTail(file: string): string {
  const size = safeSize(file);
  const window = 4 << 20;
  const start = Math.max(0, size - window);
  const fd = fs.openSync(file, "r");
  try {
    const buffer = Buffer.alloc(size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    let text = buffer.toString("utf8");
    if (start > 0) text = text.slice(text.indexOf("\n") + 1);
    return text;
  } finally {
    fs.closeSync(fd);
  }
}

function safeList(dir: string): string[] {
  try { return fs.readdirSync(dir); } catch { return []; }
}

function safeSize(file: string): number {
  try { return fs.statSync(file).size; } catch { return 0; }
}
