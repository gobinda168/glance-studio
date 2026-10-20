// Pure rules for Glance Studio's editor tab (embedded mode).

/** VS Code settings Glance Studio's editor tab starts with. Shells go to Glance Studio tabs, so the terminal panel
 *  stays hidden at start and VS Code doesn't restore old shells (each would come back as a new Glance tab). The
 *  Glance themes follow the window's light or dark, as Glance Studio's own chrome does (VS Code in a browser starts
 *  in a light theme otherwise). */
export const EMBEDDED_DEFAULTS: Record<string, unknown> = {
  "terminal.integrated.hideOnStartup": "always",
  "terminal.integrated.enablePersistentSessions": false,
  "workbench.startupEditor": "none",
  "window.autoDetectColorScheme": true,
  "workbench.preferredDarkColorTheme": "Glance Dark",
  "workbench.preferredLightColorTheme": "Glance Light",
};

/** The defaults to write: those the user has no global value for. */
export function defaultsToApply(globalValues: Record<string, unknown>): [string, unknown][] {
  return Object.entries(EMBEDDED_DEFAULTS).filter(([key]) => globalValues[key] === undefined);
}

export interface OpenedTerminal {
  name: string;
  /** Names of the tasks running now. A task's terminal is named after its task. */
  runningTasks: string[];
  /** Milliseconds since the last task (or debug session) started; negative when its event arrived after the terminal's. */
  msSinceTaskStart?: number;
  msSinceDebugStart?: number;
}

/** A terminal opened as a shell (by the user or an extension), as opposed to one a task or debug session started.
 *  Shells go to a Glance Studio tab; task and debug terminals stay so Build/Run/Debug keep working. */
export function isShellTerminal(t: OpenedTerminal): boolean {
  if (t.runningTasks.includes(t.name) || t.name.startsWith("Task - ")) return false;
  const recent = (ms?: number) => ms !== undefined && Math.abs(ms) < 1500;
  return !recent(t.msSinceTaskStart) && !recent(t.msSinceDebugStart);
}
