"use strict";

// The editor chat (Razor Code tabs in Glance Studio): a composer at the bottom of the pane, and in chat mode the
// conversation, read from the Claude Code session's transcript, in place of the latest reply. Swift drives it through
// `glance.chatComposer` and `glance.chatThread`; the page answers with chatOpen, chatSend, chatStop, chatNew
// and chatSwitch (the ☰ menu). The ☰ menu's second page lists the project's terminal sessions
// (`glance.summarySessions`, asked for with {type: "summary", action: "sessions"}); one opens its summary (summary.js).

(() => {
  const $ = (id) => document.getElementById(id);
  const composer = $("composer"), box = $("composer-box"), prompt = $("prompt");
  const thread = $("thread"), list = $("thread-list");
  let state = null; // {context, route, routeLabel, working, notice, sessions: [{id, title, updated}], active}
  let threadWorking = false;
  let sendContext = true; // the context chip wasn't dismissed for the next message
  let inChat = false;
  let diagrams = 0;

  const working = () => threadWorking || !!state?.working;

  function enterChat() {
    if (inChat) return;
    inChat = true;
    document.dispatchEvent(new CustomEvent("glance:chat", { detail: true }));
    post({ type: "chatOpen" });
    requestAnimationFrame(() => scrollDown(false));
  }

  function exitChat() {
    if (!inChat) return;
    inChat = false;
    prompt.blur();
    document.dispatchEvent(new CustomEvent("glance:chat", { detail: false }));
  }
  document.addEventListener("glance:chat-exit", exitChat);

  prompt.addEventListener("focus", () => { enterChat(); paint(); });
  prompt.addEventListener("blur", paint);
  prompt.addEventListener("input", grow);
  prompt.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) { event.preventDefault(); send(); }
    else if (event.key === "Escape") { event.preventDefault(); exitChat(); }
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && inChat && document.activeElement !== prompt) exitChat();
  });
  composer.addEventListener("submit", (event) => {
    event.preventDefault();
    if (working()) post({ type: "chatStop" });
    else send();
  });
  $("ctx-x").addEventListener("click", () => { sendContext = false; paint(); prompt.focus(); });

  // ── The ☰ menu: chats, and the project's terminal sessions ──
  const picker = $("picker"), menu = $("menu"), menuList = $("menu-list");
  let drawnSessions = "";

  function menuPage(terminals) {
    $("menu-main").hidden = terminals;
    $("menu-terms").hidden = !terminals;
    menu.querySelector(".menu-page:not([hidden]) .menu-item")?.focus();
  }

  function toggleMenu(open) {
    const next = open ?? menu.hidden;
    menu.hidden = !next;
    picker.setAttribute("aria-expanded", String(next));
    if (next) menuPage(false);
  }

  function ago(seconds) {
    const s = Math.max(0, Date.now() / 1000 - seconds);
    if (s < 45) return "now";
    if (s < 3600) return `${Math.round(s / 60)}m`;
    if (s < 86400) return `${Math.round(s / 3600)}h`;
    return `${Math.round(s / 86400)}d`;
  }

  function item(text, current, onPick, when) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "menu-item";
    b.setAttribute("role", "menuitem");
    if (current) b.setAttribute("aria-current", "true");
    const t = document.createElement("span");
    t.className = "t";
    t.textContent = text;
    b.append(t);
    if (when) {
      const w = document.createElement("span");
      w.className = "when";
      w.textContent = when;
      b.append(w);
    }
    b.addEventListener("click", onPick);
    return b;
  }

  // Chats switch only while no turn runs; terminal sessions open any time.
  function paintSessions() {
    const headless = state.route === "headless";
    const list = headless ? state.sessions || [] : [];
    const active = state.active || null;
    $("sessions").hidden = false;
    const busy = working();
    $("chat-new").disabled = busy || !headless;
    $("chat-new").title = busy ? "Stop the current turn to start a new chat" : "";
    $("chat-new").setAttribute("aria-current", String(headless && !active));
    paintRecents(list, active, busy);
    const key = JSON.stringify([list, active, busy]);
    if (key === drawnSessions) return;
    drawnSessions = key;
    menuList.replaceChildren(...list.map((entry) => {
      const b = item(entry.title || "New chat", entry.id === active, () => pick(entry.id), ago(entry.updated));
      b.disabled = busy;
      return b;
    }));
  }

  // The empty conversation lists the project's latest chats above the hint.
  let drawnRecents = "";
  function paintRecents(list, active, busy) {
    const recent = list.filter((entry) => entry.id !== active).slice(0, 5);
    const key = JSON.stringify([recent, busy]);
    if (key === drawnRecents) return;
    drawnRecents = key;
    $("recents").hidden = recent.length === 0;
    $("recents-list").replaceChildren(...recent.map((entry) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "recent";
      b.disabled = busy;
      b.innerHTML = '<span class="t"></span><span class="when"></span>';
      b.querySelector(".t").textContent = entry.title || "New chat";
      b.querySelector(".when").textContent = ago(entry.updated);
      b.addEventListener("click", () => pick(entry.id));
      return b;
    }));
  }

  $("menu-terminals").addEventListener("click", () => {
    $("menu-terms-list").replaceChildren();
    $("menu-terms-none").hidden = true;
    menuPage(true);
    post({ type: "summary", action: "sessions" });
  });
  $("menu-terms-back").addEventListener("click", () => menuPage(false));

  function pick(id) {
    toggleMenu(false);
    if (id !== state?.active) post({ type: "chatSwitch", id });
    prompt.focus();
  }

  picker.addEventListener("click", () => toggleMenu());
  $("chat-new").addEventListener("click", () => {
    toggleMenu(false);
    if (state?.active) post({ type: "chatNew" });
    prompt.focus();
  });
  document.addEventListener("click", (event) => {
    if (!menu.hidden && !$("sessions").contains(event.target) && event.target.isConnected) toggleMenu(false);
  });
  $("sessions").addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !menu.hidden) {
      event.preventDefault();
      event.stopPropagation();
      toggleMenu(false);
      picker.focus();
    } else if ((event.key === "ArrowDown" || event.key === "ArrowUp") && !menu.hidden) {
      event.preventDefault();
      const items = [...menu.querySelectorAll(".menu-page:not([hidden]) .menu-item:not(:disabled)")];
      const at = items.indexOf(document.activeElement);
      const next = event.key === "ArrowDown" ? Math.min(items.length - 1, at + 1) : Math.max(0, at - 1);
      items[next]?.focus();
    }
  });

  function send() {
    const text = prompt.value.trim();
    if (!text || !state || working()) return;
    post({ type: "chatSend", text, context: sendContext && !!state.context });
    prompt.value = "";
    sendContext = true;
    grow();
    enterChat();
    paint();
  }

  function grow() {
    prompt.style.height = "auto";
    prompt.style.height = `${Math.min(prompt.scrollHeight, 160)}px`;
  }

  function scrollDown(smooth) {
    thread.scrollTo({ top: thread.scrollHeight, behavior: smooth ? "smooth" : "auto" });
  }

  function paint() {
    if (!state) return;
    $("ctx").hidden = !state.context || !sendContext;
    $("ctx-text").textContent = state.context || "";
    $("route").textContent = state.routeLabel;
    paintSessions();
    $("composer-notice").hidden = !state.notice;
    $("composer-notice").textContent = state.notice || "";
    const send = $("send");
    send.classList.toggle("stop", working());
    send.title = working() ? "Stop" : "Send  ↩";
    box.classList.toggle("lit", working() || document.activeElement === prompt);
    prompt.placeholder = state.route === "terminal" ? "Message Claude Code in your terminal…" : "Ask Claude Code…";
  }

  // ── The conversation ─────────────────────────────────────────
  function blockElement(block) {
    const el = document.createElement("section");
    el.className = `block entered ${block.kind}`;
    if (block.kind === "mermaid") renderDiagram(el, block.markdown, `chat${++diagrams}`, true);
    else if (block.kind === "code") renderCode(el, block);
    else if (block.kind === "table") el.innerHTML = `<div class="card">${md.render(block.markdown)}</div>`;
    else if (block.kind === "quote") renderNote(el, block.markdown);
    else {
      el.classList.add(block.kind === "heading" ? "heading" : "prose");
      el.innerHTML = md.render(block.markdown);
    }
    return el;
  }

  function row(item) {
    const el = document.createElement("div");
    el.className = `msg ${item.kind}`;
    if (item.kind === "user") {
      if (item.context) {
        const chip = document.createElement("div");
        chip.className = "msg-ctx";
        chip.textContent = item.context;
        el.append(chip);
      }
      const text = document.createElement("div");
      text.className = "msg-text";
      text.textContent = item.text;
      el.append(text);
    } else if (item.kind === "assistant") {
      for (const block of item.blocks) el.append(blockElement(block));
      linkFiles(el);
    } else {
      el.innerHTML = '<span class="tool-dot"></span><span class="tool-name"></span><span class="tool-detail"></span>';
      el.querySelector(".tool-name").textContent = item.kind === "denied" ? `Blocked · ${item.name}` : item.name;
      el.querySelector(".tool-detail").textContent = item.detail;
      if (item.kind === "denied") el.title = "Auto mode refused this. Run it in the terminal if you want it done.";
    }
    return el;
  }

  // ── Turns: each prompt with Claude's replies and tool calls under it ──
  const shownTurns = []; // JSON of what each turn was drawn from
  const folded = new Map(); // turn index → true (folded) / false (open) once the reader chose; absent: the default
  let turnCount = 0;

  /** [{prompt: user item | null, steps: [assistant | tool | denied items]}]. Rows before the first prompt (only when
   *  the transcript's tail was cut) share one turn without a prompt. */
  function groupTurns(items) {
    const turns = [];
    for (const item of items) {
      if (item.kind === "user" || !turns.length) turns.push({ prompt: item.kind === "user" ? item : null, steps: [] });
      if (item.kind !== "user") turns[turns.length - 1].steps.push(item);
    }
    return turns;
  }

  const isFolded = (index, last) => folded.has(index) ? folded.get(index) : !last;

  function preview(turn) {
    for (let i = turn.steps.length - 1; i >= 0; i--) {
      const step = turn.steps[i];
      if (step.kind !== "assistant") continue;
      const text = step.blocks.map((b) => b.markdown).join(" ").replace(/[#*`>_|-]+/g, " ").replace(/\s+/g, " ").trim();
      if (text) return text.length > 140 ? `${text.slice(0, 139)}…` : text;
    }
    return "";
  }

  function turnElement(turn, index, last) {
    const el = document.createElement("section");
    el.className = "turn";
    el.dataset.index = index;
    const head = document.createElement("button");
    head.type = "button";
    head.className = "turn-head";
    head.innerHTML = '<span class="turn-chev" aria-hidden="true"></span><span class="turn-main"><span class="turn-title"></span>' +
      '<span class="turn-peek"></span></span><span class="turn-meta"></span>';
    head.querySelector(".turn-title").textContent = turn.prompt ? turn.prompt.text : "Earlier in this chat";
    head.querySelector(".turn-peek").textContent = preview(turn);
    const tools = turn.steps.filter((s) => s.kind !== "assistant").length;
    const replies = turn.steps.length - tools;
    head.querySelector(".turn-meta").textContent = [index > 0 || turn.prompt ? `#${index + 1}` : "", tools ? `${tools} tool${tools > 1 ? "s" : ""}` : "",
      replies ? `${replies} repl${replies > 1 ? "ies" : "y"}` : ""].filter(Boolean).join(" · ");
    head.addEventListener("click", () => {
      const now = !el.classList.contains("folded");
      folded.set(index, now);
      setFolded(el, now);
      paintFold(turnCount);
    });
    const body = document.createElement("div");
    body.className = "turn-body";
    if (turn.prompt) body.append(row(turn.prompt));
    for (const step of turn.steps) body.append(row(step));
    el.append(head, body);
    setFolded(el, isFolded(index, last));
    return el;
  }

  function setFolded(el, value) {
    el.classList.toggle("folded", value);
    el.querySelector(".turn-head").setAttribute("aria-expanded", String(!value));
  }

  function refreshFold(index, turns) {
    const el = list.children[index];
    if (el) setFolded(el, isFolded(index, index === turns.length - 1));
  }

  function paintFold(count) {
    turnCount = count;
    const all = [...list.children];
    const open = all.some((el) => !el.classList.contains("folded"));
    $("thread-fold").textContent = open ? "Fold all" : "Unfold all";
  }

  $("thread-fold").addEventListener("click", () => {
    const all = [...list.children];
    const fold = all.some((el) => !el.classList.contains("folded"));
    all.forEach((el, i) => { folded.set(i, fold); setFolded(el, fold); });
    paintFold(all.length);
  });

  Object.assign(window.glance, {
    /** One reply block drawn as the conversation draws it (summary.js uses it too). */
    block: blockElement,

    /** {context, route, routeLabel, working, notice, sessions, active}, or null: no Razor Code tab in front, no composer.
     *  An editor tab coming to the front opens on its conversations: the editor pane never shows terminal replies. */
    chatComposer(c) {
      const arrived = c && !state;
      state = c;
      composer.hidden = !c;
      if (!c) exitChat();
      paint();
      if (arrived) enterChat();
    },

    /** The project's terminal sessions for the ☰ menu: [{id, title, turns, updated, live}], newest first. */
    summarySessions(list) {
      $("menu-terms-none").hidden = list.length > 0;
      $("menu-terms-list").replaceChildren(...list.map((entry) => {
        const b = item(entry.title || "Untitled session", false, () => {
          toggleMenu(false);
          document.dispatchEvent(new CustomEvent("glance:summary-pick", { detail: entry.id }));
        }, entry.live ? "open" : ago(entry.updated));
        if (entry.turns) {
          const turns = document.createElement("span");
          turns.className = "turns";
          turns.textContent = `${entry.turns} turns`;
          b.insertBefore(turns, b.querySelector(".when"));
        }
        return b;
      }));
      if (!$("menu-terms").hidden) $("menu-terms-back").focus();
    },

    /** {working, truncated, items: [{kind, …}]}: grouped into one collapsible turn per prompt; turns are redrawn only
     *  when they changed; new ones rise in. */
    chatThread(t) {
      threadWorking = !!t.working;
      const nearBottom = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 48;
      const turns = groupTurns(t.items || []);
      let added = 0;
      turns.forEach((turn, i) => {
        const drawnFrom = JSON.stringify(turn);
        if (shownTurns[i] === drawnFrom) return;
        const el = turnElement(turn, i, i === turns.length - 1);
        const old = list.children[i];
        if (old) {
          old.replaceWith(el);
        } else {
          el.classList.add("rise");
          el.style.animationDelay = `${Math.min(added++ * 60, 300)}ms`;
          list.append(el);
        }
        shownTurns[i] = drawnFrom;
      });
      // The turn that used to be last is no longer: fold it unless the reader opened it.
      if (turns.length > 1) refreshFold(turns.length - 2, turns);
      while (list.children.length > turns.length) list.lastElementChild.remove();
      shownTurns.length = turns.length;
      for (const key of [...folded.keys()]) if (key >= turns.length) folded.delete(key);
      $("thread-earlier").hidden = !t.truncated;
      $("thread-empty").hidden = turns.length === 0;
      $("thread-fold").hidden = turns.length < 2;
      paintFold(turns.length);
      paint();
      if (nearBottom || added) scrollDown(added > 0);
    },
  });
})();
