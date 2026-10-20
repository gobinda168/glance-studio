"use strict";
// The status bar along the bottom, as in VS Code: the project's branch on the left (click: switch branch), the
// cursor's line and column and the file's language on the right. The branch is read again when the window comes
// forward and every few seconds, so a checkout in a terminal shows up here.

async function sbRefreshBranch() {
  let branch = null;
  try { branch = (await request("branch", {})).branch; } catch {}
  $("sb-branch").hidden = !branch;
  $("sb-branch-name").textContent = branch || "";
  $("sb-branch").title = branch ? `${branch}: switch branch` : "";
}

function sbRefreshCursor() {
  const model = editor && editor.getModel();
  $("sb-cursor").hidden = $("sb-lang").hidden = !model;
  if (!model) return;
  const p = editor.getPosition();
  const s = editor.getSelection();
  const picked = s && !s.isEmpty() ? model.getValueInRange(s).length : 0;
  $("sb-cursor").textContent = p ? `Ln ${p.lineNumber}, Col ${p.column}${picked ? ` (${picked} selected)` : ""}` : "";
  const id = model.getLanguageId();
  const language = monaco.languages.getLanguages().find((l) => l.id === id);
  $("sb-lang").textContent = (language && language.aliases && language.aliases[0]) || id;
}

function sbInit() {
  editor.onDidChangeCursorSelection(sbRefreshCursor);
  editor.onDidChangeModel(sbRefreshCursor);
  editor.onDidChangeModelLanguage(sbRefreshCursor);
  sbRefreshCursor();
  sbRefreshBranch();
  window.addEventListener("focus", sbRefreshBranch);
  setInterval(() => { if (!document.hidden) sbRefreshBranch(); }, 5000);
}

// ── Branch picker: the chip's click, as VS Code's "Select a ref to checkout" ──────────────────────────────────────────
// Rows: create a branch, then the local branches (the current one ticked), then remote ones (switching to one makes a
// local branch tracking it). Typing filters; a name that matches no branch offers to create it. git's refusal (local
// changes in the way) shows under the list and the picker stays open.
const bp = { list: null, rows: [], selected: 0, creating: false, busy: false };

async function openBranchPicker() {
  bp.creating = false;
  bp.list = null;
  $("berror").hidden = true;
  $("branch-picker").hidden = false;
  $("bq").value = "";
  $("bq").placeholder = "Switch to a branch, or type a new one's name";
  $("bq").focus();
  bpRender();
  try { bp.list = await request("branches", {}); } catch (e) { bp.list = { current: null, local: [], remote: [] }; bpError(e.message); }
  bpRender();
}

function closeBranchPicker() {
  $("branch-picker").hidden = true;
  if (active) editor.focus();
}

function bpRows() {
  const query = $("bq").value.trim();
  const q = query.toLowerCase();
  if (bp.creating) {
    return query ? [{ kind: "create", name: query, label: `Create branch “${query}”`, note: bp.list && bp.list.current ? `from ${bp.list.current}` : "" }]
      : [{ kind: "empty", label: "Type the new branch's name" }];
  }
  if (!bp.list) return [{ kind: "empty", label: "Reading the branches…" }];
  const match = (name) => !q || name.toLowerCase().includes(q);
  const rows = [];
  const exists = bp.list.local.includes(query) || bp.list.remote.some((r) => r.slice(r.indexOf("/") + 1) === query);
  if (query && !exists) rows.push({ kind: "create", name: query, label: `Create branch “${query}”`, note: bp.list.current ? `from ${bp.list.current}` : "" });
  if (!query) rows.push({ kind: "new", label: "Create new branch…" });
  const local = bp.list.local.filter(match);
  if (local.length) rows.push({ kind: "head", label: "Branches" });
  for (const name of local) rows.push({ kind: "local", name, label: name, current: name === bp.list.current, note: name === bp.list.current ? "current" : "" });
  const remote = bp.list.remote.filter(match);
  if (remote.length) rows.push({ kind: "head", label: "Remote" });
  for (const name of remote) rows.push({ kind: "remote", name, label: name, note: "remote" });
  if (!rows.some(bpPickable)) rows.push({ kind: "empty", label: "No branch matches" });
  return rows;
}

const bpPickable = (row) => row.kind !== "head" && row.kind !== "empty";
const BP_ICONS = { create: "+", new: "+", local: "⎇", remote: "☁" };

function bpRender() {
  bp.rows = bpRows();
  const pickable = bp.rows.map((row, i) => (bpPickable(row) ? i : -1)).filter((i) => i >= 0);
  // After typing: the first branch that matches, as in VS Code; creating one only when none does.
  const firstBranch = bp.rows.findIndex((row) => row.kind === "local" || row.kind === "remote");
  if (bp.selected === null) bp.selected = firstBranch >= 0 && $("bq").value.trim() ? firstBranch : pickable[0] ?? -1;
  if (!pickable.includes(bp.selected)) bp.selected = pickable[0] ?? -1;
  $("bresults").replaceChildren(...bp.rows.map((row, i) => {
    const li = document.createElement("li");
    li.className = [row.kind === "create" || row.kind === "new" ? "action" : row.kind, row.current ? "current" : "", i === bp.selected ? "sel" : ""].join(" ").trim();
    if (!bpPickable(row)) { li.textContent = row.label; return li; }
    const icon = document.createElement("span");
    icon.className = "b-icon";
    icon.textContent = row.current ? "✓" : BP_ICONS[row.kind];
    const name = document.createElement("span");
    name.className = "b-name";
    name.textContent = row.label;
    li.append(icon, name);
    if (row.note) {
      const note = document.createElement("span");
      note.className = "b-note";
      note.textContent = row.note;
      li.append(note);
    }
    li.addEventListener("mousedown", (e) => { e.preventDefault(); bpChoose(i); });
    return li;
  }));
  const sel = $("bresults").querySelector(".sel");
  if (sel) sel.scrollIntoView({ block: "nearest" });
}

function bpError(message) {
  $("berror").textContent = message;
  $("berror").hidden = !message;
}

function bpMove(step) {
  const pickable = bp.rows.map((row, i) => (bpPickable(row) ? i : -1)).filter((i) => i >= 0);
  if (!pickable.length) return;
  const at = pickable.indexOf(bp.selected);
  bp.selected = pickable[Math.max(0, Math.min(pickable.length - 1, at + step))];
  bpRender();
}

async function bpChoose(index) {
  const row = bp.rows[index];
  if (!row || !bpPickable(row) || bp.busy) return;
  if (row.kind === "new") {
    bp.creating = true;
    $("bq").value = "";
    $("bq").placeholder = "Name of the new branch";
    bpError("");
    bpRender();
    return;
  }
  if (row.current) { closeBranchPicker(); return; }
  bp.busy = true;
  bpError("");
  try {
    await request("switchBranch", { name: row.name, create: row.kind === "create", remote: row.kind === "remote" });
    closeBranchPicker();
    await sbRefreshBranch();
    sbAfterSwitch();
  } catch (e) {
    bpError(e.message);
  } finally {
    bp.busy = false;
  }
}

/** Another branch's files: list the open folders again (open files reload on their own as they change on disk). */
function sbAfterSwitch() {
  const dirs = ["", ...expanded];
  dirCache.clear();
  for (const dir of dirs) loadDir(dir);
  if (searchState.view === "changes") refreshChanges();
}

$("sb-branch").addEventListener("click", openBranchPicker);
$("bq").addEventListener("input", () => { bpError(""); bp.selected = null; bpRender(); });
$("bq").addEventListener("keydown", (e) => {
  if (e.key === "Escape") { e.preventDefault(); bp.creating ? openBranchPicker() : closeBranchPicker(); }
  else if (e.key === "ArrowDown") { e.preventDefault(); bpMove(1); }
  else if (e.key === "ArrowUp") { e.preventDefault(); bpMove(-1); }
  else if (e.key === "Enter") { e.preventDefault(); bpChoose(bp.selected); }
});
$("bq").addEventListener("blur", () => { if (!$("branch-picker").hidden && !bp.busy) closeBranchPicker(); });
