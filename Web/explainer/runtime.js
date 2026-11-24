// What Glance gives every explainer page: beats that follow the voice, node details, before/after switches, and messages
// to the host. In the app it runs in its own script world, so it alone holds the bridge and the page's own scripts (none
// run) couldn't reach it; the replica's demo loads it in a sandboxed iframe. With no voice playing, every beat rests at
// its finished state, so the page reads top to bottom like a document.
(() => {
  const native = window.webkit?.messageHandlers?.explainer;
  const send = (m) => (native ? native.postMessage(m) : parent.postMessage(m, "*"));
  const beats = [...document.querySelectorAll("[data-beat]")];
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  let active = -1, anims = [], shown = "";

  const rest = (root) => root.getAnimations({ subtree: true }).forEach((a) => {
    a.pause();
    const end = a.effect.getComputedTiming().endTime;
    a.currentTime = Number.isFinite(end) ? end : 0;
  });

  // Listen and Ask are Glance's, so a page only writes its content.
  for (const b of beats) {
    const h2 = b.querySelector("h2");
    if (h2 && !b.querySelector(".listen")) {
      const top = document.createElement("div");
      top.className = "top";
      h2.replaceWith(top);
      const listen = document.createElement("button");
      listen.className = "listen"; listen.textContent = "Listen";
      top.append(h2, listen);
    }
    if (!b.querySelector(".ask")) {
      const foot = document.createElement("div");
      foot.className = "foot";
      const ask = document.createElement("button");
      ask.className = "ask"; ask.textContent = "Ask about this";
      foot.append(ask);
      b.append(foot);
    }
  }

  // Each sentence is its own span, so the one being said can stand out.
  for (const b of beats) {
    const say = b.querySelector(".say");
    if (!say) continue;
    const parts = say.textContent.match(/[^.!?]+[.!?]+/g) || [say.textContent];
    b.chars = parts.map((p) => p.length);
    say.textContent = "";
    parts.forEach((p) => { const s = document.createElement("span"); s.textContent = p; say.append(s); });
  }

  const enter = (i) => {
    active = i;
    document.body.classList.add("narrating");
    beats.forEach((b, n) => b.classList.toggle("now", n === i));
    rest(document.body);
    anims = beats[i].getAnimations({ subtree: true });
    anims.forEach((a) => a.pause());
    send({ type: "beat", i, top: beats[i].offsetTop });
  };
  const leave = () => {
    active = -1; anims = []; shown = "";
    document.body.classList.remove("narrating");
    beats.forEach((b) => { b.classList.remove("now"); b.querySelectorAll(".say span").forEach((s) => s.classList.remove("on")); rest(b); });
  };
  const time = (i, t, spoken) => {
    if (!beats[i]) return;
    if (i !== active) enter(i);
    for (const a of anims) {
      const end = a.effect.getComputedTiming().endTime;
      a.currentTime = still ? (Number.isFinite(end) ? end : 0) : t * 1000;
    }
    const b = beats[i], total = b.chars.reduce((x, y) => x + y, 0), want = spoken > 0 ? (Math.min(t, spoken) / spoken) * total : 0;
    let n = 0, s = 0;
    for (; s < b.chars.length - 1; s++) { n += b.chars[s]; if (n > want) break; }
    const key = `${i}:${s}`;
    if (key !== shown) { shown = key; b.querySelectorAll(".say span").forEach((el, k) => el.classList.toggle("on", k === s)); }
  };

  // The app calls these (evaluateJavaScript in this world); the replica's frame posts the same things.
  window.__explainer = {
    time, stop: leave,
    theme: (name) => { document.documentElement.dataset.theme = name; },
  };
  if (!native) {
    addEventListener("message", (e) => {
      if (e.source !== parent) return;
      const m = e.data;
      if (m.type === "time") time(m.i, m.t, m.spoken);
      if (m.type === "stop") leave();
      if (m.type === "font") new FontFace(m.family, m.data, { weight: m.weight }).load().then((f) => document.fonts.add(f));
    });
    addEventListener("wheel", () => send({ type: "wheel" }), { passive: true });
  }

  document.addEventListener("click", (e) => {
    const listen = e.target.closest(".listen");
    if (listen) return send({ type: "play", i: beats.indexOf(listen.closest("[data-beat]")) });
    const ask = e.target.closest(".ask");
    if (ask) return send({ type: "ask", title: ask.closest("[data-beat]").querySelector("h2").textContent });
    const file = e.target.closest("[data-file]");
    if (file) return send({ type: "open", path: file.dataset.file });
    const pick = e.target.closest("[data-show]");
    if (pick) {
      const box = pick.closest("[data-compare]");
      if (!box) return;
      box.dataset.compare = pick.dataset.show;
      box.querySelectorAll("[data-show]").forEach((b) => b.setAttribute("aria-pressed", String(b === pick)));
      return;
    }
    const node = e.target.closest("[data-detail]");
    if (node) {
      const beat = node.closest("[data-beat]"), same = node.getAttribute("aria-expanded") === "true";
      const home = node.closest(".viz") || beat;
      let box = beat.querySelector(".detail");
      if (!box) { box = document.createElement("p"); box.className = "detail"; box.hidden = true; home.append(box); }
      beat.querySelectorAll("[data-detail]").forEach((n) => n.setAttribute("aria-expanded", "false"));
      node.setAttribute("aria-expanded", String(!same));
      box.hidden = same;
      box.textContent = same ? "" : node.dataset.detail;
    }
  });

  new ResizeObserver(() => send({ type: "height", h: Math.ceil(document.body.getBoundingClientRect().height) })).observe(document.body);
  beats.forEach(rest);
  send({ type: "ready", beats: beats.map((b) => ({ id: b.dataset.beat, title: b.querySelector("h2")?.textContent ?? "" })) });
})();
