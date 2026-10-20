"use strict";
// Inline Ask (⌘I, or the orb in the gutter next to a selection): ask Claude Code about the selected lines, or have it
// rewrite them. Swift runs Claude (InlineAskSessions, one process per box) and streams its answer back through
// editorHost.askEvent. A rewrite shows in the file as a diff, the old lines in red above the new ones in green, until
// Accept (⌘↩) or Reject (Esc). Several boxes can be open at once, each following its own lines as the file changes.
// Names here start with "ask": this script shares its global scope with editor.js, search.js and changes.js.

const askMd = window.markdownit({
  html: false,
  linkify: true,
  highlight(code, lang) {
    try {
      const out = lang && hljs.getLanguage(lang)
        ? hljs.highlight(code, { language: lang, ignoreIllegals: true })
        : hljs.highlightAuto(code);
      return `<pre><code class="hljs">${out.value}</code></pre>`;
    } catch {
      return "";
    }
  },
});

const ASK_STALE = "The code changed while Claude was working; edit not applied.";
// id -> { id, path, model, mark, text, before, after, turns, running, restart, pending, zoneId, zone, node, ... }
// `mark` is a decoration on the selected lines (Monaco moves it as the file changes); `pending` holds the diff's two.
const askBoxes = new Map();
let askLast = null; // the box used last, for ⌘↩ and Esc typed in the editor
let askSeq = 0;
let askOrb = null; // decorations collection: the orb on the selection's first line
let askOrbLine = 0;
let askOpenKey = null;
let askPendingKey = null;
// The "Ask Claude ⌘I" pill that floats above a selection once the mouse lets go of it.
let askHint = null;
let askHintAt = null;
let askHintTimer = 0;
let askMouseHeld = false;

/** Called by createEditor once Monaco is up. */
function askInit() {
  askOrb = editor.createDecorationsCollection();
  askOpenKey = editor.createContextKey("askBoxOpen", false);
  askPendingKey = editor.createContextKey("askPending", false);
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyI, askOpen);
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, () => { const b = askTarget(true); if (b) askAccept(b); }, "askPending");
  editor.addCommand(monaco.KeyCode.Escape, () => { const b = askTarget(false); if (b) askEscape(b); },
    "askBoxOpen && !suggestWidgetVisible && !findWidgetVisible && !inSnippetMode");
  editor.onDidChangeCursorSelection(askUpdateOrb);
  askBuildHint();
  editor.onMouseUp(() => { askMouseHeld = false; askUpdateOrb(); });
  editor.onDidBlurEditorWidget(() => askShowHint(false));
  editor.onMouseDown((e) => {
    askMouseHeld = e.event.leftButton;
    if (e.target.type === monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN && askOrbLine
        && e.target.position && e.target.position.lineNumber === askOrbLine) {
      e.event.preventDefault();
      askOpen();
    }
  });
  editor.onDidChangeModel(askReattach);
  editor.onDidLayoutChange(() => askShown().forEach(askPlace));
}

/** The open boxes of the file the editor shows. */
function askShown() {
  const model = editor.getModel();
  return [...askBoxes.values()].filter((b) => b.model === model);
}

/** The box ⌘↩ or Esc in the editor means: the one around the cursor, else the last one used. */
function askTarget(needsPending) {
  const shown = askShown().filter((b) => !needsPending || b.pending);
  const line = editor.getPosition() ? editor.getPosition().lineNumber : 0;
  return shown.find((b) => { const r = askRegion(b); return r && line >= r.start && line <= r.end; })
    || (shown.includes(askLast) ? askLast : shown[shown.length - 1]);
}

/** The lines a box covers now: its selection, and its diff's new lines when there is one. */
function askRegion(box) {
  const sel = box.model.getDecorationRange(box.mark);
  if (!sel) return null;
  const added = box.pending && box.model.getDecorationRange(box.pending.ids[1]);
  return { start: sel.startLineNumber, end: added ? added.endLineNumber : sel.endLineNumber };
}

function askUpdateKeys() {
  const shown = askShown();
  askOpenKey.set(shown.length > 0);
  askPendingKey.set(shown.some((b) => b.pending));
}

// ── The orb ────────────────────────────────────────────────────────────
/** The selected whole lines: a selection ending at the start of a line doesn't take that line. */
function askSelectedLines() {
  const sel = editor.getSelection();
  if (!sel) return null;
  const end = sel.endColumn === 1 && sel.endLineNumber > sel.startLineNumber ? sel.endLineNumber - 1 : sel.endLineNumber;
  return { start: sel.startLineNumber, end, empty: sel.isEmpty() };
}

function askUpdateOrb() {
  const lines = askSelectedLines();
  const show = editor.getModel() && lines && !lines.empty;
  askOrbLine = show ? lines.start : 0;
  askOrb.set(show ? [{
    range: new monaco.Range(lines.start, 1, lines.start, 1),
    options: { glyphMarginClassName: "ask-orb", glyphMarginHoverMessage: { value: "Ask Claude (⌘I)" } },
  }] : []);
  // The pill waits until the selection settles (not while the mouse is still dragging it out).
  clearTimeout(askHintTimer);
  if (!show) { askShowHint(false); return; }
  if (askMouseHeld) { askShowHint(false); return; }
  askHintTimer = setTimeout(() => {
    const model = editor.getModel();
    if (!model) return;
    askHintAt = { lineNumber: lines.start, column: Math.max(1, model.getLineFirstNonWhitespaceColumn(lines.start)) };
    askShowHint(true);
  }, 160);
}

function askBuildHint() {
  const node = document.createElement("button");
  node.className = "ask-hint";
  node.title = "Ask Claude about these lines, or have it change them";
  node.innerHTML = '<span class="ask-hint-orb"></span><span>Ask Claude</span><kbd>⌘I</kbd>';
  node.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); }); // keep the selection
  node.addEventListener("click", (e) => { e.preventDefault(); askShowHint(false); askOpen(); });
  askHint = {
    node,
    getId: () => "glance.askHint",
    getDomNode: () => node,
    getPosition: () => (askHintAt ? {
      position: askHintAt,
      preference: [monaco.editor.ContentWidgetPositionPreference.ABOVE, monaco.editor.ContentWidgetPositionPreference.BELOW],
    } : null),
  };
  editor.addContentWidget(askHint);
}

function askShowHint(show) {
  if (!askHint) return;
  if (!show) {
    askHint.node.classList.remove("show");
    return;
  }
  editor.layoutContentWidget(askHint);
  askHint.node.classList.add("show");
}

// ── Opening and closing ────────────────────────────────────────────────
function askOpen() {
  const model = editor.getModel();
  if (!model || !active) return;
  const { start, end } = askSelectedLines();
  const all = model.getLinesContent();
  const box = {
    id: `ask${++askSeq}`, path: active, model,
    mark: model.deltaDecorations([], [{ range: new monaco.Range(start, 1, end, model.getLineMaxColumn(end)),
      options: { stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges } }])[0],
    text: all.slice(start - 1, end).join("\n"),
    before: all.slice(Math.max(0, start - 41), start - 1).join("\n"),
    after: all.slice(end, end + 40).join("\n"),
    turns: [], running: false, restart: false, pending: null, zoneId: null, zone: null, renderQueued: false,
  };
  askBoxes.set(box.id, box);
  askLast = box;
  box.disposeListener = model.onWillDispose(() => askClose(box, { disposing: true }));
  box.changeListener = model.onDidChangeContent((e) => askContentChanged(box, e));
  askBuildNode(box);
  editor.addOverlayWidget(box.widget);
  askMountZone(box);
  askRender(box);
  askUpdateKeys();
  editor.setSelection(new monaco.Range(end, model.getLineMaxColumn(end), end, model.getLineMaxColumn(end)));
  box.node.querySelector(".ask-input").focus();
}

/** Esc: reject a diff waiting for an answer, otherwise close the box. */
function askEscape(box) {
  if (box.pending) askReject(box); else askClose(box);
}

function askClose(box, { disposing = false } = {}) {
  if (!askBoxes.has(box.id)) return;
  // Always: an answered box's Claude process stays alive for follow-ups until it's stopped.
  if (box.turns.length) post({ type: "askStop", id: box.id });
  if (box.pending && !disposing) askReject(box, { keepOpen: false });
  if (box.zoneId && editor.getModel() === box.model) editor.changeViewZones((a) => a.removeZone(box.zoneId));
  editor.removeOverlayWidget(box.widget);
  box.resize.disconnect();
  box.disposeListener.dispose();
  box.changeListener.dispose();
  if (!disposing) box.model.deltaDecorations([box.mark], []);
  askBoxes.delete(box.id);
  if (askLast === box) askLast = null;
  askUpdateKeys();
  if (!disposing && editor.getModel()) editor.focus();
}

// ── The box: a view zone makes room under the lines, an overlay widget draws in it ─
function askBuildNode(box) {
  const node = document.createElement("div");
  node.className = "ask";
  node.hidden = true;
  node.innerHTML = `
    <div class="ask-turns" hidden></div>
    <div class="ask-row">
      <textarea class="ask-input" rows="1" placeholder="Ask about this code, or say what to change…" spellcheck="false"></textarea>
      <span class="ask-actions"></span>
    </div>`;
  const input = node.querySelector(".ask-input");
  input.addEventListener("keydown", (e) => {
    e.stopPropagation(); // the box's keys aren't the editor's
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); if (box.pending) askAccept(box); }
    else if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); askSend(box, input.value); }
    else if (e.key === "Escape") { e.preventDefault(); askEscape(box); }
  });
  input.addEventListener("input", () => { input.style.height = "auto"; input.style.height = `${input.scrollHeight}px`; });
  node.addEventListener("mousedown", (e) => { e.stopPropagation(); askLast = box; });
  node.addEventListener("focusin", () => { askLast = box; });
  box.node = node;
  box.widget = { getId: () => `glance.${box.id}`, getDomNode: () => node, getPosition: () => null };
  box.resize = new ResizeObserver(() => askLayoutZone(box));
  box.resize.observe(node);
}

/** (Re)places the box's zone under its lines, or under its diff's new lines. */
function askMountZone(box) {
  if (editor.getModel() !== box.model) return;
  const region = askRegion(box);
  if (!region) return;
  editor.changeViewZones((a) => {
    if (box.zoneId) a.removeZone(box.zoneId);
    box.zone = {
      afterLineNumber: region.end,
      heightInPx: Math.max(box.node.offsetHeight, 48) + 8,
      domNode: document.createElement("div"),
      onDomNodeTop: (top) => { box.node.style.top = `${top + 4}px`; },
    };
    box.zoneId = a.addZone(box.zone);
  });
  box.node.hidden = false;
  askPlace(box);
}

function askLayoutZone(box) {
  if (!box.zoneId || !box.zone || box.node.hidden) return;
  const height = box.node.offsetHeight + 8;
  if (Math.abs(box.zone.heightInPx - height) < 1) return;
  box.zone.heightInPx = height;
  editor.changeViewZones((a) => a.layoutZone(box.zoneId));
}

function askPlace(box) {
  const info = editor.getLayoutInfo();
  box.node.style.left = `${info.contentLeft + 4}px`;
  box.node.style.width = `${Math.min(760, Math.max(240, info.contentWidth - info.verticalScrollbarWidth - 28))}px`;
}

/** The editor shows another file: each box stays with its own file, hidden until that file is shown again. */
function askReattach() {
  for (const box of askBoxes.values()) {
    box.zoneId = null; // Monaco drops view zones with the model
    if (editor.getModel() === box.model) askMountZone(box); else box.node.hidden = true;
  }
  askUpdateKeys();
  askUpdateOrb();
}

function askRender(box) {
  if (box.renderQueued) return;
  box.renderQueued = true;
  requestAnimationFrame(() => {
    box.renderQueued = false;
    if (!askBoxes.has(box.id)) return;
    const turns = box.node.querySelector(".ask-turns");
    const stick = turns.scrollHeight - turns.scrollTop - turns.clientHeight < 24;
    turns.replaceChildren(...box.turns.map((turn) => {
      const el = document.createElement("div");
      el.className = "ask-turn";
      const q = document.createElement("div");
      q.className = "ask-q";
      q.textContent = turn.question;
      const a = document.createElement("div");
      a.className = "ask-a";
      a.innerHTML = askMd.render(turn.answer);
      el.append(q, a);
      for (const [cls, text] of [["ask-tool", turn.tool], ["ask-note", turn.note], ["ask-error", turn.error]]) {
        if (!text) continue;
        const line = document.createElement("div");
        line.className = cls;
        line.textContent = text;
        el.append(line);
      }
      return el;
    }));
    turns.hidden = !box.turns.length;
    if (stick) turns.scrollTop = turns.scrollHeight;
    const button = (label, title, run, cls = "") => {
      const b = document.createElement("button");
      b.textContent = label;
      b.title = title;
      b.className = cls;
      b.addEventListener("click", run);
      return b;
    };
    box.node.querySelector(".ask-actions").replaceChildren(...[
      box.running && button("Stop", "Stop Claude", () => askStop(box)),
      box.pending && button("Accept", "Keep the new lines (⌘↩)", () => askAccept(box), "ask-accept"),
      box.pending && button("Reject", "Keep the old lines (Esc)", () => askReject(box)),
      button("×", "Close (Esc)", () => askClose(box), "ask-close"),
    ].filter(Boolean));
    box.node.querySelector(".ask-input").disabled = box.running;
  });
}

// ── Asking ─────────────────────────────────────────────────────────────
function askSend(box, text) {
  const question = text.trim();
  if (box.running || !question) return;
  if (box.pending) askReject(box, { keepOpen: false }); // a follow-up's answer replaces the original lines again
  const first = !box.turns.length || box.restart;
  box.restart = false;
  box.turns.push({ question, answer: "", tool: "Thinking…" });
  box.running = true;
  if (first) {
    // Claude gets the lines as they are now (the box may have moved since it opened).
    const sel = box.model.getDecorationRange(box.mark);
    const all = box.model.getLinesContent();
    if (sel) {
      box.text = all.slice(sel.startLineNumber - 1, sel.endLineNumber).join("\n");
      box.before = all.slice(Math.max(0, sel.startLineNumber - 41), sel.startLineNumber - 1).join("\n");
      box.after = all.slice(sel.endLineNumber, sel.endLineNumber + 40).join("\n");
    }
    post({ type: "askStart", id: box.id, path: box.path, start: sel ? sel.startLineNumber : 1,
           end: sel ? sel.endLineNumber : 1, text: box.text, before: box.before, after: box.after, question });
  } else {
    post({ type: "askFollowUp", id: box.id, question });
  }
  const input = box.node.querySelector(".ask-input");
  input.value = "";
  input.style.height = "auto";
  askRender(box);
}

function askStop(box) {
  if (!box.running) return;
  post({ type: "askStop", id: box.id });
  box.running = false;
  box.restart = true; // the process is gone: the next question starts over
  const turn = box.turns[box.turns.length - 1];
  turn.tool = null;
  turn.note = "Stopped.";
  askRender(box);
  box.node.querySelector(".ask-input").focus();
}

/** Swift's events for a box: text, tool, done, failed. */
function askEvent(e) {
  const box = askBoxes.get(e.id);
  if (!box || !box.running) return;
  const turn = box.turns[box.turns.length - 1];
  if (e.kind === "text") {
    turn.answer += e.text;
    if (turn.tool === "Thinking…") turn.tool = null;
  } else if (e.kind === "tool") {
    turn.tool = e.label;
  } else if (e.kind === "done") {
    box.running = false;
    turn.tool = null;
    if (typeof e.replacement === "string") askShowDiff(box, turn, e);
    if (!turn.answer.trim() && !turn.note) turn.answer = typeof e.replacement === "string" ? "Here's the change." : "(No answer.)";
  } else if (e.kind === "failed") {
    box.running = false;
    box.restart = true;
    turn.tool = null;
    turn.error = e.message;
  }
  askRender(box);
  // Focus follows the answer only when the user isn't busy in another box.
  if (!box.running && editor.getModel() === box.model && askLast === box) box.node.querySelector(".ask-input").focus();
}

// ── The diff ───────────────────────────────────────────────────────────
/** Puts Claude's lines below the box's lines, which may have moved since the question (other boxes' edits, typing
 *  above); the edit is dropped when their text changed. */
function askShowDiff(box, turn, e) {
  const model = box.model;
  const sel = model.getDecorationRange(box.mark);
  const now = sel ? model.getLinesContent().slice(sel.startLineNumber - 1, sel.endLineNumber).join("\n") : null;
  if (now !== e.originalText) { turn.note = ASK_STALE; return; }
  const start = sel.startLineNumber, end = sel.endLineNumber;
  const added = e.replacement.split("\n").length;
  const column = model.getLineMaxColumn(end);
  askEdit(box, [{ range: new monaco.Range(end, column, end, column), text: "\n" + e.replacement }]);
  box.pending = {
    ids: model.deltaDecorations([], [
      { range: new monaco.Range(start, 1, end, 1),
        options: { isWholeLine: true, className: "ask-old", glyphMarginClassName: "ask-minus" } },
      { range: new monaco.Range(end + 1, 1, end + added, 1),
        options: { isWholeLine: true, className: "ask-new", glyphMarginClassName: "ask-plus" } },
    ]),
  };
  askMountZone(box);
  askUpdateKeys();
}

/** Edits the box's file as one undo step, without counting them as the user's typing in that box. */
function askEdit(box, edits) {
  box.editing = true;
  try {
    box.model.pushStackElement();
    box.model.pushEditOperations([], edits, () => null);
    box.model.pushStackElement();
  } finally {
    box.editing = false;
  }
}

/** Deleting whole lines a..b, with the line break that goes with them. */
function askDeleteLines(model, a, b) {
  const count = model.getLineCount();
  if (b < count) return new monaco.Range(a, 1, b + 1, 1);
  if (a > 1) return new monaco.Range(a - 1, model.getLineMaxColumn(a - 1), b, model.getLineMaxColumn(b));
  return new monaco.Range(1, 1, b, model.getLineMaxColumn(b));
}

/** Removes the old lines (`which` 0) or the new ones (1) and the diff's colours. Returns both ranges as they were. */
function askSettle(box, which) {
  const gone = box.model.getDecorationRange(box.pending.ids[which]);
  const kept = box.model.getDecorationRange(box.pending.ids[1 - which]);
  box.model.deltaDecorations(box.pending.ids, []);
  box.pending = null;
  askUpdateKeys();
  if (gone) askEdit(box, [{ range: askDeleteLines(box.model, gone.startLineNumber, gone.endLineNumber), text: null }]);
  return { gone, kept };
}

function askAccept(box) {
  if (!box.pending) return;
  const { gone, kept } = askSettle(box, 0);
  askClose(box);
  if (!gone || !kept || editor.getModel() !== box.model) return;
  const removed = gone.endLineNumber - gone.startLineNumber + 1; // the old lines sat above the new ones
  const last = kept.endLineNumber - removed;
  editor.setSelection(new monaco.Range(kept.startLineNumber - removed, 1, last, box.model.getLineMaxColumn(last)));
}

function askReject(box, { keepOpen = true } = {}) {
  if (!box.pending) return;
  askSettle(box, 1);
  if (!keepOpen) return;
  const turn = box.turns[box.turns.length - 1];
  if (turn) turn.note = "Rejected: the old lines stay. Ask again, or Esc to close.";
  askMountZone(box);
  askRender(box);
  box.node.querySelector(".ask-input").focus();
}

/** Typing into a box's diff decides it: in the new lines it accepts them, in the old lines it keeps those. An undo
 *  that reaches the diff ends it. Edits elsewhere (another box's, or above) just move it: its decorations follow. */
function askContentChanged(box, e) {
  if (box.editing || !box.pending || !askBoxes.has(box.id)) return;
  const oldRange = box.model.getDecorationRange(box.pending.ids[0]);
  const newRange = box.model.getDecorationRange(box.pending.ids[1]);
  const touches = (r) => r && e.changes.some((c) => c.range.startLineNumber <= r.endLineNumber && c.range.endLineNumber >= r.startLineNumber);
  if (e.isUndoing || e.isRedoing) {
    if (!touches(oldRange) && !touches(newRange)) return;
    box.model.deltaDecorations(box.pending.ids, []);
    box.pending = null;
    askUpdateKeys();
    askMountZone(box);
    askRender(box);
    return;
  }
  if (touches(newRange)) setTimeout(() => { if (box.pending) askAccept(box); });
  else if (touches(oldRange)) setTimeout(() => { if (box.pending) askReject(box); });
}
