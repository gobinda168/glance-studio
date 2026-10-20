"use strict";
// The Changes panel of the editor page: the project's uncommitted changes, staged and not, a diff view for one file,
// (optionally) which files Claude changed, and committing: stage, unstage, revert, and a message Claude can draft.
// It reuses editor.js's globals.

const changesState = {
  staged: [], unstaged: [], error: null, claude: new Set(), mark: true, only: false, loaded: false, seq: 0,
  busy: false, drafting: false, draftBefore: "", confirm: null, msgLoaded: false,
  tree: true, collapsed: new Set(), // "staged:" / "unstaged:" for a section, "staged:src/app" for a folder in it
};
try {
  changesState.mark = localStorage.getItem("glance.changes.mark") !== "false";
  changesState.only = localStorage.getItem("glance.changes.only") === "true";
  changesState.tree = localStorage.getItem("glance.changes.tree") !== "false";
} catch {}

const STATUS = {
  M: ["M", "Modified", "#d29922"], A: ["A", "Added", "#2ea043"], D: ["D", "Deleted", "#f85149"],
  R: ["R", "Renamed", "#58a6ff"], U: ["U", "Untracked", "#2ea043"],
};

const ICONS = {
  stage: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M8 3.5v9M3.5 8h9"/></svg>',
  unstage: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M3.5 8h9"/></svg>',
  revert: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M5.5 3.5 3 6l2.5 2.5"/><path d="M3 6h6.25a3.25 3.25 0 0 1 0 6.5H6.5"/></svg>',
  open: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"><path d="M7.5 1.75H4.25a1 1 0 0 0-1 1v10.5a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1V6.5"/><path stroke-linecap="round" d="M9.5 1.75h3.25V5M12.75 1.75 7.75 6.75"/></svg>',
  tree: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"><path d="M3 3h10M6 6.5h7M6 10h7M9 13.5h4M3.5 3v7.5M3.5 6.5H5M3.5 10H5"/></svg>',
  list: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"><path d="M3 4h10M3 8h10M3 12h10"/></svg>',
};

function remember(key, value) { try { localStorage.setItem(key, String(value)); } catch {} }

/** The message box's draft is kept per project. */
const messageKey = () => "glance.commitMessage:" + ($("files-root").title || "");
function saveMessage() {
  try {
    const text = $("c-msg").value;
    text.trim() ? localStorage.setItem(messageKey(), text) : localStorage.removeItem(messageKey());
  } catch {}
}
function loadMessage() {
  if (changesState.msgLoaded || !$("files-root").title) return;
  changesState.msgLoaded = true;
  try { if (!$("c-msg").value) $("c-msg").value = localStorage.getItem(messageKey()) || ""; } catch {}
  sizeMessage();
}
function sizeMessage() {
  const box = $("c-msg");
  box.style.height = "auto";
  box.style.height = Math.min(box.scrollHeight + 2, 160) + "px";
}

async function refreshChanges() {
  const seq = ++changesState.seq;
  let lists = null;
  let error = null;
  try { lists = await request("changes", {}); } catch (e) { error = e.code === "notGit" ? "Not a git repository" : e.message; }
  if (seq !== changesState.seq) return;
  changesState.loaded = true;
  changesState.staged = lists?.staged || [];
  changesState.unstaged = lists?.unstaged || [];
  changesState.error = error;
  loadMessage();
  // The diff on screen belongs to a change that's gone (staged, unstaged, reverted, committed): leave it.
  if (diffState.path && !(diffState.staged ? changesState.staged : changesState.unstaged).some((c) => c.path === diffState.path)) {
    closeDiff(false);
  }
  renderChanges();
}

function setClaudeFiles(paths) {
  changesState.claude = new Set(Array.isArray(paths) ? paths : []);
  if (changesState.loaded) renderChanges();
}

function renderChanges() {
  const { staged, unstaged, claude, mark, busy } = changesState;
  const paths = new Set([...staged, ...unstaged].map((c) => c.path));
  const byClaude = [...paths].filter((p) => claude.has(p)).length;
  $("c-mark").checked = mark;
  $("c-only").hidden = !mark;
  $("c-only").classList.toggle("on", changesState.only);
  // The button says what a click does: the other view.
  $("c-view").innerHTML = ICONS[changesState.tree ? "list" : "tree"];
  $("c-view").title = changesState.tree ? "View as List" : "View as Tree";
  $("c-view").setAttribute("aria-label", $("c-view").title);
  $("tab-changes").textContent = paths.size ? `Changes (${paths.size})` : "Changes";
  // The sections count the files; the summary only says what they can't.
  $("c-summary").textContent = changesState.error || (paths.size === 0 ? "No changes" : mark && byClaude ? `${byClaude} by Claude` : "");
  const filter = (list) => (mark && changesState.only ? list.filter((c) => claude.has(c.path)) : list);
  const shownStaged = filter(staged);
  const shownUnstaged = filter(unstaged);
  const rows = [];
  const section = (title, list, staged) => {
    const key = sectionKey(staged, "");
    rows.push(sectionHead(title, list.length, key, listActions(list, staged, count(list))));
    if (changesState.collapsed.has(key)) return;
    if (changesState.tree) rows.push(...treeRows(list, staged));
    else rows.push(...list.map((c) => changeRow(c, staged, null)));
  };
  if (shownStaged.length) section("Staged", shownStaged, true);
  if (shownUnstaged.length) section("Changes", shownUnstaged, false);
  $("c-list").classList.toggle("tree", changesState.tree);
  $("c-list").replaceChildren(...rows);
  renderCommit();
}

const count = (list) => (list.length === 1 ? "this file" : `these ${list.length} files`);
const sectionKey = (staged, dir) => (staged ? "staged:" : "unstaged:") + dir;

/** Stage/unstage/revert buttons for a set of changes: a section's, or a folder's. */
function listActions(list, staged, what) {
  return staged
    ? [actionButton("unstage", `Unstage ${what}`, () => unstage(list))]
    : [actionButton("revert", `Revert ${what}`, () => askRevert(list)),
       actionButton("stage", `Stage ${what}`, () => stage(list))];
}

function toggleCollapsed(key) {
  changesState.collapsed.has(key) ? changesState.collapsed.delete(key) : changesState.collapsed.add(key);
  renderChanges();
}

function sectionHead(title, n, key, actions) {
  const head = document.createElement("div");
  head.className = "chead" + (changesState.collapsed.has(key) ? "" : " open");
  head.addEventListener("click", () => toggleCollapsed(key));
  const chev = document.createElement("span");
  chev.className = "chev";
  chev.innerHTML = CHEVRON;
  const label = document.createElement("span");
  label.textContent = title;
  const number = document.createElement("span");
  number.className = "c-count";
  number.textContent = n;
  const gap = document.createElement("span");
  gap.className = "c-gap";
  const acts = document.createElement("span");
  acts.className = "c-acts";
  acts.append(...actions);
  head.append(chev, label, number, gap, acts);
  return head;
}

// ── Tree view ──────────────────────────────────────────────────────────
/** A section's changes as folders, VS Code style: a folder holding only one folder folds into it ("src/app/pages"). */
function buildTree(list) {
  const root = { name: "", path: "", dirs: new Map(), files: [], all: [] };
  for (const change of list) {
    const parts = change.path.split("/");
    let node = root;
    node.all.push(change);
    for (const part of parts.slice(0, -1)) {
      const path = node.path ? `${node.path}/${part}` : part;
      if (!node.dirs.has(part)) node.dirs.set(part, { name: part, path, dirs: new Map(), files: [], all: [] });
      node = node.dirs.get(part);
      node.all.push(change);
    }
    node.files.push(change);
  }
  const compact = (node) => {
    for (const [key, child] of node.dirs) {
      let folded = child;
      while (folded.files.length === 0 && folded.dirs.size === 1) {
        const only = [...folded.dirs.values()][0];
        folded = { ...only, name: `${folded.name}/${only.name}` };
      }
      node.dirs.set(key, folded);
      compact(folded);
    }
  };
  compact(root);
  return root;
}

function treeRows(list, staged) {
  const rows = [];
  const byName = (a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
  const walk = (node, depth) => {
    for (const dir of [...node.dirs.values()].sort((a, b) => byName(a.name, b.name))) {
      const key = sectionKey(staged, dir.path);
      const open = !changesState.collapsed.has(key);
      rows.push(folderRow(dir, staged, depth, open, key));
      if (open) walk(dir, depth + 1);
    }
    const name = (c) => c.path.slice(c.path.lastIndexOf("/") + 1);
    for (const change of [...node.files].sort((a, b) => byName(name(a), name(b)))) rows.push(changeRow(change, staged, depth));
  };
  walk(buildTree(list), 0);
  return rows;
}

function folderRow(dir, staged, depth, open, key) {
  const row = document.createElement("div");
  row.className = "citem cdir" + (open ? " open" : "");
  row.title = `${dir.path} (${dir.all.length} ${dir.all.length === 1 ? "file" : "files"})`;
  indent(row, depth);
  const chev = document.createElement("span");
  chev.className = "chev";
  chev.innerHTML = CHEVRON;
  const icon = document.createElement("span");
  icon.className = "icon";
  icon.innerHTML = open ? FOLDER_OPEN : FOLDER;
  const name = document.createElement("span");
  name.className = "c-name";
  name.textContent = dir.name;
  const gap = document.createElement("span");
  gap.className = "c-gap";
  const what = dir.all.length === 1 ? "this file" : `the ${dir.all.length} files in ${dir.name.split("/").pop()}`;
  const acts = document.createElement("span");
  acts.className = "c-acts";
  acts.append(...listActions(dir.all, staged, what));
  // One status for the folder when its files share one; a quiet dot when they're mixed.
  const kinds = new Set(dir.all.map((c) => c.status));
  const dot = document.createElement("span");
  dot.className = "c-status c-dot";
  dot.style.color = kinds.size === 1 ? (STATUS[[...kinds][0]] || STATUS.M)[2] : "";
  row.append(chev, icon, name, gap, acts, dot);
  row.addEventListener("click", () => toggleCollapsed(key));
  return row;
}

function actionButton(icon, title, run) {
  const button = document.createElement("button");
  button.className = "c-act";
  button.title = title;
  button.setAttribute("aria-label", title);
  button.innerHTML = ICONS[icon];
  button.disabled = changesState.busy;
  button.addEventListener("click", (e) => { e.stopPropagation(); run(); });
  return button;
}

/** A changed file. `depth`: its level in the tree view, or null in the list view (where its folder follows the name). */
function changeRow(change, staged, depth) {
  const { claude, mark } = changesState;
  const [letter, label, color] = STATUS[change.status] || STATUS.M;
  const row = document.createElement("div");
  row.className = "citem" + (change.path === diffState.path && staged === diffState.staged ? " on" : "")
    + (change.status === "D" ? " deleted" : "");
  row.title = `${label}${staged ? ", staged" : ""}: ${change.path}` + (change.oldPath ? ` (was ${change.oldPath})` : "");
  const slash = change.path.lastIndexOf("/");
  const name = document.createElement("span");
  name.className = "c-name";
  name.textContent = change.path.slice(slash + 1);
  const dir = document.createElement("span");
  dir.className = "c-dir";
  dir.textContent = depth === null && slash > 0 ? change.path.slice(0, slash) : "";
  const lead = [];
  if (depth !== null) {
    indent(row, depth);
    const chev = document.createElement("span");
    chev.className = "chev";
    const icon = document.createElement("span");
    icon.className = "icon";
    icon.innerHTML = FILE;
    lead.push(chev, icon);
  }
  const badge = document.createElement("span");
  badge.className = "c-claude";
  badge.textContent = "C";
  badge.title = "Changed by Claude";
  badge.hidden = !(mark && claude.has(change.path));
  const acts = document.createElement("span");
  acts.className = "c-acts";
  if (change.status !== "D") acts.append(actionButton("open", "Open File", () => {
    if (diffState.path === change.path) closeDiff(true); // the file itself, not its diff
    openFile(change.path);
  }));
  acts.append(...(staged
    ? [actionButton("unstage", "Unstage", () => unstage([change]))]
    : [actionButton("revert", change.status === "U" ? "Move to the Trash" : "Revert", () => askRevert([change])),
       actionButton("stage", "Stage", () => stage([change]))]));
  const status = document.createElement("span");
  status.className = "c-status";
  status.textContent = letter;
  status.style.color = color;
  row.append(...lead, name, dir, badge, acts, status);
  row.addEventListener("click", () => openDiff(change, staged));
  return row;
}

// ── Staging, reverting, committing ─────────────────────────────────────
/** Runs one git action, then reloads the lists. Its error shows under the commit button. */
async function gitAction(type, fields) {
  if (changesState.busy) return false;
  changesState.busy = true;
  showGitError(null);
  renderChanges();
  let done = true;
  try { await request(type, fields); } catch (e) { showGitError(e.message); done = false; }
  changesState.busy = false;
  await refreshChanges();
  return done;
}

const pathsOf = (list) => list.flatMap((c) => (c.oldPath ? [c.path, c.oldPath] : [c.path]));
const stage = (list) => gitAction("stage", { paths: pathsOf(list) });
const unstage = (list) => gitAction("unstage", { paths: pathsOf(list) });

function askRevert(list) {
  const untracked = list.filter((c) => c.status === "U");
  const one = list.length === 1 ? `“${list[0].path.split("/").pop()}”` : null;
  $("c-confirm-text").textContent = one
    ? (untracked.length ? `Move ${one} to the Trash?` : `Revert ${one}? Its unstaged changes are lost.`)
    : `Revert ${list.length} files? Their unstaged changes are lost` + (untracked.length ? `, and ${untracked.length} new ${untracked.length === 1 ? "file goes" : "files go"} to the Trash.` : ".");
  $("c-confirm-yes").textContent = one && untracked.length ? "Move to Trash" : "Revert";
  changesState.confirm = list;
  $("c-confirm").hidden = false;
  $("c-confirm-yes").focus();
}

function closeConfirm() {
  changesState.confirm = null;
  $("c-confirm").hidden = true;
}

async function confirmRevert() {
  const list = changesState.confirm;
  closeConfirm();
  if (!list) return;
  await gitAction("discard", { tracked: list.filter((c) => c.status !== "U").map((c) => c.path),
                               untracked: list.filter((c) => c.status === "U").map((c) => c.path) });
}

function renderCommit() {
  const n = changesState.staged.length;
  const button = $("c-commit-btn");
  button.textContent = n ? `Commit ${n} ${n === 1 ? "file" : "files"}` : "Commit";
  button.disabled = changesState.busy || changesState.drafting || !n || !$("c-msg").value.trim();
  button.title = !n ? "Stage changes to commit them" : !$("c-msg").value.trim() ? "Write a message first" : "Commit the staged changes (⌘↩)";
  $("c-draft").disabled = !changesState.drafting && (changesState.staged.length + changesState.unstaged.length === 0);
}

async function commit() {
  if ($("c-commit-btn").disabled) return;
  if (await gitAction("commit", { message: $("c-msg").value })) {
    $("c-msg").value = "";
    saveMessage();
    sizeMessage();
    renderCommit();
  }
}

function showGitError(message) {
  $("c-error").textContent = message || "";
  $("c-error").hidden = !message;
}

// ── The commit message draft (✦) ───────────────────────────────────────
function toggleDraft() {
  if (changesState.drafting) {
    post({ type: "draftCommitStop" });
    endDraft();
    return;
  }
  changesState.drafting = true;
  changesState.draftBefore = $("c-msg").value;
  $("c-msg").value = "";
  $("c-msg").readOnly = true;
  $("c-msg").placeholder = "Claude is writing…";
  $("c-msg-wrap").classList.add("drafting");
  $("c-draft").title = "Stop";
  showGitError(null);
  renderCommit();
  post({ type: "draftCommit" });
}

function endDraft() {
  changesState.drafting = false;
  $("c-msg").readOnly = false;
  $("c-msg").placeholder = "Message (⌘↩ to commit)";
  $("c-msg-wrap").classList.remove("drafting");
  $("c-draft").title = "Write the message with Claude";
  saveMessage();
  sizeMessage();
  renderCommit();
}

function commitDraft(e) {
  if (!changesState.drafting) return;
  if (e.kind === "text") {
    $("c-msg").value += e.text;
    sizeMessage();
    return;
  }
  if (e.kind === "done") $("c-msg").value = e.text;
  if (e.kind === "failed") {
    $("c-msg").value = changesState.draftBefore;
    showGitError(e.message);
  }
  endDraft();
  if (e.kind === "done") $("c-msg").focus();
}

// ── Diff view ──────────────────────────────────────────────────────────
const diffState = { path: null, staged: false, editor: null, original: null, ownModified: null, inline: false };

/** A staged change: HEAD against the staged text, read-only. An unstaged one: the staged text against the file, in
 * the file's own model (edits and ⌘S work as usual). */
async function openDiff(change, staged) {
  const text = async (type, path) => { try { return (await request(type, { path })).text ?? ""; } catch { return ""; } };
  let original = "";
  let modified = null;
  if (staged) {
    if (change.status !== "A") original = await text("headText", change.oldPath || change.path);
    modified = change.status === "D" ? "" : await text("indexText", change.path);
  } else {
    if (change.status !== "D") await openFile(change.path);
    if (change.status !== "U") original = await text("indexText", change.path);
  }
  showDiff(change, staged, original, modified);
}

function showDiff(change, staged, head, staticText) {
  closeDiff(true);
  const file = staticText === null ? files.get(change.path) : null;
  const language = file ? file.model.getLanguageId() : monaco.languages.getLanguages().find((l) =>
    (l.extensions || []).some((ext) => change.path.endsWith(ext)))?.id || "plaintext";
  diffState.original = monaco.editor.createModel(head, language);
  diffState.ownModified = file ? null : monaco.editor.createModel(staticText ?? "", language);
  if (!diffState.editor) {
    diffState.editor = monaco.editor.createDiffEditor($("diff"), {
      theme: themeName(), automaticLayout: true, renderSideBySide: !diffState.inline, originalEditable: false,
      fontFamily: '"JetBrains Mono", ui-monospace, Menlo, monospace', fontSize: 13, minimap: { enabled: false },
      scrollBeyondLastLine: false,
    });
  }
  diffState.editor.setModel({ original: diffState.original, modified: file ? file.model : diffState.ownModified });
  diffState.editor.getModifiedEditor().updateOptions({ readOnly: !file });
  diffState.path = change.path;
  diffState.staged = staged;
  const what = change.status === "U" || change.status === "A" ? "new file" : change.status === "D" ? "deleted"
    : staged ? "staged" : "not staged";
  $("diff-title").textContent = `${change.path} — ${what}`;
  $("diff-layout").textContent = diffState.inline ? "Side by side" : "Inline";
  $("panes").hidden = true;
  $("pathbar").hidden = true;
  $("empty").hidden = true;
  $("diffbar").hidden = false;
  $("diff").hidden = false;
  diffState.editor.getModifiedEditor().focus();
  renderChanges();
}

/** Leaves the diff view. `keepView`: another view takes over at once (no switch back to the editor here). */
function closeDiff(keepView) {
  if (!diffState.path) return;
  diffState.editor.setModel(null); // the file's own model stays: its tab still owns it
  diffState.original?.dispose();
  diffState.ownModified?.dispose();
  diffState.original = null;
  diffState.ownModified = null;
  diffState.path = null;
  $("diffbar").hidden = true;
  $("diff").hidden = true;
  if (!keepView) showEditor(!!active);
  if (changesState.loaded) renderChanges();
}

$("tab-changes").addEventListener("click", () => showView("changes"));
$("c-refresh").addEventListener("click", () => refreshChanges());
$("c-view").addEventListener("click", () => { changesState.tree = !changesState.tree; remember("glance.changes.tree", changesState.tree); renderChanges(); });
$("c-mark").addEventListener("change", (e) => { changesState.mark = e.target.checked; remember("glance.changes.mark", changesState.mark); renderChanges(); });
$("c-only").addEventListener("click", () => { changesState.only = !changesState.only; remember("glance.changes.only", changesState.only); renderChanges(); });
$("c-msg").addEventListener("input", () => { sizeMessage(); saveMessage(); renderCommit(); });
$("c-msg").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && e.metaKey) { e.preventDefault(); commit(); }
});
$("c-commit-btn").addEventListener("click", () => commit());
$("c-draft").addEventListener("click", () => toggleDraft());
$("c-confirm-yes").addEventListener("click", () => confirmRevert());
$("c-confirm-no").addEventListener("click", () => closeConfirm());
$("c-confirm").addEventListener("keydown", (e) => { if (e.key === "Escape") { e.stopPropagation(); closeConfirm(); } });
$("diff-close").addEventListener("click", () => closeDiff(false));
$("diff-prev").addEventListener("click", () => diffState.editor?.goToDiff("previous"));
$("diff-next").addEventListener("click", () => diffState.editor?.goToDiff("next"));
$("diff-layout").addEventListener("click", () => {
  diffState.inline = !diffState.inline;
  diffState.editor?.updateOptions({ renderSideBySide: !diffState.inline });
  $("diff-layout").textContent = diffState.inline ? "Side by side" : "Inline";
});
