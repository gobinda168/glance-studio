// The Glance page: the same page as the Mac app's panel (Web/, copied to media/web), loaded in a webview. It's shown
// either as the orb's floating window (GlanceFloat) or as a view in the side bar (GlanceView). Calls go in as
// {method, args} messages; the page answers with the messages the Mac app's ContentWeb handles.
import * as fs from "node:fs";
import * as vscode from "vscode";

export type PageMessage =
  | { type: "ready" }
  | { type: "rendered"; generation: number }
  | { type: "copy"; text: string }
  | { type: "open"; url: string }
  | { type: "action"; name: string }
  | { type: "prefs"; prefs: unknown }
  | { type: "voice"; id: string }
  | { type: "auto"; on: boolean };

/** One loaded copy of the page, in a webview view or a webview panel. */
export class PageHost {
  private ready = false;
  private queued: { method: string; args: unknown[] }[] = [];
  private readonly subscription: vscode.Disposable;

  constructor(private readonly webview: vscode.Webview, extensionUri: vscode.Uri,
              onMessage: (message: PageMessage, host: PageHost) => void) {
    const web = vscode.Uri.joinPath(extensionUri, "media", "web");
    webview.options = { enableScripts: true, localResourceRoots: [web] };
    webview.html = html(webview, web);
    this.subscription = webview.onDidReceiveMessage((message: PageMessage) => {
      if (message?.type === "ready") {
        this.ready = true;
        const pending = this.queued;
        this.queued = [];
        for (const call of pending) void webview.postMessage(call);
      }
      onMessage(message, this);
    });
  }

  /** Calls `window.glance[method](...args)` in the page, once it has loaded. */
  call(method: string, ...args: unknown[]) {
    if (!this.ready) { this.queued.push({ method, args }); return; }
    void this.webview.postMessage({ method, args });
  }

  get isReady() { return this.ready; }

  dispose() { this.subscription.dispose(); }
}

type Listener = { onMessage: (message: PageMessage, host: PageHost) => void; onVisible: (host: PageHost) => void };

/** The page as a view in the Glance activity-bar container (the "sidebar" placement). */
export class GlanceView implements vscode.WebviewViewProvider {
  static readonly id = "glance.panel";
  view?: vscode.WebviewView;
  host?: PageHost;

  constructor(private readonly extensionUri: vscode.Uri, private readonly listener: Listener) {}

  resolveWebviewView(view: vscode.WebviewView) {
    this.view = view;
    const host = this.host = new PageHost(view.webview, this.extensionUri, this.listener.onMessage);
    view.onDidChangeVisibility(() => { if (view.visible) this.listener.onVisible(host); });
    view.onDidDispose(() => { host.dispose(); if (this.host === host) { this.host = undefined; this.view = undefined; } });
  }
}

/** The page in its own floating window, opened and closed from the orb in the status bar (the "orb" placement). */
export class GlanceFloat {
  static readonly viewType = "glance.float";
  panel?: vscode.WebviewPanel;
  host?: PageHost;
  onDidChange?: () => void;
  /** The window stays above the editor, so bringing it forward doesn't need to take focus. */
  private onTop = false;

  constructor(private readonly extensionUri: vscode.Uri, private readonly listener: Listener) {}

  get isOpen() { return !!this.panel; }

  async toggle() {
    if (this.panel) this.close();
    else await this.open();
  }

  /**
   * Opens the window, or brings it forward if it's already open. Without "always on top" (Cursor) the window can be
   * behind the editor, and only taking focus raises it.
   */
  async open() {
    if (this.panel) { this.panel.reveal(undefined, this.onTop); return; }
    const panel = this.panel = vscode.window.createWebviewPanel(GlanceFloat.viewType, "Glance",
      { viewColumn: vscode.ViewColumn.Active, preserveFocus: false },
      { retainContextWhenHidden: true });
    panel.iconPath = vscode.Uri.joinPath(this.extensionUri, "media", "glance.svg");
    const host = this.host = new PageHost(panel.webview, this.extensionUri, this.listener.onMessage);
    panel.onDidChangeViewState(() => { if (panel.visible) this.listener.onVisible(host); });
    panel.onDidDispose(() => {
      host.dispose();
      if (this.panel === panel) { this.panel = undefined; this.host = undefined; this.onDidChange?.(); }
    });
    this.onDidChange?.();
    this.onTop = await floatActiveEditor();
  }

  close() { this.panel?.dispose(); }
}

/**
 * Moves the active editor (the panel just created) into its own window, then makes that window small and always on
 * top where the editor supports it. VS Code has had floating editor windows since 1.85; "always on top" and "compact"
 * aren't in every build (Cursor, for one), so each step runs only if its command exists. Without floating windows at
 * all (VS Code for the Web), the panel stays as an editor tab.
 */
async function floatActiveEditor(): Promise<boolean> {
  const available = new Set(await vscode.commands.getCommands(true));
  const run = async (id: string) => {
    if (!available.has(id)) return false;
    try { await vscode.commands.executeCommand(id); return true; } catch { return false; }
  };
  if (!(await run("workbench.action.moveEditorToNewWindow"))) return false;
  await run("workbench.action.enableCompactAuxiliaryWindow");
  return run("workbench.action.enableWindowAlwaysOnTop");
}

function html(webview: vscode.Webview, web: vscode.Uri): string {
  const page = fs.readFileSync(vscode.Uri.joinPath(web, "index.html").fsPath, "utf8");
  const csp = [
    "default-src 'none'",
    `script-src ${webview.cspSource} 'unsafe-eval'`,
    `style-src ${webview.cspSource} 'unsafe-inline'`,
    `img-src ${webview.cspSource} data:`,
    `font-src ${webview.cspSource} data:`,
  ].join("; ");
  return page
    .replace(/<meta http-equiv="Content-Security-Policy"[\s\S]*?>/, `<meta http-equiv="Content-Security-Policy" content="${csp}">`)
    .replace("<head>", `<head>\n  <base href="${webview.asWebviewUri(web)}/">`)
    .replace('<html lang="en" data-theme="dark">', '<html lang="en" data-theme="dark" data-host="vscode">');
}
