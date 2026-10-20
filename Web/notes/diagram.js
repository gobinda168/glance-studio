"use strict";

// One note diagram: Mermaid code rendered in the app's diagram colours. Swift calls `glanceRender(code, theme)`; the
// page answers with its height ({type: "size"}) or Mermaid's error ({type: "error"}).

const COLORS = {
  dark: {
    ink: "#f1ede4", body: "#c5bfb3", mu: "#9a948a", node: "#24221f", border: "#3a3732", line: "#8a847a",
    life: "#ffffff2e", label: "#1c1b19", note: "#2c1a12", noteText: "#f3d4c4", hot: "#3a2218", teal: "#1d3637",
  },
  light: {
    ink: "#1c1a17", body: "#4a453d", mu: "#7a746a", node: "#f6f2e8", border: "#d6cfbf", line: "#8a847a",
    life: "#1c1a1730", label: "#ffffff", note: "#fbe9df", noteText: "#6b2c14", hot: "#fbe9df", teal: "#dcefef",
  },
};

const post = (message) => window.webkit?.messageHandlers?.glanceDiagram?.postMessage(message);
const stage = document.getElementById("stage");
let renders = 0;

function configure(theme) {
  const c = COLORS[theme] || COLORS.dark;
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: "base",
    fontFamily: '-apple-system, "SF Pro Text", system-ui, sans-serif',
    themeVariables: {
      darkMode: theme === "dark",
      background: "transparent",
      fontSize: "13px",
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
    flowchart: { curve: "basis", padding: 14 },
    sequence: { mirrorActors: false, actorFontWeight: 600 },
  });
}

function reportSize() {
  post({ type: "size", height: Math.ceil(stage.getBoundingClientRect().height) });
}

window.glanceRender = async (code, theme) => {
  const mine = ++renders;
  configure(theme);
  try {
    const { svg } = await mermaid.render(`d${mine}`, code);
    if (mine !== renders) return;
    stage.innerHTML = svg;
    const el = stage.querySelector("svg");
    const natural = el?.viewBox?.baseVal?.width || 0;
    // Too wide to read when shrunk: keep a readable size and scroll sideways.
    stage.classList.toggle("wide", natural * 0.6 > stage.clientWidth);
    if (stage.classList.contains("wide") && el) {
      el.setAttribute("width", Math.round(natural * 0.8));
      el.removeAttribute("height");
    }
    post({ type: "rendered" });
  } catch (e) {
    if (mine !== renders) return;
    stage.innerHTML = "";
    document.querySelectorAll("[id^='dd']").forEach((n) => n.remove()); // Mermaid's leftover error drawing
    post({ type: "error", message: String((e && e.message) || e).split("\n").slice(0, 3).join(" ") });
  }
  reportSize();
};

new ResizeObserver(reportSize).observe(stage);
post({ type: "ready" });
