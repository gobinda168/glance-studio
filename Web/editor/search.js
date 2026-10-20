"use strict";
// The Search panel of the editor page: project-wide search and replace through Swift. It reuses editor.js's globals.

const searchState = { caseSensitive: false, wholeWord: false, regex: false, view: "files" };
let projectSeq = 0;
let projectTimer = null;
let lastResult = null;

function showView(view) {
  searchState.view = view;
  $("tab-files").classList.toggle("on", view === "files");
  $("tab-search").classList.toggle("on", view === "search");
  $("tab-changes").classList.toggle("on", view === "changes");
  $("tree-list").hidden = view !== "files";
  $("files-bar").hidden = view !== "files";
  $("search-panel").hidden = view !== "search";
  $("changes-panel").hidden = view !== "changes";
  if (view === "changes") refreshChanges();
}

function searchOptions() {
  return { caseSensitive: searchState.caseSensitive, wholeWord: searchState.wholeWord, regex: searchState.regex };
}

function setSummary(text, isError = false) {
  $("s-summary").textContent = text;
  $("s-summary").classList.toggle("error", isError);
}

/** Runs the search for the current query (the previous one is superseded; Swift cancels its scan). */
async function runSearch() {
  const query = $("s-query").value;
  const seq = ++projectSeq;
  if (!query) { lastResult = null; $("s-results").replaceChildren(); setSummary(""); return; }
  setSummary("Searching…");
  try {
    const result = await request("search", { query, options: searchOptions() });
    if (seq !== projectSeq) return;
    lastResult = result;
    renderSearchResults(result);
  } catch (e) {
    if (seq !== projectSeq || e.code === "cancelled") return;
    lastResult = null;
    $("s-results").replaceChildren();
    setSummary(e.message, true);
  }
}

function queueSearch() {
  clearTimeout(projectTimer);
  projectTimer = setTimeout(runSearch, 250);
}

function highlighted(match) {
  const tx = document.createElement("span");
  tx.className = "tx";
  const before = match.preview.slice(0, match.previewStart);
  const hit = match.preview.slice(match.previewStart, match.previewStart + match.length);
  const after = match.preview.slice(match.previewStart + match.length);
  const mark = document.createElement("mark");
  mark.textContent = hit;
  tx.append(before, mark, after);
  return tx;
}

function renderSearchResults(result) {
  const byFile = new Map();
  for (const match of result.matches) {
    if (!byFile.has(match.path)) byFile.set(match.path, []);
    byFile.get(match.path).push(match);
  }
  const nodes = [];
  for (const [path, matches] of byFile) {
    const slash = path.lastIndexOf("/");
    const head = document.createElement("div");
    head.className = "sfile";
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = path.slice(slash + 1);
    const dir = document.createElement("span");
    dir.className = "dir";
    dir.textContent = slash >= 0 ? path.slice(0, slash) : "";
    const count = document.createElement("span");
    count.className = "count";
    count.textContent = String(matches.length);
    const rin = document.createElement("button");
    rin.className = "rin";
    rin.textContent = "Replace";
    rin.title = `Replace in ${path}`;
    rin.addEventListener("click", () => replaceIn([path]));
    head.append(name, dir, count, rin);
    nodes.push(head);
    for (const match of matches) {
      const row = document.createElement("div");
      row.className = "smatch";
      const ln = document.createElement("span");
      ln.className = "ln";
      ln.textContent = String(match.line);
      row.append(ln, highlighted(match));
      row.title = `${path}:${match.line}:${match.column}`;
      row.addEventListener("click", () => openFile(path, { line: match.line, column: match.column }));
      nodes.push(row);
    }
  }
  $("s-results").replaceChildren(...nodes);
  const total = result.matches.length;
  setSummary(total === 0 ? "No results" : `${total}${result.truncated ? "+" : ""} result${total === 1 ? "" : "s"} in ${result.files} file${result.files === 1 ? "" : "s"}${result.truncated ? " (showing the first matches)" : ""}`);
}

/** Replaces on disk, never touching a file with unsaved edits; reloads clean open files; refreshes the results. */
async function replaceIn(paths) {
  const query = $("s-query").value;
  if (!query) return;
  const total = lastResult ? lastResult.matches.filter((m) => !paths || paths.includes(m.path)).length : 0;
  const scope = paths ? `${paths.length === 1 ? paths[0] : paths.length + " files"}` : "the project";
  const dirty = order.filter((p) => files.get(p).dirty);
  const message = `Replace ${total || "all"} match${total === 1 ? "" : "es"} of "${query}" with "${$("s-replace").value}" in ${scope}? Files with unsaved edits are skipped.`;
  const confirmed = await new Promise((resolve) => {
    showBanner(message, [
      { label: "Replace", run: () => resolve(true) },
      { label: "Cancel", run: () => resolve(false) },
    ]);
  });
  if (!confirmed) { refreshBanner(); return; }
  setSummary("Replacing…");
  let done;
  try {
    done = await request("replace", { query, options: searchOptions(), replacement: $("s-replace").value, paths, skip: dirty });
  } catch (e) {
    setSummary(e.message, true);
    return;
  }
  for (const path of order) {
    const file = files.get(path);
    if (file && !file.dirty) reload(path); // clean open files take the new text now; the poller would get there too
  }
  const notes = [];
  if (done.skipped.length) notes.push(`${done.skipped.length} skipped (unsaved edits): ${done.skipped.join(", ")}`);
  if (done.failed.length) notes.push(`${done.failed.length} failed: ${done.failed.map((f) => `${f.path} (${f.message})`).join("; ")}`);
  await runSearch();
  const summary = `Replaced ${done.replacements} in ${done.files} file${done.files === 1 ? "" : "s"}.` + (notes.length ? " " + notes.join(". ") : "");
  setSummary(summary, done.failed.length > 0);
}

function toggleOption(id, key) {
  searchState[key] = !searchState[key];
  $(id).classList.toggle("on", searchState[key]);
  runSearch();
}

$("tab-files").addEventListener("click", () => showView("files"));
$("tab-search").addEventListener("click", () => { showView("search"); $("s-query").focus(); });
$("s-query").addEventListener("input", queueSearch);
$("s-query").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); clearTimeout(projectTimer); runSearch(); } });
$("s-case").addEventListener("click", () => toggleOption("s-case", "caseSensitive"));
$("s-word").addEventListener("click", () => toggleOption("s-word", "wholeWord"));
$("s-regex").addEventListener("click", () => toggleOption("s-regex", "regex"));
$("s-replace-all").addEventListener("click", () => replaceIn(null));

/** ⌘⇧F: show the panel, prefilled with a single-line selection. */
editorHost.search = () => {
  setTreeOpen(true);
  showView("search");
  const selection = editor && editor.getSelection();
  if (selection && !selection.isEmpty() && selection.startLineNumber === selection.endLineNumber) {
    $("s-query").value = editor.getModel().getValueInRange(selection);
    runSearch();
  }
  $("s-query").focus();
  $("s-query").select();
};

showView("files");
