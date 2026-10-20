"use strict";
// The Glance editor page: Monaco with a file tree, tabs, a file palette (⌘P) and a message bridge to Swift, which owns
// every file on disk and the saved session.

const $ = (id) => document.getElementById(id);
const post = (message) => window.webkit.messageHandlers.glanceEditor.postMessage(message);
window.addEventListener("error", (e) => post({ type: "log", message: `${e.message} (${e.filename}:${e.lineno})` }));
window.addEventListener("unhandledrejection", (e) => post({ type: "log", message: `unhandled: ${(e.reason && e.reason.message) || e.reason}` }));

// ── Bridge ─────────────────────────────────────────────────────────────
const pending = new Map();
let nextId = 1;
function request(type, fields) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    post({ type, id, ...fields });
  });
}

window.editorHost = {
  reply({ id, ok, result, error }) {
    const waiting = pending.get(id);
    if (!waiting) return;
    pending.delete(id);
    ok ? waiting.resolve(result) : waiting.reject(Object.assign(new Error(error.message), { code: error.code }));
  },
  save: () => saveFromNative(false),
  saveAll: () => saveFromNative(true),
  quickOpen: () => openPalette(),
  externalChange: (info) => onExternalChange(info),
  open: ({ path, line, column }) => openFile(path, { line, column }),
  restore: (saved) => restoreSession(saved),
  claudeChanges: (map) => setClaudeChanges(map),
  nextChange: () => gotoChange(1),
  prevChange: () => gotoChange(-1),
  clearChanges: () => setClaudeChanges({}),
  claudeFiles: (paths) => setClaudeFiles(paths),
  project: (info) => { pvSetProject(info); $("files-root").textContent = info.name; $("files-root").title = info.root; },
  askEvent: (e) => askEvent(e),
  commitDraft: (e) => commitDraft(e),
};

// ── Monaco ─────────────────────────────────────────────────────────────
self.MonacoEnvironment = {
  getWorker(_, label) {
    const file = label === "typescript" || label === "javascript" ? "ts.worker.js" : label === "json" ? "json.worker.js" : "editor.worker.js";
    return new Worker(`vendor/${file}`);
  },
};

const dark = window.matchMedia("(prefers-color-scheme: dark)");
function defineThemes() {
  monaco.editor.defineTheme("glance-dark", { base: "vs-dark", inherit: true, rules: [], colors: {
    "editor.background": "#12111080", "editorGutter.background": "#00000000", "minimap.background": "#00000000" } });
  monaco.editor.defineTheme("glance-light", { base: "vs", inherit: true, rules: [], colors: {
    "editor.background": "#faf7f094", "editorGutter.background": "#00000000", "minimap.background": "#00000000" } });
}
const themeName = () => (dark.matches ? "glance-dark" : "glance-light");

let editor = null;

function createEditor() {
  defineThemes();
  editor = monaco.editor.create($("editor"), {
    model: null,
    theme: themeName(),
    fontFamily: '"JetBrains Mono", ui-monospace, Menlo, monospace',
    fontSize: 13,
    minimap: { enabled: false },
    automaticLayout: true,
    scrollBeyondLastLine: false,
    renderWhitespace: "selection",
    smoothScrolling: true,
    cursorSmoothCaretAnimation: "on",
    padding: { top: 8 },
    glyphMargin: true, // the Inline Ask orb and its diff's +/−
  });
  dark.addEventListener("change", () => monaco.editor.setTheme(themeName()));
  editor.addCommand(monaco.KeyCode.F7, () => gotoChange(1));
  editor.addCommand(monaco.KeyMod.Shift | monaco.KeyCode.F7, () => gotoChange(-1));
  askInit();
  pvInit();
  fmtInit();
  sbInit();
  // The editor chat's context chip: which lines are selected (none for a bare cursor).
  let selectionTimer = null;
  editor.onDidChangeCursorSelection(() => {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => {
      const s = editor.getSelection();
      if (!s || s.isEmpty()) { post({ type: "selection" }); return; }
      // A selection ending at column 1 of the next line doesn't include that line.
      const end = s.endColumn === 1 && s.endLineNumber > s.startLineNumber ? s.endLineNumber - 1 : s.endLineNumber;
      post({ type: "selection", start: s.startLineNumber, end });
    }, 120);
  });
}

// ── Open files ─────────────────────────────────────────────────────────
// path -> { path, model, modified, bom, savedVersion, dirty, viewState, conflict }   conflict: null | "changed" | "deleted"
const files = new Map();
let order = []; // open paths, in tab order
let active = null; // the active file's path
let restoring = false;
const session = { treeOpen: true, treeWidth: 240 };

let sessionTimer = null;
/** Tells Swift what changed, and (unless a restore is in progress) saves the session a moment later. */
function publish() {
  post({ type: "state", active, dirty: order.filter((p) => files.get(p).dirty), open: order });
  if (restoring) return;
  clearTimeout(sessionTimer);
  sessionTimer = setTimeout(() => {
    post({ type: "session", json: JSON.stringify({ open: order, active, expanded: [...expanded], treeOpen: session.treeOpen, treeWidth: session.treeWidth, previews: pvModes(), wrap: fmtWrap }) });
  }, 300);
}

function labelFor(path) {
  const parts = path.split("/");
  const name = parts[parts.length - 1];
  const clash = order.some((p) => p !== path && p.split("/").pop() === name);
  return clash && parts.length > 1 ? `${parts[parts.length - 2]}/${name}` : name;
}

function renderTabs() {
  $("tabs").replaceChildren(...order.map((path) => {
    const file = files.get(path);
    const tab = document.createElement("div");
    tab.className = "tab" + (path === active ? " active" : "");
    tab.title = path;
    const name = document.createElement("span");
    name.className = "tab-name";
    name.textContent = labelFor(path);
    const mark = document.createElement("span");
    mark.className = "tab-mark";
    mark.textContent = file.conflict ? "⚠" : file.dirty ? "●" : "";
    const close = document.createElement("button");
    close.className = "tab-close";
    close.textContent = "×";
    close.title = "Close";
    close.addEventListener("mousedown", (e) => e.stopPropagation());
    close.addEventListener("click", (e) => { e.stopPropagation(); closeFile(path); });
    tab.addEventListener("mousedown", (e) => { if (e.button === 0) activate(path); });
    tab.addEventListener("auxclick", (e) => { if (e.button === 1) { e.preventDefault(); closeFile(path); } });
    tab.addEventListener("contextmenu", (e) => { e.preventDefault(); openTabMenu(path, e.clientX, e.clientY); });
    tab.append(name, mark, close);
    return tab;
  }));
  const current = $("tabs").querySelector(".active");
  if (current) current.scrollIntoView({ inline: "nearest", block: "nearest" });
}

function showEditor(on) {
  $("empty").hidden = on;
  $("panes").hidden = !on;
  $("pathbar").hidden = !on;
  pvShow(on); // the path bar, and which of the code and its preview are shown
  if (on && editor) editor.layout();
}

function activate(path, { line, column } = {}) {
  const file = files.get(path);
  if (!file) return;
  if (diffState.path && diffState.path !== path) closeDiff(true);
  if (active && files.has(active)) files.get(active).viewState = editor.saveViewState();
  active = path;
  // Going to a line of a file that shows only its preview: show the code beside it.
  if (line && pvMode(path) === "preview") file.preview = "split";
  editor.setModel(file.model);
  if (file.viewState) editor.restoreViewState(file.viewState);
  showEditor(true);
  if (line) {
    editor.revealLineInCenter(line);
    editor.setPosition({ lineNumber: line, column: column || 1 });
  }
  editor.focus();
  renderTabs();
  refreshBanner();
  renderTree();
  revealInTree(path);
  publish();
}

/** Opens a file in a new tab, or activates its tab. `quiet`: no banner when it can't be opened (session restore). */
async function openFile(path, { line, column, quiet = false } = {}) {
  if (files.has(path)) { activate(path, { line, column }); return; }
  let doc;
  try {
    doc = await request("read", { path });
  } catch (e) {
    if (!quiet) showBanner(`Can't open ${path}: ${e.message}`, [{ label: "OK", run: refreshBanner }]);
    return;
  }
  if (files.has(path)) { activate(path, { line, column }); return; } // opened by someone else meanwhile
  const model = monaco.editor.createModel(doc.text, doc.language, monaco.Uri.from({ scheme: "file", path: "/" + doc.path }));
  const file = { path: doc.path, model, modified: doc.modified, bom: doc.bom, formatter: doc.formatter || null, savedVersion: model.getAlternativeVersionId(), dirty: false, viewState: null, conflict: null, claudeIds: [] };
  model.onDidChangeContent(() => {
    const dirty = model.getAlternativeVersionId() !== file.savedVersion;
    if (dirty !== file.dirty) { file.dirty = dirty; renderTabs(); publish(); }
  });
  files.set(doc.path, file);
  order.push(doc.path);
  applyMarks(doc.path);
  activate(doc.path, { line, column });
}

/** Closes a tab, asking first when it has unsaved edits. Resolves false when it stays open (cancelled, or the save failed). */
async function closeFile(path) {
  const file = files.get(path);
  if (!file) return true;
  if (diffState.path === path) closeDiff(false);
  if (file.dirty) {
    activate(path);
    const choice = await confirmUnsaved(`${labelFor(path)} has unsaved changes.`);
    if (choice === "cancel") { refreshBanner(); return false; }
    if (choice === "save" && !(await save(path))) return false;
  }
  const index = order.indexOf(path);
  order.splice(index, 1);
  files.delete(path);
  file.model.dispose();
  if (active === path) {
    active = null;
    const next = order[Math.min(index, order.length - 1)];
    if (next) {
      activate(next);
    } else {
      editor.setModel(null);
      showEditor(false);
      hideBanner();
      renderTabs();
      renderTree();
      publish();
    }
  } else {
    renderTabs();
    publish();
  }
  return true;
}

/** Closes several tabs one by one, keeping `keep` (if any) in front; stops at the first one that stays open. */
async function closeFiles(paths, keep) {
  if (keep && paths.includes(active)) activate(keep);
  for (const path of paths) {
    if (!(await closeFile(path))) return;
  }
  if (keep && files.has(keep) && active !== keep) activate(keep);
}

// ── Tab menu ───────────────────────────────────────────────────────────
function openTabMenu(path, x, y) {
  closeTabMenu();
  const at = order.indexOf(path);
  const left = order.slice(0, at), right = order.slice(at + 1);
  const items = [
    { label: "Close", run: () => closeFile(path) },
    left.length || right.length ? { label: "Close Others", run: () => closeFiles([...left, ...right], path) } : null,
    left.length ? { label: "Close All to the Left", run: () => closeFiles(left, path) } : null,
    right.length ? { label: "Close All to the Right", run: () => closeFiles(right, path) } : null,
    { label: "Close All", run: () => closeFiles([...order]) },
  ].filter(Boolean);
  openMenu(items, x, y);
}

/** A small menu at the pointer (the tab menu's look): `items` are { label, run }. */
function openMenu(items, x, y) {
  closeTabMenu();
  const menu = document.createElement("div");
  menu.id = "tab-menu";
  menu.replaceChildren(...items.map(({ label, run }) => {
    const b = document.createElement("button");
    b.textContent = label;
    b.addEventListener("click", () => { closeTabMenu(); run(); });
    return b;
  }));
  document.body.append(menu);
  const { width, height } = menu.getBoundingClientRect();
  menu.style.left = `${Math.max(4, Math.min(x, innerWidth - width - 4))}px`;
  menu.style.top = `${Math.max(4, Math.min(y, innerHeight - height - 4))}px`;
  setTimeout(() => {
    document.addEventListener("mousedown", onTabMenuOutside, true);
    document.addEventListener("keydown", onTabMenuKey, true);
    window.addEventListener("blur", closeTabMenu);
    window.addEventListener("resize", closeTabMenu);
  });
}
function closeTabMenu() {
  const menu = $("tab-menu");
  if (!menu) return;
  menu.remove();
  document.removeEventListener("mousedown", onTabMenuOutside, true);
  document.removeEventListener("keydown", onTabMenuKey, true);
  window.removeEventListener("blur", closeTabMenu);
  window.removeEventListener("resize", closeTabMenu);
}
function onTabMenuOutside(e) { if (!$("tab-menu").contains(e.target)) closeTabMenu(); }
function onTabMenuKey(e) { if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); closeTabMenu(); } }

// ── Banner and confirmation ────────────────────────────────────────────
function showBanner(text, actions) {
  $("banner-text").textContent = text;
  $("banner-actions").replaceChildren(...actions.map(({ label, run }) => {
    const b = document.createElement("button");
    b.textContent = label;
    b.addEventListener("click", () => { hideBanner(); if (run) run(); });
    return b;
  }));
  $("banner").hidden = false;
}
function hideBanner() { $("banner").hidden = true; }

/** Shows the banner that belongs to the active file's conflict, or none. */
function refreshBanner() {
  const file = active && files.get(active);
  if (!file || !file.conflict) { hideBanner(); return; }
  const path = file.path;
  if (file.conflict === "deleted") {
    showBanner("This file was deleted on disk. Saving will recreate it.", [{ label: "OK", run: () => { file.conflict = null; renderTabs(); } }]);
  } else {
    showBanner("This file changed on disk, and you have unsaved changes.", [
      { label: "Reload", run: () => reload(path) },
      { label: "Keep mine", run: () => { file.conflict = null; renderTabs(); } },
    ]);
  }
}

/** Asks what to do with unsaved edits. Resolves "save", "discard" or "cancel". */
function confirmUnsaved(text) {
  return new Promise((resolve) => {
    showBanner(`${text} Save them?`, [
      { label: "Save", run: () => resolve("save") },
      { label: "Discard", run: () => resolve("discard") },
      { label: "Cancel", run: () => resolve("cancel") },
    ]);
  });
}

// ── Saving and reloading ───────────────────────────────────────────────
/** Saves a file. Resolves true when it is saved (or there is nothing to save). */
async function save(path = active, { force = false } = {}) {
  const file = files.get(path);
  if (!file) return true;
  if (!force) await fmtBeforeSave(file);
  const version = file.model.getAlternativeVersionId();
  try {
    const saved = await request("save", { path, text: file.model.getValue(), modified: force ? null : file.modified, bom: file.bom });
    file.modified = saved.modified;
    file.savedVersion = version;
    file.conflict = null;
    file.dirty = file.model.getAlternativeVersionId() !== file.savedVersion;
    renderTabs();
    publish();
    if (path === active) hideBanner();
    if (searchState.view === "changes") refreshChanges();
    return true;
  } catch (e) {
    if (path !== active) activate(path);
    if (e.code === "changed-on-disk") {
      showBanner("This file changed on disk since you opened it.", [
        { label: "Overwrite", run: () => save(path, { force: true }) },
        { label: "Reload", run: () => reload(path) },
        { label: "Cancel", run: refreshBanner },
      ]);
    } else {
      showBanner(`Couldn't save: ${e.message}`, [{ label: "OK", run: refreshBanner }]);
    }
    return false;
  }
}

/** ⌘S (the active file) or the close prompt's Save (every file with unsaved edits). Always tells Swift how it went. */
async function saveFromNative(all) {
  const targets = all ? order.filter((p) => files.get(p).dirty) : (active && files.get(active).dirty ? [active] : []);
  let ok = true;
  for (const path of targets) {
    if (!(await save(path))) { ok = false; break; }
  }
  post({ type: "saveDone", ok });
}

function applyToModel(file, doc) {
  const isActive = file.path === active;
  const view = isActive ? editor.saveViewState() : file.viewState;
  file.model.pushEditOperations([], [{ range: file.model.getFullModelRange(), text: doc.text }], () => null);
  file.modified = doc.modified;
  file.bom = doc.bom;
  file.savedVersion = file.model.getAlternativeVersionId();
  file.dirty = false;
  file.conflict = null;
  claudeMarks.delete(file.path);
  file.claudeIds = file.model.deltaDecorations(file.claudeIds, []);
  if (isActive) editor.restoreViewState(view); else file.viewState = view;
}

async function reload(path) {
  const file = files.get(path);
  if (!file) return;
  try {
    applyToModel(file, await request("read", { path }));
    renderTabs();
    publish();
    if (path === active) hideBanner();
  } catch (e) {
    showBanner(`Couldn't reload: ${e.message}`, [{ label: "OK", run: refreshBanner }]);
  }
}

function onExternalChange({ path, modified }) {
  if (searchState.view === "changes") refreshChanges();
  const file = files.get(path);
  if (!file) return;
  if (modified === null) file.conflict = "deleted";
  else if (!file.dirty) { reload(path); return; }
  else file.conflict = "changed";
  renderTabs();
  if (path === active) refreshBanner();
}

// ── File tree ──────────────────────────────────────────────────────────
const dirCache = new Map(); // folder ("" is the root) -> [{ name, dir }]
const expanded = new Set();

const dirErrors = new Map(); // folder -> why it couldn't be listed
const CHEVRON = '<svg viewBox="0 0 16 16" width="12" height="12"><path d="M6 4l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
// A folder's mark in coral, as the branch chip's, open while its entries show; files get a quiet page so names line up.
const FOLDER = '<svg viewBox="0 0 16 16" width="15" height="15"><path d="M1.75 4.25a1.5 1.5 0 0 1 1.5-1.5h2.6c.4 0 .78.16 1.06.44l1.1 1.06h4.74a1.5 1.5 0 0 1 1.5 1.5v6a1.5 1.5 0 0 1-1.5 1.5H3.25a1.5 1.5 0 0 1-1.5-1.5z" fill="currentColor" fill-opacity=".2" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></svg>';
const FOLDER_OPEN = '<svg viewBox="0 0 16 16" width="15" height="15"><path d="M2.25 12.25a.5.5 0 0 1-.5-.5v-7.5a1.5 1.5 0 0 1 1.5-1.5h2.6c.4 0 .78.16 1.06.44l1.1 1.06h4.24a1.5 1.5 0 0 1 1.5 1.5v1" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/><path d="M3.7 7.9a1 1 0 0 1 .95-.65h9.3a.75.75 0 0 1 .7 1.02l-1.42 3.65a1 1 0 0 1-.93.63H2.25z" fill="currentColor" fill-opacity=".2" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></svg>';
const FILE = '<svg viewBox="0 0 16 16" width="15" height="15"><path d="M4.25 1.75h4.6l3.4 3.4v8.1a1 1 0 0 1-1 1h-7a1 1 0 0 1-1-1v-10.5a1 1 0 0 1 1-1z" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/><path d="M8.75 1.9v3.35h3.35" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/></svg>';
const INDENT = 12; // px per level; the guides sit under each parent's chevron

async function loadDir(dir) {
  try {
    dirCache.set(dir, (await request("list", { path: dir })).entries);
    dirErrors.delete(dir);
  } catch (e) {
    dirCache.set(dir, []);
    dirErrors.set(dir, e.message || "Couldn't read this folder.");
    post({ type: "log", message: `list "${dir}" failed: ${e.message}` });
  }
  renderTree();
}

function toggleDir(dir) {
  if (expanded.has(dir)) {
    expanded.delete(dir);
  } else {
    expanded.add(dir);
    if (!dirCache.has(dir)) loadDir(dir);
  }
  renderTree();
  publish();
}

/** A row's left side: one guide per ancestor level, then the chevron's slot. */
function indent(row, depth) {
  row.style.paddingLeft = `${depth * INDENT + 6}px`;
  for (let level = 0; level < depth; level++) {
    const guide = document.createElement("span");
    guide.className = "guide";
    guide.style.left = `${level * INDENT + 11.5}px`;
    row.append(guide);
  }
}

function treeRow(entry, path, depth) {
  const row = document.createElement("div");
  const open = entry.dir && expanded.has(path);
  row.className = "row" + (entry.dir ? " dir" : "") + (open ? " open" : "") + (!entry.dir && path === active ? " active" : "")
    + (entry.name.startsWith(".") ? " dot" : "");
  indent(row, depth);
  const chev = document.createElement("span");
  chev.className = "chev";
  if (entry.dir) chev.innerHTML = CHEVRON;
  const icon = document.createElement("span");
  icon.className = "icon";
  icon.innerHTML = entry.dir ? (open ? FOLDER_OPEN : FOLDER) : FILE;
  const label = document.createElement("span");
  label.className = "label";
  // A file's extension steps back, so the names line up as the thing to read.
  const dot = entry.dir ? -1 : entry.name.lastIndexOf(".");
  if (dot > 0) {
    const ext = document.createElement("span");
    ext.className = "ext";
    ext.textContent = entry.name.slice(dot);
    label.append(entry.name.slice(0, dot), ext);
  } else {
    label.textContent = entry.name;
  }
  row.title = path;
  row.append(chev, icon, label);
  row.addEventListener("click", () => (entry.dir ? toggleDir(path) : openFile(path)));
  row.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    e.stopPropagation();
    openNewMenu(entry.dir ? path : parentOf(path), e.clientX, e.clientY);
  });
  return row;
}

/** A quiet line in place of a folder's entries: why it couldn't be read, or that it's empty. */
function noteRow(text, depth, error) {
  const row = document.createElement("div");
  row.className = "row note" + (error ? " error" : "");
  indent(row, depth);
  const label = document.createElement("span");
  label.className = "label";
  label.textContent = text;
  row.title = text;
  const chev = document.createElement("span"), icon = document.createElement("span");
  chev.className = "chev";
  icon.className = "icon";
  row.append(chev, icon, label);
  return row;
}

function renderTree() {
  const rows = [];
  const walk = (dir, depth) => {
    const entries = dirCache.get(dir);
    if (creating && creating.dir === dir) {
      creating.row.querySelectorAll(".guide").forEach((guide) => guide.remove());
      indent(creating.row, depth);
      rows.push(creating.row);
      if (creating.error) rows.push(noteRow(creating.error, depth, true));
    }
    if (dirErrors.has(dir)) { rows.push(noteRow(dirErrors.get(dir), depth, true)); return; }
    if (entries && entries.length === 0 && creating?.dir === dir) return;
    if (entries && entries.length === 0) { rows.push(noteRow(dir ? "Empty" : "This folder is empty", depth, false)); return; }
    for (const entry of entries || []) {
      const path = dir ? `${dir}/${entry.name}` : entry.name;
      rows.push(treeRow(entry, path, depth));
      if (entry.dir && expanded.has(path)) walk(path, depth + 1);
    }
  };
  walk("", 0);
  $("tree-list").replaceChildren(...rows);
  if (creating && document.activeElement !== creating.input) creating.input.focus();
}

// ── New File / New Folder ──────────────────────────────────────────────
// A name field opens as the folder's first row; Enter makes it through Swift (`a/b.ts` makes the folders too), Escape
// or leaving it empty drops it. A new file opens in a tab.
let creating = null; // { dir, directory, row, input, error, busy }

const parentOf = (path) => path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";

function openNewMenu(dir, x, y) {
  openMenu([
    { label: "New File…", run: () => startCreate(dir, false) },
    { label: "New Folder…", run: () => startCreate(dir, true) },
  ], x, y);
}

function startCreate(dir, directory) {
  cancelCreate();
  if (!session.treeOpen) setTreeOpen(true);
  if (typeof showView === "function") showView("files");
  const row = document.createElement("div");
  row.className = "row create" + (directory ? " dir" : "");
  const chev = document.createElement("span"), icon = document.createElement("span"), input = document.createElement("input");
  chev.className = "chev";
  icon.className = "icon";
  icon.innerHTML = directory ? FOLDER : FILE;
  input.type = "text";
  input.spellcheck = false;
  input.autocomplete = "off";
  input.setAttribute("autocapitalize", "off");
  input.placeholder = directory ? "Folder name" : "File name";
  input.setAttribute("aria-label", input.placeholder);
  row.append(chev, icon, input);
  creating = { dir, directory, row, input, error: "", busy: false };
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); commitCreate(); }
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); cancelCreate(); }
  });
  input.addEventListener("input", () => { if (creating?.error) { creating.error = ""; renderTree(); } });
  // A re-render moves the field and can blur it for a moment, so only a blur that sticks counts.
  input.addEventListener("blur", () => setTimeout(() => {
    if (creating?.input !== input || creating.busy || document.activeElement === input || !input.isConnected) return;
    input.value.trim() ? commitCreate() : cancelCreate();
  }));
  // Open the folder (and those above it) so the field shows where the new item goes.
  if (dir) {
    const parts = dir.split("/");
    for (let i = 1; i <= parts.length; i++) {
      const folder = parts.slice(0, i).join("/");
      expanded.add(folder);
      if (!dirCache.has(folder)) loadDir(folder);
    }
    publish();
  }
  renderTree();
  row.scrollIntoView({ block: "nearest" });
}

function cancelCreate() {
  if (!creating) return;
  creating = null;
  renderTree();
}

/** Why a typed name can't be made, or "" when it can. */
function nameProblem(name) {
  if (name.startsWith("/")) return "A name can't start with /.";
  if (name.split("/").some((part) => part === "" || part === "." || part === "..")) return "That isn't a valid name.";
  return "";
}

async function commitCreate() {
  const c = creating;
  if (!c || c.busy) return;
  const name = c.input.value.trim().replace(/\/+$/, "");
  if (!name) return cancelCreate();
  const problem = nameProblem(name);
  if (problem) { c.error = problem; renderTree(); return; }
  const path = c.dir ? `${c.dir}/${name}` : name;
  c.busy = true;
  try {
    await request("create", { path, dir: c.directory });
  } catch (e) {
    c.busy = false;
    if (creating !== c) return;
    c.error = e.message || "Couldn't create it.";
    renderTree();
    return;
  }
  if (creating === c) creating = null;
  // The folders typed on the way (`a/b` in `a/b/c.ts`) open, so the new item shows.
  const made = path.split("/").slice(0, -1);
  for (let i = c.dir ? c.dir.split("/").length + 1 : 1; i <= made.length; i++) expanded.add(made.slice(0, i).join("/"));
  await loadDir(c.dir);
  for (let i = c.dir ? c.dir.split("/").length + 1 : 1; i <= made.length; i++) await loadDir(made.slice(0, i).join("/"));
  publish();
  if (c.directory) revealInTree(path);
  else openFile(path);
}

$("new-file").addEventListener("click", () => startCreate(active ? parentOf(active) : "", false));
$("new-folder").addEventListener("click", () => startCreate(active ? parentOf(active) : "", true));
$("tree-list").addEventListener("contextmenu", (e) => { e.preventDefault(); openNewMenu("", e.clientX, e.clientY); });

/** Expands the folders above a file and scrolls its row into view. */
async function revealInTree(path) {
  const parts = path.split("/");
  for (let i = 1; i < parts.length; i++) {
    const dir = parts.slice(0, i).join("/");
    expanded.add(dir);
    if (!dirCache.has(dir)) await loadDir(dir);
  }
  renderTree();
  const row = $("tree-list").querySelector(".row.active");
  if (row) row.scrollIntoView({ block: "nearest" });
}

function setTreeWidth(width) {
  session.treeWidth = Math.max(160, Math.min(480, Math.round(width)));
  document.documentElement.style.setProperty("--tree-w", `${session.treeWidth}px`);
}
function setTreeOpen(open) {
  session.treeOpen = open;
  $("tree").hidden = !open;
  $("divider").hidden = !open;
  $("tree-toggle").classList.toggle("on", open);
}
$("tree-toggle").addEventListener("click", () => { setTreeOpen(!session.treeOpen); publish(); });
$("divider").addEventListener("pointerdown", (e) => {
  e.preventDefault();
  const divider = $("divider");
  divider.setPointerCapture(e.pointerId);
  const move = (ev) => setTreeWidth(ev.clientX);
  const up = () => { divider.removeEventListener("pointermove", move); divider.removeEventListener("pointerup", up); publish(); };
  divider.addEventListener("pointermove", move);
  divider.addEventListener("pointerup", up);
});

// ── Session ────────────────────────────────────────────────────────────
async function restoreSession(saved) {
  restoring = true;
  try {
    if (typeof saved.treeWidth === "number") setTreeWidth(saved.treeWidth);
    if (typeof saved.treeOpen === "boolean") setTreeOpen(saved.treeOpen);
    for (const dir of Array.isArray(saved.expanded) ? saved.expanded : []) {
      if (typeof dir !== "string") continue;
      expanded.add(dir);
      if (!dirCache.has(dir)) await loadDir(dir);
    }
    renderTree();
    for (const path of Array.isArray(saved.open) ? saved.open : []) {
      if (typeof path === "string") await openFile(path, { quiet: true });
    }
    pvRestore(saved.previews);
    fmtRestore(saved.wrap);
    if (typeof saved.active === "string" && files.has(saved.active)) activate(saved.active);
  } finally {
    restoring = false;
    publish();
  }
}

// ── Claude's changes ───────────────────────────────────────────────────
const claudeMarks = new Map(); // path -> [{ start, end, kind }]
const MARK_COLORS = { added: "#2a8f94", modified: "#e8643c", deleted: "#c0392b" };

function toDecoration(mark) {
  const deleted = mark.kind === "deleted";
  return {
    range: new monaco.Range(mark.start, 1, mark.end, 1),
    options: {
      isWholeLine: !deleted,
      linesDecorationsClassName: `claude-${mark.kind}`,
      overviewRuler: { color: MARK_COLORS[mark.kind], position: monaco.editor.OverviewRulerLane.Left },
      stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges,
    },
  };
}

function applyMarks(path) {
  const file = files.get(path);
  if (!file) return;
  const marks = (claudeMarks.get(path) || []).filter((m) => m.start <= file.model.getLineCount());
  file.claudeIds = file.model.deltaDecorations(file.claudeIds, marks.map(toDecoration));
}

/** Replaces every mark (Swift sends the latest turn's changes). */
function setClaudeChanges(map) {
  claudeMarks.clear();
  for (const [path, marks] of Object.entries(map || {})) if (marks.length) claudeMarks.set(path, marks);
  for (const path of order) applyMarks(path);
}

/** Every mark, as { path, line }, in path then line order. Open files use their live positions. */
function markPositions() {
  const out = [];
  for (const path of [...claudeMarks.keys()].sort()) {
    const file = files.get(path);
    const lines = file && file.claudeIds.length
      ? file.claudeIds.map((id) => file.model.getDecorationRange(id)).filter(Boolean).map((r) => r.startLineNumber)
      : claudeMarks.get(path).map((m) => m.start);
    for (const line of lines.sort((a, b) => a - b)) out.push({ path, line });
  }
  return out;
}

/** The next (direction 1) or previous (-1) change after the cursor, across files, wrapping around. */
function gotoChange(direction) {
  const list = markPositions();
  if (!list.length) return;
  const here = active ? { path: active, line: editor.getPosition().lineNumber } : null;
  const compare = (a, b) => (a.path === b.path ? a.line - b.line : a.path < b.path ? -1 : 1);
  let target;
  if (direction > 0) target = here ? list.find((p) => compare(p, here) > 0) : list[0];
  else target = here ? [...list].reverse().find((p) => compare(p, here) < 0) : list[list.length - 1];
  if (!target) target = direction > 0 ? list[0] : list[list.length - 1];
  openFile(target.path, { line: target.line });
}

// ── Quick open (⌘P) ────────────────────────────────────────────────────
let results = [];
let selected = 0;
let searchSeq = 0;

function renderResults() {
  $("results").replaceChildren(...results.map((path, i) => {
    const li = document.createElement("li");
    const slash = path.lastIndexOf("/");
    if (slash >= 0) {
      const dir = document.createElement("span");
      dir.className = "dir";
      dir.textContent = path.slice(0, slash + 1);
      li.append(dir, path.slice(slash + 1));
    } else {
      li.textContent = path;
    }
    if (i === selected) li.className = "sel";
    li.addEventListener("mousedown", (e) => { e.preventDefault(); choose(i); });
    return li;
  }));
  const sel = $("results").querySelector(".sel");
  if (sel) sel.scrollIntoView({ block: "nearest" });
}

async function search(query) {
  const seq = ++searchSeq;
  try {
    const found = await request("quickOpen", { query });
    if (seq !== searchSeq) return;
    results = found.paths;
    selected = 0;
    renderResults();
  } catch (e) { /* the palette just stays as it was */ }
}

function openPalette() {
  $("palette").hidden = false;
  $("q").value = "";
  $("q").focus();
  search("");
}
function closePalette() {
  $("palette").hidden = true;
  if (active) editor.focus();
}
function choose(index) {
  const path = results[index];
  closePalette();
  if (path) openFile(path);
}

$("q").addEventListener("input", () => search($("q").value));
$("q").addEventListener("keydown", (e) => {
  if (e.key === "Escape") { e.preventDefault(); closePalette(); }
  else if (e.key === "ArrowDown") { e.preventDefault(); selected = Math.min(selected + 1, results.length - 1); renderResults(); }
  else if (e.key === "ArrowUp") { e.preventDefault(); selected = Math.max(selected - 1, 0); renderResults(); }
  else if (e.key === "Enter") { e.preventDefault(); choose(selected); }
});
$("q").addEventListener("blur", () => { if (!$("palette").hidden) closePalette(); });

// ── Start ──────────────────────────────────────────────────────────────
// Once every script has run (createEditor calls ask.js, preview.js and format.js) and the font is in. A cached font
// settles at once, between scripts, which started the editor too early and left it blank, tree and all.
const fontLoaded = document.fonts.load('13px "JetBrains Mono"').catch(() => {});
document.addEventListener("DOMContentLoaded", () => fontLoaded.finally(() => {
  createEditor();
  setTreeWidth(session.treeWidth);
  setTreeOpen(true);
  showEditor(false);
  loadDir("");
  post({ type: "ready" });
}));
