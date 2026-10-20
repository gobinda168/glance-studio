"use strict";

// Renders a Claude reply block by block and animates its diagrams. Driven from Swift through `window.glance`;
// panel.js adds the chrome (header, orb, settings) to the same object.

const root = document.getElementById("reply");
// "Waiting for Claude": put back when a render has nothing to show, so the floating card is never an empty box.
const emptyNote = root.querySelector(".empty");
const scroller = document.getElementById("chat");
const md = window.markdownit({
  html: false,
  linkify: true,
  typographer: true,
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

/** Panel settings that change how replies render; panel.js keeps them current. */
window.glancePrefs = { theme: "dark", animate: true, follow: true };

const MERMAID_COLORS = {
  dark: {
    ink: "#f1ede4", body: "#c5bfb3", mu: "#9a948a", node: "#24221f", border: "#3a3732", line: "#8a847a",
    life: "#ffffff2e", label: "#1c1b19", note: "#2c1a12", noteText: "#f3d4c4", hot: "#3a2218", teal: "#1d3637",
  },
  light: {
    ink: "#1c1a17", body: "#4a453d", mu: "#7a746a", node: "#f6f2e8", border: "#d6cfbf", line: "#8a847a",
    life: "#1c1a1730", label: "#ffffff", note: "#fbe9df", noteText: "#6b2c14", hot: "#fbe9df", teal: "#dcefef",
  },
};

function configureMermaid(theme) {
  const c = MERMAID_COLORS[theme] || MERMAID_COLORS.dark;
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: "base",
    fontFamily: '"JetBrains Mono", ui-monospace, monospace',
    themeVariables: {
      darkMode: theme === "dark",
      background: "transparent",
      fontSize: "12px",
      primaryColor: c.node, primaryTextColor: c.ink, primaryBorderColor: c.border,
      secondaryColor: c.teal, tertiaryColor: c.node,
      mainBkg: c.node, nodeBorder: c.border, lineColor: c.line, textColor: c.ink, titleColor: c.ink,
      clusterBkg: "transparent", clusterBorder: c.border, edgeLabelBackground: c.label,
      actorBkg: c.node, actorBorder: c.border, actorTextColor: c.ink, actorLineColor: c.life,
      signalColor: c.line, signalTextColor: c.body,
      labelBoxBkgColor: c.node, labelBoxBorderColor: c.border, labelTextColor: c.ink, loopTextColor: c.mu,
      noteBkgColor: c.note, noteTextColor: c.noteText, noteBorderColor: "#e8643c",
      activationBkgColor: c.hot, activationBorderColor: "#e8643c", sequenceNumberColor: "#ffffff",
      pie1: "#e8643c", pie2: "#2a8f94", pie3: "#d9a441", pie4: "#8fd9dc", pie5: "#ff9b7a", pie6: "#8fd9a0",
      pieStrokeColor: c.border, pieTitleTextColor: c.ink, pieSectionTextColor: "#ffffff", pieLegendTextColor: c.body,
    },
    flowchart: { curve: "basis", padding: 12 },
    sequence: { mirrorActors: false, actorFontWeight: 600 },
  });
}
configureMermaid("dark");

// The host: the Mac app's WKWebView, or a VS Code webview.
const vscode = typeof acquireVsCodeApi === "function" ? acquireVsCodeApi() : null;
const post = (message) => vscode ? vscode.postMessage(message) : window.webkit?.messageHandlers?.glance?.postMessage(message);
let generation = 0;
let userScrolledAt = 0;
let current = []; // the blocks on screen
const units = new Map(); // block index → diagram units, in reveal order

scroller.addEventListener("wheel", () => { userScrolledAt = Date.now(); }, { passive: true });

window.glance = {
  /** blocks: [{kind, markdown, lang?}] as produced by GlanceCore.Blocks; asked: the question they answer (the orb
   *  assistant's), shown muted above them. */
  async render(blocks, asked) {
    const mine = ++generation;
    current = blocks;
    units.clear();
    root.innerHTML = "";
    if (!blocks.length && !asked) {
      root.append(emptyNote);
      return;
    }
    if (asked) {
      // A first paragraph block, so it (not the answer) clears the floating card's hover strip; no data-i, so
      // narration and reveals never touch it, and the answer's first paragraph is still the lead.
      const line = document.createElement("section");
      line.className = "block paragraph asked";
      line.textContent = `You: ${asked}`;
      Object.assign(line.style, { color: "var(--mu)", fontSize: "13px", lineHeight: "1.45" });
      line.addEventListener("animationend", () => line.classList.add("entered"), { once: true });
      root.append(line);
    }
    scroller.scrollTop = 0;
    document.dispatchEvent(new CustomEvent("glance:reply"));
    const lead = blocks.findIndex((b) => b.kind === "paragraph");
    for (const [i, block] of blocks.entries()) {
      const el = document.createElement("section");
      el.className = `block ${block.kind}`;
      el.dataset.i = i;
      el.style.animationDelay = `${Math.min(i * 70, 700)}ms`;
      el.addEventListener("animationend", () => el.classList.add("entered"), { once: true });
      root.append(el);
      if (block.kind === "mermaid") {
        await renderDiagram(el, block.markdown, `d${mine}_${i}`, false);
        if (mine !== generation) return;
      } else if (block.kind === "code") {
        renderCode(el, block);
      } else if (block.kind === "table") {
        el.innerHTML = `<div class="card">${md.render(block.markdown)}</div>`;
      } else if (block.kind === "quote") {
        renderNote(el, block.markdown);
      } else {
        el.classList.add(i === lead && i <= 1 ? "lead" : "prose");
        if (block.kind === "heading") el.classList.replace("prose", "heading");
        el.innerHTML = md.render(block.markdown);
      }
    }
    linkFiles(root);
    post({ type: "rendered", generation: mine });
  },

  narrating(on) {
    document.body.classList.toggle("following", on && window.glancePrefs.follow);
    if (!on) root.querySelectorAll(".ahead").forEach((el) => el.classList.remove("ahead"));
  },


  speaking(i) {
    for (const el of root.querySelectorAll(".block")) el.classList.toggle("ahead", Number(el.dataset.i) > i);
    const el = root.querySelector(`.block[data-i="${i}"]`);
    if (el && Date.now() - userScrolledAt > 4000) {
      const box = el.getBoundingClientRect(), view = scroller.getBoundingClientRect();
      if (box.top < view.top || box.bottom > view.bottom) el.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  },

  /** Draws diagram block `i` piece by piece over `ms` milliseconds. */
  reveal(i, ms) {
    const list = units.get(i);
    if (!list || list.revealed) return;
    list.revealed = true;
    if (!window.glancePrefs.animate) { list.forEach((unit) => unit.el.classList.remove("hidden")); return; }
    const host = root.querySelector(`.block[data-i="${i}"]`);
    if (host && Date.now() - userScrolledAt > 4000) {
      const box = host.getBoundingClientRect(), view = scroller.getBoundingClientRect();
      if (box.top < view.top || box.bottom > view.bottom) host.scrollIntoView({ behavior: "smooth", block: "nearest" });
    }
    play(list, ms);
  },

  revealAll(ms) {
    for (const i of units.keys()) this.reveal(i, ms);
  },

  /** Diagram colours follow the theme, so diagrams are drawn again (already-revealed ones stay revealed). */
  async retheme(theme) {
    configureMermaid(theme);
    const mine = generation;
    for (const [i, block] of current.entries()) {
      if (block.kind !== "mermaid") continue;
      const el = root.querySelector(`.block[data-i="${i}"]`);
      if (!el) continue;
      const revealed = units.get(i)?.revealed ?? true;
      el.innerHTML = "";
      await renderDiagram(el, block.markdown, `r${mine}_${i}_${Date.now()}`, revealed);
      if (mine !== generation) return;
    }
  },
};

function play(list, ms) {
  const step = ms / Math.max(list.length, 1);
  const duration = Math.min(700, Math.max(260, step * 1.6));
  list.forEach((unit, n) => setTimeout(() => show(unit, duration), n * step));
}

function header(card, tag, dotClass) {
  const head = document.createElement("div");
  head.className = "card-head";
  if (dotClass !== null) {
    const dot = document.createElement("span");
    dot.className = `dot ${dotClass || ""}`;
    head.append(dot);
  }
  const label = document.createElement("span");
  label.className = "tag";
  label.textContent = tag;
  head.append(label);
  card.append(head);
  return head;
}

function button(head, text, onClick) {
  const b = document.createElement("button");
  b.className = "chip-btn";
  b.textContent = text;
  b.addEventListener("click", () => onClick(b));
  head.append(b);
  return b;
}

function copyButton(head, text) {
  return button(head, "COPY", (b) => {
    post({ type: "copy", text });
    b.textContent = "COPIED";
    b.classList.add("done");
    setTimeout(() => { b.textContent = "COPY"; b.classList.remove("done"); }, 1400);
  });
}

function renderCode(el, block) {
  const card = document.createElement("div");
  card.className = "code-card";
  const head = header(card, (block.lang || "code").toUpperCase(), null);
  copyButton(head, block.markdown);
  card.insertAdjacentHTML("beforeend", md.render("```" + (block.lang || "") + "\n" + block.markdown + "\n```"));
  el.append(card);
}

/** Blockquotes become the design's NOTE callout; a leading "Note:" label is folded into the tag. */
function renderNote(el, markdown) {
  const text = markdown.replace(/^>\s?/gm, "");
  const match = text.match(/^\s*(?:\*\*|__)?(note|tip|warning|important|caution)(?:\*\*|__)?\s*:?\s*(?:\*\*|__)?\s*/i);
  const tag = match ? match[1].toUpperCase() : "NOTE";
  const body = match ? text.slice(match[0].length) : text;
  el.innerHTML = `<div class="note"><span class="note-tag">${tag}</span><div class="note-body">${md.render(body)}</div></div>`;
}

const DIAGRAM_NAMES = {
  sequence: "SEQUENCE", flowchart: "FLOW", "flowchart-v2": "FLOW", stateDiagram: "STATE", class: "CLASS",
  er: "ENTITIES", gantt: "TIMELINE", pie: "PIE", gitGraph: "GIT", mindmap: "MIND MAP", journey: "JOURNEY",
};

function diagramTitle(code) {
  const m = code.match(/^\s*(?:title|accTitle\s*:)\s*:?\s*(.+)$/m);
  return m ? m[1].trim().toUpperCase() : "";
}

async function renderDiagram(el, code, id, revealed) {
  const i = Number(el.dataset.i);
  const card = document.createElement("div");
  card.className = "card diagram";
  const head = header(card, "DIAGRAM", "");
  const caption = document.createElement("span");
  caption.className = "caption";
  head.append(caption);
  const grid = document.createElement("div");
  grid.className = "stage-grid";
  card.append(grid);
  el.append(card);
  try {
    grid.innerHTML = (await mermaid.render(id, code)).svg;
    let svgEl = grid.querySelector("svg");
    // The panel is narrow: a left-to-right flowchart that would shrink past reading size is drawn top-down instead,
    // and anything still too wide keeps a readable size and scrolls sideways.
    const room = grid.clientWidth - 16;
    const natural = () => svgEl?.viewBox?.baseVal?.width || 0;
    const sideways = /^\s*(flowchart|graph)\s+(LR|RL)\b/i;
    if (natural() > room * 1.5 && sideways.test(code)) {
      grid.innerHTML = (await mermaid.render(id + "v", code.replace(sideways, "$1 TD"))).svg;
      svgEl = grid.querySelector("svg");
    }
    if (natural() * .8 > room) {
      svgEl.classList.add("wide");
      svgEl.setAttribute("width", Math.round(natural() * .8));
      svgEl.removeAttribute("height");
    }
    const role = svgEl?.getAttribute("aria-roledescription") || "";
    const kind = DIAGRAM_NAMES[role] || "DIAGRAM";
    const title = diagramTitle(code);
    head.querySelector(".tag").textContent = title ? `${kind} · ${title}` : kind;
    if (!role.includes("sequence")) head.querySelector(".dot").classList.add("teal");
    const list = prepare(svgEl);
    if (!Number.isNaN(i)) units.set(i, list); // chat diagrams have no reply index and are drawn already
    if (revealed) {
      list.revealed = true;
      list.forEach((unit) => unit.el.classList.remove("hidden"));
    }
    button(head, "↻ REPLAY", () => {
      list.revealed = true;
      list.forEach((unit) => unit.el.classList.add("hidden"));
      requestAnimationFrame(() => play(list, 2400));
    });
  } catch (error) {
    for (const stray of [id, "d" + id, id + "v", "d" + id + "v"]) document.getElementById(stray)?.remove();
    grid.innerHTML = `<div class="fail">Couldn't draw this diagram — showing its source.</div>` + md.render("```\n" + code + "\n```");
  }
}

// Diagram units: the visible pieces of a mermaid SVG (nodes, edges, labels, actors, messages, notes),
// outermost match only, ordered in reading order so the picture builds the way you'd explain it.
const UNIT_SELECTOR = [
  "g.cluster", "g.node", "path.flowchart-link", ".edgePaths > path", "g.edgeLabel",
  "rect.actor", "text.actor", "g.actor", ".actor-line", "[class*=messageLine]", "text.messageText",
  "rect.note", "text.noteText", "[class^=activation]", ".loopLine", ".loopText", ".labelBox", ".labelText",
  "g.stateGroup", "path.transition", "g.classGroup", "path.relation", ".relationshipLine", "g.entity",
  "g.commit-bullets > *", "g.commit-labels > *", "g.branch", ".pieCircle", ".slice", ".legend",
].join(",");

function prepare(svg) {
  if (!svg) return [];
  const found = [...svg.querySelectorAll(UNIT_SELECTOR)];
  let list = found.filter((el) => !found.some((other) => other !== el && other.contains(el)));
  if (list.length < 2) list = [svg];

  const sequence = (svg.getAttribute("aria-roledescription") || "").includes("sequence");
  const frame = svg.getBoundingClientRect();
  const horizontal = !sequence && frame.width > frame.height * 1.2;
  const key = (el) => {
    const b = el.getBoundingClientRect();
    const x = b.left + b.width / 2, y = b.top + b.height / 2;
    return horizontal ? [Math.round(x / 12), y] : [Math.round(y / 12), x];
  };
  const keyed = list.map((el) => ({ el, k: key(el) }));
  keyed.sort((a, b) => a.k[0] - b.k[0] || a.k[1] - b.k[1]);

  return keyed.map(({ el }) => {
    el.classList.add("unit", "hidden");
    const drawable = el instanceof SVGGeometryElement && (el.tagName === "path" || el.tagName === "line");
    return { el, drawable };
  });
}

/** Lines draw themselves in coral, then settle to their own colour; everything else fades in with a coral glow. */
function show({ el, drawable }, duration) {
  el.style.transitionDuration = `${duration}ms`;
  if (drawable) {
    let length = 0;
    try { length = el.getTotalLength(); } catch {}
    if (length > 0) {
      const saved = {
        dasharray: el.style.strokeDasharray,
        offset: el.style.strokeDashoffset,
        stroke: el.style.stroke,
        marker: el.getAttribute("marker-end"),
      };
      if (saved.marker) el.removeAttribute("marker-end");
      el.style.transition = "none";
      el.style.strokeDasharray = `${length} ${length}`;
      el.style.strokeDashoffset = `${length}`;
      el.style.stroke = "#e8643c";
      el.classList.remove("hidden");
      el.getBoundingClientRect(); // commit the start state
      el.style.transition = `stroke-dashoffset ${duration}ms cubic-bezier(.4,.1,.2,1), stroke .5s ease ${duration}ms`;
      el.style.strokeDashoffset = "0";
      setTimeout(() => {
        el.style.strokeDasharray = saved.dasharray;
        el.style.strokeDashoffset = saved.offset;
        el.style.stroke = saved.stroke;
        if (saved.marker) el.setAttribute("marker-end", saved.marker);
      }, duration + 30);
      setTimeout(() => { el.style.transition = ""; }, duration + 600);
      return;
    }
  }
  el.classList.remove("hidden");
  el.classList.add("lit");
  setTimeout(() => el.classList.remove("lit"), duration + 250);
}

document.addEventListener("click", (event) => {
  const link = event.target.closest("a[href]");
  if (!link) return;
  event.preventDefault();
  post({ type: "open", url: link.href });
});

// ── File mentions ──────────────────────────────────────────────────────
// `src/App.swift:12` in a reply is a file the host may be able to open. Only code spans that look like paths are marked;
// they are styled and clickable only when the host says it can open files (Glance Studio does, the overlay and the VS
// Code extension don't).
const FILE_LINK = /^(?:\.{0,2}\/|~\/)?[\w.@+-]+(?:\/[\w.@+-]+)*\.[A-Za-z][A-Za-z0-9]{0,7}(?::\d+(?::\d+)?)?$/;
const FILE_EXTENSIONS = new Set(["swift", "ts", "tsx", "js", "jsx", "mjs", "json", "md", "py", "go", "rs", "html", "css", "scss", "yml", "yaml", "toml", "sh", "zsh", "txt", "c", "h", "cpp", "m", "java", "kt", "rb", "php", "xml", "sql", "plist", "lock", "env"]);
function linkFiles(root) {
  for (const code of root.querySelectorAll("code")) {
    if (code.closest("pre") || code.dataset.path) continue;
    const text = code.textContent.trim();
    if (!FILE_LINK.test(text)) continue;
    const extension = text.replace(/:\d+(?::\d+)?$/, "").split(".").pop().toLowerCase();
    if (!text.includes("/") && !FILE_EXTENSIONS.has(extension)) continue;
    code.classList.add("filelink");
    code.dataset.path = text;
  }
}
let fileLinksOn = false;
window.glance.fileLinks = (on) => {
  fileLinksOn = !!on;
  document.body.classList.toggle("filelinks", fileLinksOn);
};
document.addEventListener("click", (event) => {
  const link = fileLinksOn && event.target.closest && event.target.closest(".filelink");
  if (link) post({ type: "openFile", path: link.dataset.path });
});
