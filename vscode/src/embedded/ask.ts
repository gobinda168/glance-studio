// Inline Ask in GS Code: ⌘I, Ask Glance… or the gutter's "+" opens a comment thread on the selected lines (VS
// Code's only built-in input inside the editor). Glance Studio runs Claude Code headless, one process per thread,
// and streams its answer back over the bridge; a change Claude makes shows as a diff in the file (old lines red, new
// lines green) until Accept or Reject. Several threads can be open at once, each following its own lines as the file
// changes. Razor Code's Web/editor/ask.js does the same in Monaco.
import * as vscode from "vscode";
import type { AskEvent, BridgeMessage } from "./bridge";
import { Pending, afterChange, isStale, lineDeletion, pendingFor, shiftLines } from "./askDiff";

const STALE = "The code changed while Claude was working; edit not applied.";

const icon = (sign: string, color: string) => vscode.Uri.parse("data:image/svg+xml;utf8," + encodeURIComponent(
  `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><text x="8" y="12.5" font-size="13" font-family="Menlo,monospace" font-weight="600" text-anchor="middle" fill="${color}">${sign}</text></svg>`));

class AskComment implements vscode.Comment {
  mode = vscode.CommentMode.Preview;
  constructor(public body: vscode.MarkdownString | string, public author: vscode.CommentAuthorInformation) {}
}

interface Turn {
  question: string;
  answer: string;
  tool?: string;
  note?: string;
  error?: string;
}

interface Box {
  id: string;
  thread: vscode.CommentThread;
  uri: vscode.Uri;
  /** The selected lines now (1-based, inclusive): they follow edits above and inside them. */
  start: number;
  end: number;
  turns: Turn[];
  running: boolean;
  restart: boolean;
  pending?: Pending;
  renderTimer?: NodeJS.Timeout;
}

export class InlineAsk implements vscode.Disposable {
  private readonly controller = vscode.comments.createCommentController("glance.ask", "Claude");
  private readonly oldLines = vscode.window.createTextEditorDecorationType({
    isWholeLine: true, backgroundColor: "rgba(248, 81, 73, 0.16)", gutterIconPath: icon("−", "#f85149"), gutterIconSize: "contain",
  });
  private readonly newLines = vscode.window.createTextEditorDecorationType({
    isWholeLine: true, backgroundColor: "rgba(46, 160, 67, 0.16)", gutterIconPath: icon("+", "#2ea043"), gutterIconSize: "contain",
  });
  /** "✦ Ask Claude ⌘I" after a selection's first line (extensions can't put a button inside the text). */
  private readonly hint = vscode.window.createTextEditorDecorationType({
    after: {
      contentText: "✦ Ask Claude  ⌘I", color: "#e8643c", backgroundColor: "rgba(232, 100, 60, 0.13)", fontWeight: "600",
      margin: "0 0 0 2em", border: "1px solid rgba(232, 100, 60, 0.45)",
      textDecoration: "none; border-radius: 10px; padding: 0 8px; font-size: 0.88em; box-shadow: 0 2px 10px rgba(232, 100, 60, 0.28)",
    },
  });
  private hintTimer?: NodeJS.Timeout;
  private readonly disposables: vscode.Disposable[] = [];
  private readonly boxes = new Map<string, Box>();
  private last?: Box;
  /** The box whose own edit is going into the document now (its changes don't move or decide it). */
  private applying?: Box;
  private seq = 0;

  constructor(private readonly send: (message: BridgeMessage) => void, private readonly root: () => string) {
    this.controller.commentingRangeProvider = {
      provideCommentingRanges: (document) => (this.relative(document.uri) === undefined || document.lineCount === 0
        ? [] : [new vscode.Range(0, 0, document.lineCount - 1, 0)]),
    };
    this.controller.options = { prompt: "Ask Glance…", placeHolder: "Ask about this code, or say what to change…" };
    this.disposables.push(
      this.controller, this.oldLines, this.newLines, this.hint,
      vscode.window.onDidChangeTextEditorSelection((e) => this.selectionChanged(e.textEditor)),
      vscode.commands.registerCommand("glance.ask", () => this.open()),
      vscode.commands.registerCommand("glance.askSubmit", (reply: vscode.CommentReply) => this.submit(reply)),
      vscode.commands.registerCommand("glance.askStop", (thread?: vscode.CommentThread) => this.withBox(thread, false, (b) => this.stop(b))),
      vscode.commands.registerCommand("glance.askAccept", (thread?: vscode.CommentThread) => this.withBox(thread, true, (b) => this.accept(b))),
      vscode.commands.registerCommand("glance.askReject", (thread?: vscode.CommentThread) => this.withBox(thread, true, (b) => this.reject(b))),
      vscode.commands.registerCommand("glance.askClose", (thread?: vscode.CommentThread) => {
        const box = thread && this.boxOf(thread);
        if (box) void this.close(box);
        else thread?.dispose(); // a thread nobody asked anything in yet
      }),
      vscode.workspace.onDidChangeTextDocument((e) => this.documentChanged(e)),
      vscode.window.onDidChangeVisibleTextEditors(() => this.paint()),
      vscode.workspace.onDidCloseTextDocument((d) => {
        for (const box of [...this.boxes.values()]) if (box.uri.toString() === d.uri.toString()) void this.close(box, { closed: true });
      }),
    );
  }

  /** ⌘I or Ask Glance…: VS Code's own command opens a thread on the selection, through this controller, with the
   *  input focused. */
  private async open() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || this.relative(editor.document.uri) === undefined) return;
    await vscode.commands.executeCommand("workbench.action.addComment");
  }

  /** The hint shows once a selection has settled for a moment, and goes as soon as it's empty. */
  private selectionChanged(editor: vscode.TextEditor) {
    clearTimeout(this.hintTimer);
    editor.setDecorations(this.hint, []);
    const selection = editor.selection;
    if (selection.isEmpty || this.relative(editor.document.uri) === undefined) return;
    this.hintTimer = setTimeout(() => {
      if (!editor.selection.isEqual(selection)) return;
      const line = editor.document.lineAt(selection.start.line);
      editor.setDecorations(this.hint, [new vscode.Range(line.range.end, line.range.end)]);
    }, 200);
  }

  private boxOf(thread: vscode.CommentThread): Box | undefined {
    for (const box of this.boxes.values()) if (box.thread === thread) return box;
    return undefined;
  }

  /** A title button passes its thread; a key means the box around the cursor, else the one used last. */
  private withBox(thread: vscode.CommentThread | undefined, needsPending: boolean, run: (box: Box) => unknown) {
    let box = thread ? this.boxOf(thread) : undefined;
    if (!thread) {
      const editor = vscode.window.activeTextEditor;
      const line = editor ? editor.selection.active.line + 1 : 0;
      const candidates = [...this.boxes.values()].filter((b) => (!needsPending || b.pending)
        && editor && b.uri.toString() === editor.document.uri.toString());
      box = candidates.find((b) => line >= b.start && line <= (b.pending?.newEnd ?? b.end))
        ?? (this.last && candidates.includes(this.last) ? this.last : candidates[candidates.length - 1]);
    }
    if (box) void run(box);
  }

  private async submit(reply: vscode.CommentReply) {
    const question = reply.text.trim();
    if (!question) return;
    const box = this.boxOf(reply.thread) ?? this.newBox(reply.thread);
    if (!box) { reply.thread.dispose(); return; }
    this.last = box;
    if (box.running) return;
    if (box.pending) await this.reject(box, { quiet: true });
    const first = !box.turns.length || box.restart;
    box.restart = false;
    box.turns.push({ question, answer: "", tool: "Thinking…" });
    box.running = true;
    if (first) {
      const document = await vscode.workspace.openTextDocument(box.uri);
      const lines = (from: number, to: number) => {
        const out: string[] = [];
        for (let i = Math.max(1, from); i <= Math.min(document.lineCount, to); i++) out.push(document.lineAt(i - 1).text);
        return out.join("\n");
      };
      this.send({ type: "askStart", id: box.id, path: this.relative(box.uri) ?? box.uri.path, start: box.start, end: box.end,
                  text: lines(box.start, box.end), before: lines(box.start - 40, box.start - 1),
                  after: lines(box.end + 1, box.end + 40), question });
    } else {
      this.send({ type: "askFollowUp", id: box.id, question });
    }
    this.render(box, true);
  }

  private newBox(thread: vscode.CommentThread): Box | undefined {
    const range = thread.range;
    if (!range || this.relative(thread.uri) === undefined) return undefined;
    thread.label = "Claude";
    thread.canReply = true;
    thread.collapsibleState = vscode.CommentThreadCollapsibleState.Expanded;
    const start = range.start.line + 1;
    const end = range.end.character === 0 && range.end.line > range.start.line ? range.end.line : range.end.line + 1;
    const box: Box = { id: `ask${Date.now()}-${++this.seq}`, thread, uri: thread.uri, start, end, turns: [], running: false,
                       restart: false };
    this.boxes.set(box.id, box);
    return box;
  }

  /** The app's events for a box. */
  onEvent(e: AskEvent) {
    const box = this.boxes.get(e.id);
    if (!box || !box.running) return;
    const turn = box.turns[box.turns.length - 1];
    switch (e.kind) {
      case "text":
        turn.answer += e.text;
        if (turn.tool === "Thinking…") turn.tool = undefined;
        this.render(box);
        return;
      case "tool":
        turn.tool = e.label;
        this.render(box);
        return;
      case "failed":
        box.running = false;
        box.restart = true;
        turn.tool = undefined;
        turn.error = e.message;
        this.render(box, true);
        return;
      case "done":
        box.running = false;
        turn.tool = undefined;
        if (!turn.answer.trim()) turn.answer = e.replacement !== undefined ? "Here's the change." : "(No answer.)";
        if (e.replacement === undefined) { this.render(box, true); return; }
        void this.showDiff(box, turn, e.originalText, e.replacement).then(() => this.render(box, true));
    }
  }

  /** Claude's lines go below the box's lines where they are now; dropped when their text changed since the question. */
  private async showDiff(box: Box, turn: Turn, original: string, replacement: string) {
    const document = this.document(box);
    const current = document && box.end <= document.lineCount
      ? Array.from({ length: box.end - box.start + 1 }, (_, i) => document.lineAt(box.start - 1 + i).text).join("\n") : undefined;
    if (!document || isStale(current, original)) { turn.note = STALE; return; }
    const eol = document.eol === vscode.EndOfLine.CRLF ? "\r\n" : "\n";
    const edit = new vscode.WorkspaceEdit();
    edit.insert(box.uri, document.lineAt(box.end - 1).range.end, eol + replacement.split("\n").join(eol));
    if (!(await this.apply(box, edit))) { turn.note = "Couldn't put the change in the file."; return; }
    if (!this.boxes.has(box.id)) return;
    box.pending = pendingFor(box.start, box.end, replacement);
    this.settled();
  }

  private document(box: Box): vscode.TextDocument | undefined {
    return vscode.workspace.textDocuments.find((d) => d.uri.toString() === box.uri.toString());
  }

  private async apply(box: Box, edit: vscode.WorkspaceEdit): Promise<boolean> {
    this.applying = box;
    try { return await vscode.workspace.applyEdit(edit); } finally { this.applying = undefined; }
  }

  private async deleteLines(box: Box, a: number, b: number): Promise<boolean> {
    const document = this.document(box);
    if (!document) return false;
    const r = lineDeletion(a, b, document.lineCount, (line) => document.lineAt(line).text.length);
    const edit = new vscode.WorkspaceEdit();
    edit.delete(box.uri, new vscode.Range(r.startLine, r.startCharacter, r.endLine, r.endCharacter));
    return this.apply(box, edit);
  }

  private async accept(box: Box) {
    const pending = box.pending;
    if (!pending) return;
    box.pending = undefined;
    this.settled();
    await this.deleteLines(box, pending.oldStart, pending.oldEnd);
    await this.close(box);
  }

  private async reject(box: Box, { quiet = false } = {}) {
    const pending = box.pending;
    if (!pending) return;
    box.pending = undefined;
    this.settled();
    await this.deleteLines(box, pending.newStart, pending.newEnd);
    if (quiet) return;
    const turn = box.turns[box.turns.length - 1];
    if (turn) turn.note = "Rejected: the old lines stay. Ask again, or close.";
    this.render(box, true);
  }

  private stop(box: Box) {
    if (!box.running) return;
    this.send({ type: "askStop", id: box.id });
    box.running = false;
    box.restart = true;
    const turn = box.turns[box.turns.length - 1];
    turn.tool = undefined;
    turn.note = "Stopped.";
    this.render(box, true);
  }

  /** Ends a box: its Claude process (alive for follow-ups even when idle), its diff, its timer and its thread. */
  private async close(box: Box, { closed = false } = {}) {
    if (!this.boxes.has(box.id)) return;
    this.boxes.delete(box.id);
    if (this.last === box) this.last = undefined;
    if (box.turns.length) this.send({ type: "askStop", id: box.id });
    clearTimeout(box.renderTimer);
    const pending = box.pending;
    box.pending = undefined;
    if (pending && !closed) await this.deleteLines(box, pending.newStart, pending.newEnd);
    this.settled();
    box.thread.dispose();
  }

  /** The user's own edits, and other boxes' edits: they move each box's lines and diff. The user's typing inside a
   *  diff decides it; an undo that reaches a diff ends it. */
  private documentChanged(e: vscode.TextDocumentChangeEvent) {
    if (!e.contentChanges.length) return;
    const undo = e.reason === vscode.TextDocumentChangeReason.Undo || e.reason === vscode.TextDocumentChangeReason.Redo;
    let changed = false;
    for (const box of this.boxes.values()) {
      if (box === this.applying || box.uri.toString() !== e.document.uri.toString()) continue;
      for (const change of e.contentChanges) {
        const startLine = change.range.start.line + 1, endLine = change.range.end.line + 1;
        const lineDelta = change.text.split(/\r\n|\n/).length - 1 - (endLine - startLine);
        const line = { startLine, endLine, lineDelta };
        if (box.pending) {
          const next = afterChange(box.pending, line);
          if (next === "accept" || next === "reject") {
            if (undo) box.pending = undefined; // the undo took Claude's lines (or the old ones) back: nothing to decide
            else if (!this.applying) { setTimeout(() => void (next === "accept" ? this.accept(box) : this.reject(box))); break; }
          } else {
            box.pending = next;
            box.start = next.oldStart;
            box.end = next.oldEnd;
          }
        } else {
          ({ start: box.start, end: box.end } = shiftLines(box.start, box.end, line));
        }
        changed = true;
      }
    }
    if (changed) this.settled();
  }

  /** Every box's diff colours, thread place and buttons, and the context key for ⌘↩/Esc. */
  private settled() {
    let anyPending = false;
    for (const box of this.boxes.values()) {
      const last = box.pending ? box.pending.newEnd : box.end;
      box.thread.range = new vscode.Range(box.start - 1, 0, Math.max(box.start, last) - 1, 0);
      box.thread.contextValue = box.running ? "glance-ask-running" : box.pending ? "glance-ask-pending" : "glance-ask-idle";
      anyPending ||= !!box.pending;
    }
    void vscode.commands.executeCommand("setContext", "glance.askPending", anyPending);
    this.paint();
  }

  private paint() {
    for (const editor of vscode.window.visibleTextEditors) {
      const uri = editor.document.uri.toString();
      const diffs = [...this.boxes.values()].filter((b) => b.pending && b.uri.toString() === uri).map((b) => b.pending!);
      editor.setDecorations(this.oldLines, diffs.map((p) => new vscode.Range(p.oldStart - 1, 0, p.oldEnd - 1, 0)));
      editor.setDecorations(this.newLines, diffs.map((p) => new vscode.Range(p.newStart - 1, 0, p.newEnd - 1, 0)));
    }
  }

  /** A box's comments from its turns: the questions, and Claude's answers as they stream (redrawn at most every
   *  100 ms, or at once with `now`). */
  private render(box: Box, now = false) {
    if (!now) {
      box.renderTimer ??= setTimeout(() => { box.renderTimer = undefined; this.render(box, true); }, 100);
      return;
    }
    clearTimeout(box.renderTimer);
    box.renderTimer = undefined;
    if (!this.boxes.has(box.id)) return;
    const comments: vscode.Comment[] = [];
    for (const turn of box.turns) {
      comments.push(new AskComment(turn.question, { name: "You" }));
      let body = turn.answer;
      for (const [text, style] of [[turn.tool, "_"], [turn.note, ""], [turn.error, "**"]] as const) {
        if (text) body += `${body ? "\n\n" : ""}${style}${text}${style}`;
      }
      comments.push(new AskComment(new vscode.MarkdownString(body || "_Thinking…_"), { name: "Claude" }));
    }
    box.thread.comments = comments;
    this.settled();
  }

  private relative(uri: vscode.Uri): string | undefined {
    const root = this.root();
    return root && uri.path.startsWith(root + "/") ? uri.path.slice(root.length + 1) : undefined;
  }

  /** The extension host is going away: every box's process is stopped (the app also stops them when this connection
   *  closes), and nothing is left drawn. Claude's pending lines stay in the buffer: the document is going too. */
  dispose() {
    clearTimeout(this.hintTimer);
    for (const box of [...this.boxes.values()]) {
      if (box.turns.length) this.send({ type: "askStop", id: box.id });
      clearTimeout(box.renderTimer);
      box.thread.dispose();
    }
    this.boxes.clear();
    void vscode.commands.executeCommand("setContext", "glance.askPending", false);
    for (const d of this.disposables) d.dispose();
  }
}
