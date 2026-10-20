"use strict";
// Word wrap (⌥Z) and formatting: Format Document (⇧⌥F), Format Selection (⌘K ⌘F), the path bar's two buttons and
// format on save (Settings). Swift formats the text with the project's own tool when it has one (its Prettier, with
// its plugins; ruff, gofmt…); otherwise Prettier formats it here in the page, with the project's options (Prettier's
// script loads the first time it's needed). Either way the result goes in as one undoable edit and nothing is saved.
// Names here start with "fmt": this script shares its global scope with editor.js and the others.

const FMT_PROSE = new Set(["md", "markdown", "mdx", "txt", "text", "rst", "adoc"]);
const fmtWrap = { prose: true, code: false }; // prose files wrap by default, code doesn't; ⌥Z flips the active kind
let fmtPrettier = null; // Prettier's script, loading or loaded
let fmtSaving = false; // a format on save is running: it asks Swift whether it's on, and fails quietly

const fmtExt = (path) => (path || "").split("/").pop().split(".").pop().toLowerCase();
const fmtIsProse = (path) => FMT_PROSE.has(fmtExt(path));
const fmtWrapped = (path = active) => fmtWrap[fmtIsProse(path) ? "prose" : "code"];

function fmtInit() {
  // Monaco's own TypeScript and JSON formatters would win over ours; Prettier, with the project's options, does those.
  const off = { documentFormattingEdits: false, documentRangeFormattingEdits: false, onTypeFormattingEdits: false };
  for (const defaults of [monaco.typescript.typescriptDefaults, monaco.typescript.javascriptDefaults, monaco.json.jsonDefaults]) {
    defaults.setModeConfiguration({ ...defaults.modeConfiguration, ...off });
  }
  monaco.languages.registerDocumentFormattingEditProvider("*", {
    displayName: "Glance",
    provideDocumentFormattingEdits: (model) => fmtEdits(model, null),
  });
  monaco.languages.registerDocumentRangeFormattingEditProvider("*", {
    displayName: "Glance",
    provideDocumentRangeFormattingEdits: (model, range) => fmtEdits(model, range),
  });
  editor.addAction({ id: "glance.toggleWrap", label: "Toggle Word Wrap", keybindings: [monaco.KeyMod.Alt | monaco.KeyCode.KeyZ], run: fmtToggleWrap });
  // Right-click → Ask Claude: what to do with the selection (a ticket, a to-do, a note). Glance opens its panel.
  editor.addAction({
    id: "glance.askClaude", label: "Ask Glance…", precondition: "editorHasSelection",
    contextMenuGroupId: "9_cutcopypaste", contextMenuOrder: 0,
    run: (ed) => {
      const selection = ed.getSelection();
      const text = selection && ed.getModel() ? ed.getModel().getValueInRange(selection) : "";
      if (text.trim()) post({ type: "askClaude", text, path: active });
    },
  });
}

// ── Word wrap ──────────────────────────────────────────────────────────
function fmtToggleWrap() {
  if (!active) return;
  const kind = fmtIsProse(active) ? "prose" : "code";
  fmtWrap[kind] = !fmtWrap[kind];
  fmtShow();
  publish();
}

function fmtRestore(saved) {
  if (!saved || typeof saved !== "object") return;
  for (const kind of ["prose", "code"]) if (typeof saved[kind] === "boolean") fmtWrap[kind] = saved[kind];
  if (active) fmtShow();
}

/** Called by pvShow: the active file's wrap, and the path bar's buttons (only while its code is showing). */
function fmtShow() {
  const file = active && files.get(active);
  const code = !!file && !$("editor").hidden;
  $("wrap-toggle").hidden = !code;
  $("format-doc").hidden = !code || !file.formatter;
  if (!file) return;
  const on = fmtWrapped();
  editor.updateOptions({ wordWrap: on ? "on" : "off" });
  $("wrap-toggle").classList.toggle("on", on);
  $("wrap-toggle").title = `${on ? "Stop wrapping" : "Wrap"} long lines in ${fmtIsProse(active) ? "text files" : "code"} (⌥Z)`;
}

$("wrap-toggle").addEventListener("click", () => { fmtToggleWrap(); editor.focus(); });
$("format-doc").addEventListener("click", () => {
  editor.focus();
  editor.getAction("editor.action.formatDocument").run();
});

// ── Formatting ─────────────────────────────────────────────────────────
function fmtLoadPrettier() {
  if (window.glancePrettier) return Promise.resolve(window.glancePrettier);
  fmtPrettier = fmtPrettier || new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "vendor/prettier.js";
    script.onload = () => resolve(window.glancePrettier);
    script.onerror = () => { fmtPrettier = null; reject(new Error("Couldn't load Prettier.")); };
    document.head.append(script);
  });
  return fmtPrettier;
}

/** The file's text formatted (only `range` of it, when given), or null when there's nothing to do. Throws with a
 *  message to show. */
async function fmtFormat(file, range, onSave) {
  if (!file.formatter) throw new Error(`No formatter for .${fmtExt(file.path)} files.`);
  if (range && file.formatter === "command") {
    throw new Error("Only Prettier's languages can format a selection. Format Document (⇧⌥F) formats the whole file.");
  }
  const model = file.model;
  const text = model.getValue();
  const span = range && { rangeStart: model.getOffsetAt(range.getStartPosition()), rangeEnd: model.getOffsetAt(range.getEndPosition()) };
  const how = await request("format", { path: file.path, text, onSave, ...span });
  if (how.skip) return null;
  if (typeof how.text === "string") return how.text;
  const { prettier, plugins } = await fmtLoadPrettier();
  const options = { parser: how.prettier.parser, ...how.prettier.options, plugins, filepath: file.path, ...span };
  return prettier.format(text, options);
}

/** Monaco's formatting providers: the formatted text as one edit, which Monaco narrows down to what changed. */
async function fmtEdits(model, range) {
  const file = [...files.values()].find((f) => f.model === model);
  if (!file) return [];
  try {
    const text = await fmtFormat(file, range, fmtSaving);
    if (text == null || text === model.getValue()) return [];
    return [{ range: model.getFullModelRange(), text }];
  } catch (e) {
    fmtFailed(e);
    return [];
  }
}

function fmtFailed(e) {
  // Prettier's syntax errors carry a code frame after the first line.
  const message = String((e && e.message) || e).split("\n")[0];
  if (fmtSaving) { post({ type: "log", message: `format on save: ${message}` }); return; }
  showBanner(message, [{ label: "OK", run: refreshBanner }]);
}

/** Before a save: formats the file when format on save is turned on. A failure doesn't stop the save. */
async function fmtBeforeSave(file) {
  if (!file.formatter) return;
  fmtSaving = true;
  try {
    if (file.path === active) {
      await editor.getAction("editor.action.formatDocument").run();
      return;
    }
    const version = file.model.getAlternativeVersionId();
    const text = await fmtFormat(file, null, true);
    if (text == null || version !== file.model.getAlternativeVersionId()) return;
    const edit = fmtEdit(file.model, text);
    if (edit) file.model.pushEditOperations([], [edit], () => null);
  } catch (e) {
    fmtFailed(e);
  } finally {
    fmtSaving = false;
  }
}

/** An edit that turns the model's text into `text`, covering only what lies between their common start and end. */
function fmtEdit(model, text) {
  const old = model.getValue();
  if (old === text) return null;
  let start = 0;
  while (start < old.length && start < text.length && old[start] === text[start]) start++;
  let end = 0;
  while (end < old.length - start && end < text.length - start && old[old.length - 1 - end] === text[text.length - 1 - end]) end++;
  return {
    range: monaco.Range.fromPositions(model.getPositionAt(start), model.getPositionAt(old.length - end)),
    text: text.slice(start, text.length - end),
  };
}
