"use strict";
// The path bar above the code (project › folders › file, with copy) and the Markdown/HTML preview beside or instead of
// it. The preview costs nothing until it's switched on for a file: Markdown renders with the markdown-it the page
// already has, after typing pauses, into a frame that can't run scripts; HTML runs in a sandboxed frame. Images,
// stylesheets and scripts come from the project through glance-file:// (Swift's PreviewSchemeHandler).
// Names here start with "pv": this script shares its global scope with editor.js and the others.

const PV_ORIGIN = "glance-file://project/";
const pvProject = { name: "", root: "" };
let pvFrame = null; // the preview's iframe
let pvFrameKey = null; // "kind:path" the frame was made for
let pvFrameReady = false;
let pvPending = null; // Markdown body waiting for the frame to load
let pvTimer = 0;
let pvSyncing = false;

function pvSetProject(info) {
  pvProject.name = (info && info.name) || "";
  pvProject.root = (info && info.root) || "";
  if (active) pvRenderPath();
}

/** "markdown", "html", or null for a file with no preview. */
function pvKind(path) {
  const ext = (path || "").split(".").pop().toLowerCase();
  if (ext === "md" || ext === "markdown" || ext === "mdown" || ext === "mkd") return "markdown";
  if (ext === "html" || ext === "htm" || ext === "xhtml") return "html";
  return null;
}

/** The active file's view: "code", "split" or "preview" (Markdown and HTML open as their preview). */
function pvMode(path = active) {
  const file = path && files.get(path);
  if (!file || !pvKind(path)) return "code";
  return file.preview || "preview";
}

/** For the saved session: every open file whose view was picked by hand. */
function pvModes() {
  const out = {};
  for (const path of order) if (files.get(path).preview) out[path] = files.get(path).preview;
  return out;
}

function pvRestore(saved) {
  if (!saved || typeof saved !== "object") return;
  for (const [path, mode] of Object.entries(saved)) {
    const file = files.get(path);
    if (file && pvKind(path) && ["code", "split", "preview"].includes(mode)) file.preview = mode;
  }
  if (active) pvShow(true);
}

function pvUrl(path) { return PV_ORIGIN + path.split("/").map(encodeURIComponent).join("/"); }

// ── Path bar ───────────────────────────────────────────────────────────
function pvRenderPath() {
  const parts = active ? active.split("/") : [];
  const nodes = [];
  const crumb = (text, cls, onClick) => {
    const el = document.createElement(onClick ? "button" : "span");
    el.className = "crumb" + (cls ? " " + cls : "");
    el.textContent = text;
    if (onClick) el.addEventListener("click", onClick);
    return el;
  };
  const sep = () => Object.assign(document.createElement("span"), { className: "sep", textContent: "›" });
  if (pvProject.name) {
    const root = crumb(pvProject.name, "root", () => pvRevealFolder(""));
    root.title = pvProject.root;
    nodes.push(root, sep());
  }
  parts.forEach((name, i) => {
    const last = i === parts.length - 1;
    const dir = parts.slice(0, i + 1).join("/");
    const el = last ? crumb(name, "file") : crumb(name, i < parts.length - 3 ? "cut" : "", () => pvRevealFolder(dir));
    el.title = last ? active : dir;
    nodes.push(el);
    if (!last) nodes.push(sep());
  });
  $("crumbs").replaceChildren(...nodes);
  const kind = pvKind(active);
  $("pv-modes").hidden = !kind;
  if (kind) {
    const mode = pvMode();
    for (const b of $("pv-modes").children) b.classList.toggle("on", b.dataset.mode === mode);
    $("pv-modes").title = kind === "html" ? "HTML preview" : "Markdown preview";
  }
}

/** Shows a folder in the file tree: opens the tree, expands down to it and scrolls it into view. */
async function pvRevealFolder(dir) {
  if (!session.treeOpen) { setTreeOpen(true); publish(); }
  showView("files");
  if (!dir) { $("tree-list").scrollTop = 0; return; }
  const parts = dir.split("/");
  for (let i = 1; i <= parts.length; i++) {
    const folder = parts.slice(0, i).join("/");
    expanded.add(folder);
    if (!dirCache.has(folder)) await loadDir(folder);
  }
  renderTree();
  publish();
  const row = [...$("tree-list").querySelectorAll(".row")].find((r) => r.title === dir);
  if (row) row.scrollIntoView({ block: "center" });
}

function pvCopy(text) {
  const fallback = () => {
    const area = Object.assign(document.createElement("textarea"), { value: text });
    document.body.append(area);
    area.select();
    document.execCommand("copy");
    area.remove();
  };
  try {
    (navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject()).catch(fallback);
  } catch { fallback(); }
}

$("copy-path").addEventListener("click", (e) => {
  if (!active) return;
  pvCopy(e.altKey && pvProject.root ? `${pvProject.root.replace(/\/$/, "")}/${active}` : active);
  const button = $("copy-path");
  button.classList.add("done");
  setTimeout(() => button.classList.remove("done"), 1200);
});

for (const button of $("pv-modes").children) {
  button.addEventListener("click", () => {
    const file = active && files.get(active);
    if (!file) return;
    file.preview = button.dataset.mode;
    pvShow(true);
    publish();
    if (file.preview !== "preview") editor.focus();
  });
}

// ── Showing the code, the preview, or both ─────────────────────────────
/** Called by showEditor: lays out the active file's code and preview, or (off) drops the preview. */
function pvShow(on) {
  const mode = on ? pvMode() : "code";
  $("editor").hidden = !on || mode === "preview";
  $("preview").hidden = !on || mode === "code";
  if (on) pvRenderPath();
  if (on && mode !== "code") pvRender();
  else pvDrop();
  fmtShow();
}

function pvDrop() {
  clearTimeout(pvTimer);
  if (pvFrame) pvFrame.remove();
  pvFrame = null;
  pvFrameKey = null;
  pvFrameReady = false;
  pvPending = null;
}

/** Called by createEditor once Monaco is up. */
function pvInit() {
  editor.onDidChangeModelContent(() => {
    if (pvMode() === "code") return;
    clearTimeout(pvTimer);
    // HTML reloads its frame (and runs its scripts again), so it waits for a longer pause.
    pvTimer = setTimeout(pvRender, pvKind(active) === "html" ? 700 : 180);
  });
  editor.onDidScrollChange((e) => {
    if (!e.scrollTopChanged || pvSyncing || pvMode() !== "split" || pvKind(active) !== "markdown" || !pvFrameReady) return;
    const doc = pvFrame.contentDocument;
    const page = doc && doc.scrollingElement;
    if (!page) return;
    const range = e.scrollHeight - editor.getLayoutInfo().height;
    page.scrollTop = range > 0 ? (e.scrollTop / range) * (page.scrollHeight - page.clientHeight) : 0;
  });
}

function pvRender() {
  clearTimeout(pvTimer);
  const file = active && files.get(active);
  const kind = pvKind(active);
  if (!file || !kind) return;
  const text = file.model.getValue();
  if (kind === "html") {
    pvMakeFrame(`html:${active}:${file.model.getAlternativeVersionId()}`, "allow-scripts allow-forms", pvWithBase(text, pvUrl(active)));
  } else {
    pvPending = pvMarkdown(text);
    pvMakeFrame(`markdown:${active}`, "allow-same-origin", pvMarkdownShell(pvUrl(active)));
    if (pvFrameReady) pvFlush();
  }
}

/** Replaces the frame unless it's already showing `key`. */
function pvMakeFrame(key, sandbox, srcdoc) {
  if (pvFrame && pvFrameKey === key) return;
  const frame = document.createElement("iframe");
  frame.setAttribute("sandbox", sandbox);
  frame.style.background = key.startsWith("html:") ? "#fff" : "transparent";
  frame.addEventListener("load", () => {
    if (frame !== pvFrame) return;
    pvFrameReady = true;
    pvFlush();
  });
  frame.srcdoc = srcdoc;
  if (pvFrame) pvFrame.replaceWith(frame); else $("preview").append(frame);
  pvFrame = frame;
  pvFrameKey = key;
  pvFrameReady = false;
}

/** Puts the rendered Markdown into the frame, in place, so it keeps its scroll position. */
function pvFlush() {
  if (pvPending === null || !pvFrame || !pvFrameKey.startsWith("markdown:")) return;
  const doc = pvFrame.contentDocument;
  if (!doc || !doc.body) return;
  doc.body.replaceChildren(...pvPending);
  pvPending = null;
}

/** An HTML file's text with a <base> so its relative links, images and stylesheets resolve in the project. */
function pvWithBase(html, base) {
  const tag = `<base href="${base.replace(/"/g, "%22")}">`;
  for (const pattern of [/<head(\s[^>]*)?>/i, /<html(\s[^>]*)?>/i, /<!doctype[^>]*>/i]) {
    const match = pattern.exec(html);
    if (match) return html.slice(0, match.index + match[0].length) + tag + html.slice(match.index + match[0].length);
  }
  return tag + html;
}

// ── Markdown ───────────────────────────────────────────────────────────
const pvMd = window.markdownit({
  html: true, // raw HTML in READMEs (centred logos, <details>…): the frame can't run scripts, and pvClean strips them anyway
  linkify: true,
  highlight(code, lang) {
    // Only fenced blocks that name their language: guessing (highlightAuto) is slow on long files.
    if (!lang || !hljs.getLanguage(lang)) return "";
    try {
      return `<pre><code class="hljs">${hljs.highlight(code, { language: lang, ignoreIllegals: true }).value}</code></pre>`;
    } catch {
      return "";
    }
  },
});

/** Rendered Markdown as nodes owned by an inert document: no scripts, frames or event handlers, headings get ids. */
function pvMarkdown(text) {
  const doc = new DOMParser().parseFromString(`<!doctype html><body>${pvMd.render(text)}</body>`, "text/html");
  pvClean(doc.body);
  const used = new Map();
  for (const h of doc.body.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
    let slug = h.textContent.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s/g, "-");
    const n = used.get(slug) || 0;
    used.set(slug, n + 1);
    if (n) slug += `-${n}`;
    if (!h.id) h.id = slug;
  }
  // "#section" would resolve against the <base> (the file's glance-file URL) and open the file again; the frame's own
  // address keeps it on this page.
  for (const a of doc.body.querySelectorAll('a[href^="#"]')) a.setAttribute("href", "about:srcdoc" + a.getAttribute("href"));
  for (const box of doc.body.querySelectorAll('input[type="checkbox"]')) box.disabled = true;
  return [...doc.body.childNodes];
}

function pvClean(root) {
  for (const el of root.querySelectorAll("script, iframe, frame, frameset, object, embed, base, meta, link, form, noscript")) el.remove();
  for (const el of root.querySelectorAll("*")) {
    for (const attr of [...el.attributes]) {
      const name = attr.name.toLowerCase();
      const value = attr.value.replace(/[\s\u0000-\u001f]/g, "").toLowerCase();
      if (name.startsWith("on") || name === "srcdoc" || name === "style" && /expression|url\(\s*["']?javascript/.test(value)
        || /^(href|src|xlink:href|action|formaction|poster|data)$/.test(name) && /^(javascript|vbscript|data:text\/html)/.test(value)) {
        el.removeAttribute(attr.name);
      }
    }
  }
}

function pvMarkdownShell(base) {
  const font = (file) => new URL(`../vendor/fonts/${file}`, location.href).href;
  return `<!doctype html><html><head><meta charset="utf-8"><base href="${base.replace(/"/g, "%22")}"><style>
@font-face { font-family: "DM Sans"; font-weight: 400 700; src: url(${font("dm-sans.woff2")}) format("woff2"); }
@font-face { font-family: "JetBrains Mono"; font-weight: 400 600; src: url(${font("jetbrains-mono.woff2")}) format("woff2"); }
:root { color-scheme: light dark; --ink: #1c1a17; --body: #4a453d; --mu: #6b655c; --line: rgba(28, 26, 23, .12); --code: rgba(28, 26, 23, .06);
  --link: #c4471f; --pre: #f3efe6; }
@media (prefers-color-scheme: dark) { :root { --ink: #f1ede4; --body: #c5bfb3; --mu: #9a948a; --line: rgba(255, 255, 255, .1);
  --code: rgba(255, 255, 255, .08); --link: #ff9b7a; --pre: #23211e; } }
html { background: transparent; }
body { max-width: 860px; margin: 0 auto; padding: 24px 32px 64px; font: 15px/1.65 "DM Sans", -apple-system, sans-serif; color: var(--body);
  -webkit-font-smoothing: antialiased; overflow-wrap: break-word; }
h1, h2, h3, h4, h5, h6 { color: var(--ink); line-height: 1.25; margin: 1.6em 0 .6em; font-weight: 650; }
h1 { font-size: 1.9em; padding-bottom: .3em; border-bottom: 1px solid var(--line); }
h2 { font-size: 1.45em; padding-bottom: .25em; border-bottom: 1px solid var(--line); }
h3 { font-size: 1.2em; } h4 { font-size: 1.05em; } h5, h6 { font-size: .95em; color: var(--mu); }
body > :first-child { margin-top: 0; }
p, ul, ol, blockquote, table, pre, details { margin: 0 0 1em; }
li + li { margin-top: .25em; }
li > input[type="checkbox"] { margin: 0 .4em 0 -1.2em; }
ul:has(> li > input[type="checkbox"]) { list-style: none; }
a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
strong { color: var(--ink); }
img { max-width: 100%; }
hr { border: 0; border-top: 1px solid var(--line); margin: 2em 0; }
blockquote { margin-left: 0; padding: 0 1em; color: var(--mu); border-left: 3px solid #e8643c; }
code { font: .87em "JetBrains Mono", ui-monospace, Menlo, monospace; background: var(--code); border-radius: 4px; padding: .15em .35em; }
pre { padding: 12px 14px; border-radius: 8px; background: var(--pre); overflow-x: auto; line-height: 1.5; }
pre code { background: none; padding: 0; font-size: 12.5px; color: var(--ink); }
table { border-collapse: collapse; display: block; overflow-x: auto; }
th, td { border: 1px solid var(--line); padding: 6px 12px; }
th { color: var(--ink); background: var(--code); }
details > summary { cursor: pointer; }
.hljs-keyword, .hljs-selector-tag, .hljs-literal, .hljs-tag { color: #c4471f; }
.hljs-title, .hljs-built_in, .hljs-attr, .hljs-attribute, .hljs-name { color: #1f7a7e; }
.hljs-string, .hljs-number, .hljs-regexp, .hljs-addition { color: #8a6a12; }
.hljs-comment, .hljs-quote, .hljs-meta { color: var(--mu); font-style: italic; }
.hljs-section, .hljs-type { color: #2b7a3d; } .hljs-deletion { color: #c0392b; }
@media (prefers-color-scheme: dark) {
  .hljs-keyword, .hljs-selector-tag, .hljs-literal, .hljs-tag { color: #ff9b7a; }
  .hljs-title, .hljs-built_in, .hljs-attr, .hljs-attribute, .hljs-name { color: #8fd9dc; }
  .hljs-string, .hljs-number, .hljs-regexp, .hljs-addition { color: #f0d28a; }
  .hljs-section, .hljs-type { color: #8fd9a0; } .hljs-deletion { color: #ff9b7a; }
}
</style></head><body></body></html>`;
}
