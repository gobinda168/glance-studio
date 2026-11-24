// Make explainer: the fake clock. Injected at document start. The page's time is driven only by __clock.advanceTo(ms):
// requestAnimationFrame, Date, performance.now, setTimeout and setInterval all read it, so a scene looks the same
// however long a frame takes to render. Forward only. CSS and Web animations are not touched here: harness.js seeks
// them, once per frame, in the scene's own time.
(function () {
  if (window.__clock) return;
  let now = 0;                        // virtual ms since the page started
  const epoch = 1700000000000;        // virtual Date origin
  let rafId = 1, rafQ = new Map();
  let tid = 1, timers = new Map();    // id -> {t, fn, args, every}
  const RealDate = Date;
  function FakeDate(...a) {
    if (!(this instanceof FakeDate)) return new RealDate(epoch + now).toString();
    return a.length ? new RealDate(...a) : new RealDate(epoch + now);
  }
  FakeDate.prototype = RealDate.prototype;
  FakeDate.now = () => epoch + now;
  FakeDate.parse = RealDate.parse;
  FakeDate.UTC = RealDate.UTC;
  window.Date = FakeDate;
  performance.now = () => now;
  window.requestAnimationFrame = cb => { const id = rafId++; rafQ.set(id, cb); return id; };
  window.cancelAnimationFrame = id => rafQ.delete(id);
  window.setTimeout = (fn, d = 0, ...args) => { const id = tid++; timers.set(id, { t: now + Math.max(0, +d || 0), fn, args }); return id; };
  window.setInterval = (fn, d = 0, ...args) => { const id = tid++; d = Math.max(1, +d || 1); timers.set(id, { t: now + d, fn, args, every: d }); return id; };
  window.clearTimeout = window.clearInterval = id => timers.delete(id);
  function runTimers(upTo) {
    for (;;) {
      let best = null, bid = 0;
      for (const [id, t] of timers) if (t.t <= upTo && (!best || t.t < best.t)) { best = t; bid = id; }
      if (!best) break;
      now = Math.max(now, best.t);
      if (best.every) best.t += best.every; else timers.delete(bid);
      try { best.fn(...best.args); } catch (e) { console.error(e); }
    }
  }
  window.__clock = {
    get now() { return now; },
    // Advances virtual time to `ms` in `step` increments: fires due timers, one animation-frame round per step.
    advanceTo(ms, step = 1000 / 60) {
      if (ms < now) throw new Error("clock cannot go backwards: reload the page");
      while (now < ms) {
        const next = Math.min(ms, now + step);
        runTimers(next);
        now = next;
        const q = rafQ; rafQ = new Map();
        for (const [, cb] of q) { try { cb(now); } catch (e) { console.error(e); } }
      }
      return now;
    },
    // One animation-frame round at the current time, without moving it: callbacks a scene change just queued paint
    // before the scene's first frame is taken.
    flushFrame() {
      const q = rafQ; rafQ = new Map();
      for (const [, cb] of q) { try { cb(now); } catch (e) { console.error(e); } }
    },
  };
})();
