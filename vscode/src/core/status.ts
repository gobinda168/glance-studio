// Port of Sources/GlanceCore/PanelState.swift: the words and orb mode for each state, and the panel's settings.

export type OrbState = "idle" | "thinking" | "reading" | "speaking" | "paused";

export interface PanelStatus { mode: string; header: string; title: string; subtitle: string }

export function panelStatus(state: OrbState, hasReply: boolean): PanelStatus {
  switch (state) {
    case "idle": return { mode: "idle", header: hasReply ? "READY" : "WAITING FOR CLAUDE", title: "Idle", subtitle: "READY WHEN YOU ARE" };
    case "thinking": return { mode: "thinking", header: "THINKING", title: "Thinking", subtitle: "WORKING ON AN ANSWER" };
    case "reading": return { mode: "reading", header: "READING", title: "Reading", subtitle: "SCANNING THE PAGE" };
    case "speaking": return { mode: "speaking", header: "READING ALOUD", title: "Speaking", subtitle: "READING ALOUD" };
    case "paused": return { mode: "idle", header: "PAUSED", title: "Paused", subtitle: "PRESS PLAY TO CONTINUE" };
  }
}

export interface PanelPrefs { theme: "dark" | "light"; speed: number; size: number; animate: boolean; follow: boolean }

export const DEFAULT_PREFS: PanelPrefs = { theme: "dark", speed: 1, size: 1, animate: true, follow: true };

/** Fills gaps with defaults and keeps values inside the ranges the controls offer. */
export function clampPrefs(input: Partial<PanelPrefs> | undefined): PanelPrefs {
  const p = { ...DEFAULT_PREFS, ...(input ?? {}) };
  const speed = Number.isFinite(p.speed) ? p.speed : 1;
  return {
    theme: p.theme === "light" ? "light" : "dark",
    speed: Math.min(Math.max(speed, 0.75), 1.5),
    size: Math.min(Math.max(Math.round(Number(p.size) || 0), 0), 2),
    animate: p.animate !== false,
    follow: p.follow !== false,
  };
}
