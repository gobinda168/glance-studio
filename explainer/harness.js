// Make explainer: what the renderer calls on the page, once per frame. Injected at document start.
(function () {
  if (window.__glanceScene) return;

  // No WebRTC: it opens network paths (ICE, STUN) that the content rules can't see. Every frame gets this.
  for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel"]) {
    const blocked = function () { throw new DOMException("WebRTC is off while a scene is rendered", "NotSupportedError"); };
    try { Object.defineProperty(window, name, { value: blocked, configurable: false, writable: false }); } catch (e) {}
  }

  // No resource hints: dns-prefetch, preconnect and prefetch look names up or connect outside the content rules. They
  // are removed as the parser adds them and when a script does. (A lookup may start before the removal; see the report.)
  const hint = /(^|\s)(dns-prefetch|preconnect|prefetch|prerender)(\s|$)/i;
  const strip = node => {
    if (node.nodeType !== 1) return;
    if (node.localName === "link" && hint.test(node.getAttribute("rel") || "")) { node.remove(); return; }
    node.querySelectorAll?.("link[rel]").forEach(l => { if (hint.test(l.getAttribute("rel"))) l.remove(); });
  };
  new MutationObserver(records => {
    for (const r of records) {
      r.addedNodes.forEach(strip);
      if (r.type === "attributes") strip(r.target);
    }
  }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ["rel"] });

  // Shows the <section data-scene="id"> and hides the others, then tells the page which scene started and how long it
  // lasts: document.addEventListener("glance:scene", e => e.detail.id / e.detail.durationMs). False when there is no
  // such section.
  window.__glanceScene = function (id, durationMs) {
    let found = false;
    document.querySelectorAll("section[data-scene]").forEach(section => {
      if (section.getAttribute("data-scene") === id) {
        section.style.removeProperty("display");
        found = true;
      } else {
        section.style.setProperty("display", "none", "important");
      }
    });
    if (found) document.dispatchEvent(new CustomEvent("glance:scene", { bubbles: true, detail: { id, durationMs } }));
    return found;
  };

  // The one place that sets the picture's time: every CSS and Web animation is paused at the scene's local time, then
  // the page's own seek hook (window.__seek(localMs), for canvas or script-driven scenes) gets the same time.
  window.__glanceSeek = function (localMs) {
    document.getAnimations().forEach(a => { try { a.pause(); a.currentTime = localMs; } catch (e) {} });
    window.__seek?.(localMs);
  };
})();
