"use strict";

// The panel's chrome from Claude Design "Glance Panel v11": header, orb, big-orb stage, settings. The host (the Mac
// app's WKWebView or the VS Code extension's webview) drives it through `window.glance` and hears back through `post`.

(() => {
  const $ = (id) => document.getElementById(id);
  const body = document.body;
  const main = $("main");
  const orb = $("orb");
  const orbBody = $("orb-body");
  // Held, not looked up: a reply takes the empty note out of the page (app.js puts it back).
  const emptyTitle = $("empty-title"), emptyBody = $("empty-body");

  const DEFAULTS = { theme: "dark", speed: 1, size: 1, animate: true, follow: true };
  const SIZES = ["13px", "16px", "19px"];
  let prefs = { ...DEFAULTS };
  let auto = false;
  let voices = { options: [], selected: "" };
  let mode = "idle";
  let playing = false;
  let hasReply = false;
  let big = true;
  let inSettings = false;
  let inChat = false;
  let inSummary = false; // summary.js: a session's summary in front
  // "terminal": the terminal in front runs no Claude session, so the idle stage says so (glance.emptyKind).
  let emptyKind = "default";
  let chrome = "full";

  // ── Segmented controls with a sliding thumb ──────────────────
  const segs = new Map();
  function segment(el, onPick) {
    const thumb = document.createElement("div");
    thumb.className = "thumb";
    el.prepend(thumb);
    el.addEventListener("click", (event) => {
      const item = event.target.closest("span[data-v]");
      if (item && !item.classList.contains("disabled")) onPick(item.dataset.v);
    });
    segs.set(el, thumb);
  }
  function select(el, value, instant) {
    let chosen = null;
    for (const item of el.querySelectorAll("span[data-v]")) {
      const on = item.dataset.v === String(value);
      item.classList.toggle("on", on);
      if (on) chosen = item;
    }
    const thumb = segs.get(el);
    if (!thumb) return;
    thumb.style.opacity = chosen ? 1 : 0;
    if (!chosen) return;
    if (instant) thumb.style.transition = "none";
    thumb.style.width = `${chosen.offsetWidth}px`;
    thumb.style.transform = `translateX(${chosen.offsetLeft}px)`;
    if (instant) { thumb.getBoundingClientRect(); thumb.style.transition = ""; }
  }
  const relayout = () => {
    select($("modes"), mode, true);
    select($("voices"), voices.selected, true);
    select($("themes"), prefs.theme, true);
    select($("sizes"), prefs.size, true);
  };
  addEventListener("resize", relayout);

  // ── Swapping text with a soft blur-in ────────────────────────
  function swap(el, text) {
    if (el.textContent === text) return;
    el.textContent = text;
    el.classList.remove("in");
    void el.offsetWidth;
    el.classList.add("in");
  }

  // ── Layout: big orb, settings ────────────────────────────────
  function layout() {
    const showBig = big && !inSettings && !inChat && !inSummary;
    orb.classList.toggle("big", showBig);
    main.classList.toggle("big-orb", showBig);
    main.classList.toggle("in-settings", inSettings);
    main.classList.toggle("in-chat", inChat && !inSettings);
    $("title").textContent = inSettings ? "Settings" : inSummary ? "Summary" : inChat ? "Chat" : "Glance";
    const gearIcon = $("gear-icon"), glyph = inSettings || inChat || inSummary ? "←" : "⚙︎";
    if (gearIcon.textContent !== glyph) {
      gearIcon.textContent = glyph;
      gearIcon.classList.remove("turn");
      void gearIcon.offsetWidth;
      gearIcon.classList.add("turn");
    }
    $("gear").style.background = inSettings ? "var(--seg)" : "";
    renderStatus();
    requestAnimationFrame(relayout);
    measureSoon();
  }

  // ── The height the content needs (Glance Studio's floating card fits itself to it) ──
  // What shows below the header: the notice, the view in front (the reply, settings or the conversation) at its
  // natural height, padding included, and the composer. One message per frame at most, and only on a real change.
  let reported = -1, measuring = 0;
  function natural(el) {
    let bottom = 0;
    for (const child of el.children) if (child.offsetParent) bottom = Math.max(bottom, child.offsetTop + child.offsetHeight);
    return bottom + parseFloat(getComputedStyle(el).paddingBottom || 0);
  }
  function needed() {
    const notice = $("notice"), composer = $("composer");
    const view = inSettings ? natural($("settings")) : inSummary ? natural($("summary"))
      : inChat ? natural($("thread")) : $("reply").offsetHeight;
    return Math.ceil(view + (notice.hidden ? 0 : notice.offsetHeight) + (composer.hidden ? 0 : composer.offsetHeight)
      + (chrome === "float" ? 0 : document.querySelector(".bar").offsetHeight));
  }
  function measureSoon() {
    if (measuring) return;
    measuring = requestAnimationFrame(() => {
      measuring = 0;
      const height = needed();
      if (Math.abs(height - reported) < 1) return;
      reported = height;
      post({ type: "contentHeight", value: height });
    });
  }
  const sizes = new ResizeObserver(measureSoon);
  for (const id of ["reply", "thread-list", "toggles", "notice", "composer", "sum-body", "sum-empty"]) sizes.observe($(id));

  let status = { header: "WAITING FOR CLAUDE", title: "Idle", subtitle: "READY WHEN YOU ARE" };
  function renderStatus() {
    const noSession = emptyKind === "terminal" && mode === "idle" && !hasReply;
    swap($("status"), inSettings ? "PREFERENCES" : noSession ? "NO SESSION HERE" : status.header);
    swap($("orb-title"), noSession ? "No Claude session" : status.title);
    swap($("orb-sub"), noSession ? "START CLAUDE IN THIS TERMINAL" : status.subtitle);
    // The floating card has no stage: its empty note says what the stage would.
    emptyTitle.textContent = noSession ? "No Claude session" : "Waiting for Claude";
    emptyBody.textContent = noSession ? "Start Claude in this terminal. Its replies appear here, drawn."
      : "Ask Claude Code something in your terminal. The reply appears here, drawn. Press play or ⌥. to hear it.";
    orb.dataset.mode = mode;
    select($("modes"), mode);
    const play = $("play");
    play.classList.toggle("on", playing);
    play.classList.toggle("off", !hasReply);
  }

  // ── Prefs ────────────────────────────────────────────────────
  function applyPrefs() {
    document.documentElement.dataset.theme = prefs.theme;
    document.documentElement.style.setProperty("--fs", SIZES[prefs.size] || SIZES[1]);
    $("theme-icon").textContent = prefs.theme === "dark" ? "☀︎" : "☾";
    $("speed").value = prefs.speed;
    $("speed-label").textContent = prefs.speed.toFixed(2).replace(/0$/, "") + "×";
    select($("themes"), prefs.theme);
    select($("sizes"), prefs.size);
    for (const t of document.querySelectorAll(".toggle")) {
      const key = t.dataset.key;
      t.classList.toggle("on", key === "auto" ? auto : !!prefs[key]);
    }
    const themeChanged = window.glancePrefs.theme !== prefs.theme;
    Object.assign(window.glancePrefs, { theme: prefs.theme, animate: prefs.animate, follow: prefs.follow });
    if (themeChanged) window.glance.retheme(prefs.theme);
  }
  function setPrefs(change) {
    prefs = { ...prefs, ...change };
    applyPrefs();
    post({ type: "prefs", prefs });
  }
  function renderVoices() {
    const el = $("voices");
    el.querySelectorAll("span[data-v]").forEach((s) => s.remove());
    for (const v of voices.options) {
      const span = document.createElement("span");
      span.dataset.v = v.id;
      span.textContent = v.name;
      if (v.title) span.title = v.title;
      el.append(span);
    }
    select(el, voices.selected, true);
  }

  // ── Orb level: the real voice level while speaking ───────────
  // Hosts that can't measure the voice (OS speech in VS Code) send no level: the orb then pulses the way the design
  // animates it.
  let level = 0, levelAt = 0, amp = 0, last = 0, raf = 0;
  function tick(now) {
    const dt = Math.min(Math.max((now - (last || now)) / 1000, 0), .1);
    last = now;
    const t = now / 300;
    const synthetic = .35 + .65 * Math.abs(Math.sin(t * 1.3)) * (.6 + .4 * Math.abs(Math.sin(t * .55)));
    const measured = now - levelAt < 400;
    const target = mode === "speaking" ? (measured ? Math.min(1, level * 7) : synthetic * .8) : 0;
    amp += (target - amp) * (1 - Math.exp(-dt * (target > amp ? 22 : 7)));
    orbBody.style.transform = `scale(${1 + .14 * amp})`;
    raf = mode === "speaking" || amp > .002 ? requestAnimationFrame(tick) : 0;
    if (!raf) { orbBody.style.transform = ""; last = 0; }
  }
  const wake = () => { if (!raf) raf = requestAnimationFrame(tick); };

  // ── Wiring ───────────────────────────────────────────────────
  segment($("modes"), (v) => {
    if (v === "speaking" && !playing && hasReply) post({ type: "action", name: "play" });
    else if (v === "idle" && playing) post({ type: "action", name: "pause" });
  });
  segment($("voices"), (v) => { voices.selected = v; select($("voices"), v); post({ type: "voice", id: v }); });
  segment($("themes"), (v) => setPrefs({ theme: v }));
  segment($("sizes"), (v) => setPrefs({ size: Number(v) }));
  $("speed").addEventListener("input", (e) => setPrefs({ speed: parseFloat(e.target.value) }));
  for (const t of document.querySelectorAll(".toggle")) {
    t.addEventListener("click", () => {
      const key = t.dataset.key;
      if (key === "auto") {
        auto = !auto;
        applyPrefs();
        post({ type: "auto", on: auto });
      } else {
        setPrefs({ [key]: !prefs[key] });
      }
    });
  }
  $("reset").addEventListener("click", () => {
    auto = false;
    setPrefs({ ...DEFAULTS });
    post({ type: "auto", on: false });
  });
  $("more").querySelector(".link").addEventListener("click", () => post({ type: "action", name: "settingsWindow" }));
  $("play").addEventListener("click", () => hasReply && post({ type: "action", name: "playPause" }));
  $("theme").addEventListener("click", () => setPrefs({ theme: prefs.theme === "dark" ? "light" : "dark" }));
  $("gear").addEventListener("click", () => {
    if (inSummary && !inSettings) { document.dispatchEvent(new CustomEvent("glance:summary-exit")); return; }
    if (inChat && !inSettings) { document.dispatchEvent(new CustomEvent("glance:chat-exit")); return; }
    inSettings = !inSettings;
    layout();
  });
  $("close").addEventListener("click", () => post({ type: "action", name: "close" }));
  $("pin").addEventListener("click", () => post({ type: "action", name: "layout" }));
  orb.addEventListener("click", () => {
    if (inSettings) { inSettings = false; big = true; } else big = !big;
    layout();
  });
  document.addEventListener("glance:reply", () => { hasReply = true; big = false; layout(); });
  document.addEventListener("glance:summary", (event) => {
    inSummary = !!event.detail;
    if (inSummary) inSettings = false;
    layout();
  });
  document.addEventListener("glance:chat", (event) => {
    inChat = !!event.detail;
    if (inChat) { big = false; inSettings = false; }
    layout();
  });

  Object.assign(window.glance, {
    /** "terminal" (the terminal in front runs no Claude session) or "default": what the idle stage says. */
    emptyKind(kind) {
      emptyKind = kind === "terminal" ? "terminal" : "default";
      main.classList.toggle("no-session", emptyKind === "terminal");
      renderStatus();
    },

    /** {mode, header, title, subtitle, playing, hasReply, notice} */
    state(s) {
      const wasThinking = mode === "thinking";
      mode = s.mode;
      playing = !!s.playing;
      hasReply = !!s.hasReply;
      status = { header: s.header, title: s.title, subtitle: s.subtitle };
      if (mode === "thinking" && !wasThinking) big = true;
      const notice = $("notice");
      notice.hidden = !s.notice;
      notice.textContent = s.notice || "";
      notice.title = s.notice || "";
      if (mode === "speaking") wake();
      layout();
    },
    /** {theme, speed, size, animate, follow, auto, voices: {options: [{id, name, title?}], selected}} */
    prefs(p) {
      prefs = { ...DEFAULTS, ...prefs, ...p };
      delete prefs.auto;
      delete prefs.voices;
      if (typeof p.auto === "boolean") auto = p.auto;
      if (p.voices) { voices = p.voices; renderVoices(); }
      applyPrefs();
    },
    level(x) { level = x; levelAt = performance.now(); wake(); },
    /** Glance Studio's layout: "auto", "pinned" or "floating". Shows the pin, which cycles it. */
    layout(m) {
      const pin = $("pin");
      pin.hidden = false;
      pin.dataset.mode = m;
      pin.title = {
        auto: "Layout: Auto — sidebar in wide windows, orb in narrow ones. Click to pin the sidebar",
        pinned: "Layout: Sidebar — click to float as an orb",
        floating: "Layout: Orb — click to switch automatically",
      }[m] || "";
    },
    /** Glance Studio's chrome: "float" (the floating card: no header row, its buttons a hover strip) or "full". */
    chrome(m) {
      chrome = m === "float" ? "float" : "full";
      $("panel").classList.toggle("float", chrome === "float");
      measureSoon();
    },
    /** The panel came on screen. */
    appear() {
      const panel = $("panel");
      panel.classList.remove("appear");
      void panel.offsetWidth;
      panel.classList.add("appear");
    },
  });

  // VS Code webviews receive calls as messages: {method, args}.
  addEventListener("message", (event) => {
    const { method, args } = event.data || {};
    if (typeof method === "string" && typeof window.glance[method] === "function") window.glance[method](...(args || []));
  });

  if (document.documentElement.dataset.host === "vscode") {
    $("more").innerHTML = 'Voice IDs and the system voice are in <span class="link">VS Code Settings…</span>';
    $("more").querySelector(".link").addEventListener("click", () => post({ type: "action", name: "settingsWindow" }));
    document.querySelector(".foot .kbd").textContent = navigator.platform.startsWith("Mac") ? "⌥." : "Alt+.";
  }

  applyPrefs();
  layout();
  post({ type: "ready" });
})();
