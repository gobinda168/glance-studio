"use strict";

// A Claude Code session's summary (spec 2026-10-11-humanize-summaries-design.md, "Settings and UI"): a layer in front
// of the reply or the conversation. Swift drives it with `glance.summaryAvailable(on)` (the header button: the
// terminal in front has a session) and `glance.summary(payload)`; the page answers with
// {type: "summary", action: "open" | "generate" | "close"}. The ☰ menu's Terminal sessions (chat.js) open it with
// a `glance:summary-pick` event, which becomes action "pick".

(() => {
  const $ = (id) => document.getElementById(id);
  const main = $("main"), view = $("summary"), body = $("sum-body"), button = $("summary-btn");
  let open = false;
  let drawn = ""; // the blocks on screen, as drawn from

  function show(on) {
    if (open === on) return;
    open = on;
    main.classList.toggle("in-summary", on);
    button.setAttribute("aria-pressed", String(on));
    document.dispatchEvent(new CustomEvent("glance:summary", { detail: on }));
    if (on) view.scrollTop = 0;
  }

  function close() {
    if (!open) return;
    show(false);
    post({ type: "summary", action: "close" });
  }

  const generate = () => post({ type: "summary", action: "generate" });
  button.addEventListener("click", () => {
    if (open) return close();
    show(true);
    post({ type: "summary", action: "open" });
  });
  $("sum-back").addEventListener("click", close);
  $("sum-refresh").addEventListener("click", generate);
  $("sum-stale").addEventListener("click", generate);
  $("sum-go").addEventListener("click", generate);
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && open && !event.defaultPrevented) { event.preventDefault(); close(); }
  });
  document.addEventListener("glance:summary-pick", (event) => {
    show(true);
    post({ type: "summary", action: "pick", id: event.detail });
  });
  document.addEventListener("glance:summary-exit", close);
  // Chat mode taking over (the composer focused) puts the summary away.
  document.addEventListener("glance:chat", (event) => { if (event.detail) show(false); });

  function drawBlocks(blocks) {
    const key = JSON.stringify(blocks || []);
    if (key === drawn) return;
    drawn = key;
    body.replaceChildren(...(blocks || []).map((block) => window.glance.block(block)));
    if (typeof linkFiles === "function") linkFiles(body);
  }

  /** {state: none | working | ready | failed | closed, title, meta?, stale, blocks?, message?, hint?, mode} */
  function paint(p) {
    const state = p.state, hasSummary = !!(p.blocks && p.blocks.length);
    $("sum-title").textContent = p.title || "This session";
    $("sum-meta").textContent = state === "working" ? (hasSummary ? `${p.meta} · updating` : "Summarizing…") : (p.meta || "");
    view.classList.toggle("working", state === "working");
    $("sum-progress").hidden = state !== "working";
    $("sum-stale").hidden = !(state === "ready" && p.stale);
    const refresh = $("sum-refresh");
    refresh.hidden = !hasSummary;
    refresh.disabled = state === "working";
    $("sum-error").hidden = state !== "failed" || !hasSummary;
    $("sum-error").textContent = state === "failed" ? `Couldn't update the summary: ${p.message || "Claude Code failed."}` : "";
    drawBlocks(hasSummary ? p.blocks : []);

    const empty = !hasSummary;
    $("sum-empty").hidden = !empty;
    if (!empty) return;
    const go = $("sum-go");
    if (state === "working") {
      $("sum-empty-title").textContent = "Summarizing this session";
      $("sum-empty-text").textContent = "Claude is reading it once with Haiku. It stays here when you switch terminals.";
      go.hidden = true;
    } else if (state === "failed") {
      $("sum-empty-title").textContent = "Couldn't summarize this session";
      $("sum-empty-text").textContent = p.message || "Claude Code failed.";
      go.hidden = false;
      go.textContent = "Try again";
    } else {
      $("sum-empty-title").textContent = "No summary yet";
      $("sum-empty-text").textContent = p.hint || "Summarizing reads this session once with Haiku. Nothing runs until you ask.";
      go.hidden = false;
      go.textContent = "Summarize";
    }
  }

  Object.assign(window.glance, {
    /** The terminal in front has a Claude session (or not): the header's Summary button. */
    summaryAvailable(on) {
      button.hidden = !on;
      if (!on && open) show(false);
    },

    summary(p) {
      if (p.state === "closed") return show(false);
      show(true);
      paint(p);
    },
  });
})();
