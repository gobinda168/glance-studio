// glance.js: an automation's web UI talking to Glance Studio (docs/superpowers/specs/2026-10-09-automations-design.md,
// "Web UI contract"). Studio injects it before the page's own scripts, after window.__glanceBoot; a page may also
// load glance-automation://glance/glance.js, which then does nothing.
//
//   glance.automation               { id, name, version, inputs }
//   await glance.run(inputs)        RunHandle { id, onStep(cb), onOutput(cb), cancel(), done }
//                                   done: Promise<{ status, steps: [{ id, status, text, json }] }>
//   glance.cancel(runID)            Promise
//   await glance.runs(limit)        [{ id, status, trigger, startedAt, durationMs }]
//   await glance.state.get(key)     the value, or null
//   glance.state.set(key, value)    Promise (null removes the key)
//   glance.openURL(url)             GitHub pull requests and issues, Slack and files open in Studio; other pages
//                                   in the browser; never github.com in a browser
//   glance.reveal(path)             Finder
//   glance.theme                    "light" | "dark"; "themechange" fires on window (glance.addEventListener)
(() => {
  "use strict";
  if (window.glance) return;

  const boot = window.__glanceBoot || {
    automation: { id: "", name: "", version: 0, inputs: {} },
    theme: window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light",
  };
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.glance;
  let theme = boot.theme === "dark" ? "dark" : "light";
  if (document.documentElement) document.documentElement.dataset.theme = theme;

  // One call to Studio: JSON text out, JSON text back; a refusal rejects with Studio's reason.
  async function call(op, args) {
    if (!handler) throw new Error("glance.js works only inside Glance Studio.");
    const reply = await handler.postMessage(JSON.stringify(Object.assign({}, args, { op })));
    return typeof reply === "string" && reply !== "" ? JSON.parse(reply) : null;
  }

  function safely(callback, value) {
    try {
      callback(value);
    } catch (error) {
      console.error(error);
    }
  }

  // Runs this page started, by id: what they said so far (a late onStep hears it too) and who listens.
  const runs = new Map();
  // Lines of a run whose id the page doesn't know yet: Studio's reply can trail the run's first lines.
  const early = new Map();

  function deliver(run, event) {
    if (event.type === "step") {
      const step = { id: event.step, status: event.status, text: event.text, json: event.json };
      run.steps.push(step);
      run.stepListeners.forEach((callback) => safely(callback, step));
    } else if (event.type === "output") {
      const chunk = { step: event.step, text: event.chunk };
      run.outputs.push(chunk);
      run.outputListeners.forEach((callback) => safely(callback, chunk));
    } else if (event.type === "done") {
      run.settle({ status: event.status, steps: event.steps || [] });
    }
  }

  function track(runID) {
    const run = { steps: [], outputs: [], stepListeners: [], outputListeners: [], settle: null, done: null };
    run.done = new Promise((resolve) => {
      run.settle = resolve;
    });
    runs.set(runID, run);
    (early.get(runID) || []).forEach((event) => deliver(run, event));
    early.delete(runID);
    return run;
  }

  function setTheme(next) {
    const value = next === "dark" ? "dark" : "light";
    if (value === theme) return;
    theme = value;
    if (document.documentElement) document.documentElement.dataset.theme = theme;
    window.dispatchEvent(new CustomEvent("themechange", { detail: { theme } }));
  }

  // Studio calls this with each line of a run the page started, and with theme changes.
  window.__glanceReceive = (event) => {
    if (!event || typeof event !== "object") return;
    if (event.type === "theme") return setTheme(event.theme);
    const run = runs.get(event.runID);
    if (run) return deliver(run, event);
    const waiting = early.get(event.runID) || [];
    waiting.push(event);
    early.set(event.runID, waiting);
  };

  function handle(runID) {
    const run = runs.get(runID) || track(runID);
    const self = {
      id: runID,
      onStep(callback) {
        run.steps.forEach((step) => safely(callback, step));
        run.stepListeners.push(callback);
        return self;
      },
      onOutput(callback) {
        run.outputs.forEach((chunk) => safely(callback, chunk));
        run.outputListeners.push(callback);
        return self;
      },
      cancel() {
        return call("cancel", { runID });
      },
      done: run.done,
    };
    return self;
  }

  const glance = {
    automation: Object.freeze(Object.assign({}, boot.automation)),
    get theme() {
      return theme;
    },
    async run(inputs) {
      const reply = await call("run", { inputs: inputs || {} });
      return handle(reply.runID);
    },
    cancel(runID) {
      return call("cancel", { runID: String(runID) });
    },
    runs(limit) {
      return call("runs", limit === undefined ? {} : { limit });
    },
    state: Object.freeze({
      get(key) {
        return call("state.get", { key: String(key) });
      },
      set(key, value) {
        return call("state.set", { key: String(key), value: value === undefined ? null : value });
      },
    }),
    openURL(url) {
      return call("openURL", { url: String(url) });
    },
    reveal(path) {
      return call("reveal", { path: String(path) });
    },
    addEventListener(type, listener, options) {
      window.addEventListener(type, listener, options);
    },
    removeEventListener(type, listener, options) {
      window.removeEventListener(type, listener, options);
    },
  };
  Object.defineProperty(window, "glance", { value: Object.freeze(glance), enumerable: true });
})();
