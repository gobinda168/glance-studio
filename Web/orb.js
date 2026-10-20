// The orb the Mac app floats over code editors (VS Code, Cursor…): the panel's orb from Claude Design "Glance Panel
// v11" on its own, as in the design's VS Code "orb" placement. The app sets the mode and feeds the voice level; it
// handles clicks and drags itself, so the page only draws.
(() => {
  const orb = document.getElementById("orb");
  const body = document.getElementById("orb-body");
  let mode = "idle", level = 0, levelAt = 0, amp = 0, last = 0, raf = 0;

  // Same as the panel's orb (panel.js): the real voice level while speaking, else the design's pulse.
  function tick(now) {
    const dt = Math.min(Math.max((now - (last || now)) / 1000, 0), .1);
    last = now;
    const t = now / 300;
    const synthetic = .35 + .65 * Math.abs(Math.sin(t * 1.3)) * (.6 + .4 * Math.abs(Math.sin(t * .55)));
    const measured = now - levelAt < 400;
    const target = mode === "speaking" ? (measured ? Math.min(1, level * 7) : synthetic * .8) : 0;
    amp += (target - amp) * (1 - Math.exp(-dt * (target > amp ? 22 : 7)));
    body.style.transform = `scale(${1 + .14 * amp})`;
    raf = mode === "speaking" || amp > .002 ? requestAnimationFrame(tick) : 0;
    if (!raf) { body.style.transform = ""; last = 0; }
  }
  const wake = () => { if (!raf) raf = requestAnimationFrame(tick); };

  window.glanceOrb = {
    // The orb channel's `working` looks like thinking; the other new modes have their own look (orb.html).
    state(next) { mode = next; orb.dataset.mode = next === "working" ? "thinking" : next; wake(); },
    level(x) { level = x; levelAt = performance.now(); wake(); },
    open(on) { orb.classList.toggle("open", on); },
  };
})();
