// Glance for VS Code: follows Claude Code sessions in this window's folders and, when Claude finishes a reply, shows
// it in the Glance page (rendered Markdown and Mermaid, diagrams drawn as they're explained) and reads it aloud.
// The page opens from the orb in the status bar as a floating window, or lives in the side bar (`glance.placement`).
// The same flow as the Mac app's AppController.
import * as os from "node:os";
import * as path from "node:path";
import * as vscode from "vscode";
import { Block, splitBlocks } from "./core/blocks";
import { diagramAnchors } from "./core/narration";
import { speechText } from "./core/speech";
import { clampPrefs, OrbState, PanelPrefs, panelStatus } from "./core/status";
import { lastReply } from "./core/transcript";
import { Narrator, Segment, VoiceChoice } from "./narrator";
import { GlanceFloat, GlanceView, PageHost, PageMessage } from "./panel";
import { readTail, SessionEvent, TranscriptWatcher } from "./watcher";
import { activateEmbedded } from "./embedded/embedded";

const KEY_SECRET = "glance.elevenLabsKey";

export function activate(context: vscode.ExtensionContext) {
  // Glance Studio's editor tab: the native Glance pane is beside VS Code, so no panel or voice here.
  const bridgeSocket = process.env.GLANCE_BRIDGE;
  if (bridgeSocket) {
    activateEmbedded(context, bridgeSocket);
    return;
  }
  const glance = new Glance(context);
  context.subscriptions.push({ dispose: () => glance.dispose() });
}

export function deactivate() {}

type Placement = "orb" | "sidebar";

class Glance {
  private view: GlanceView;
  private float: GlanceFloat;
  private narrator: Narrator;
  private watcher: TranscriptWatcher;
  private status: vscode.StatusBarItem;
  private prefs: PanelPrefs;
  private elevenLabsKey: string | undefined;

  private state: OrbState = "idle";
  private notice: string | null = null;
  private blocks: Block[] = [];
  private segments: Segment[] = [];
  private anchors = new Map<number, number[]>();
  private narrateWhenRendered = false;
  /** The page whose "rendered" starts the narration; any other open page just catches up. */
  private renderingOn?: PageHost;
  private speakingBlock?: number;
  /** A reply arrived while the orb's window was closed. */
  private unseen = false;
  private thinkingTimeout?: NodeJS.Timeout;

  constructor(private readonly context: vscode.ExtensionContext) {
    const theme = vscode.window.activeColorTheme.kind;
    const light = theme === vscode.ColorThemeKind.Light || theme === vscode.ColorThemeKind.HighContrastLight;
    this.prefs = clampPrefs(context.globalState.get<PanelPrefs>("panel") ?? { theme: light ? "light" : "dark" });

    const listener = {
      onMessage: (message: PageMessage, host: PageHost) => this.handlePage(message, host),
      onVisible: (host: PageHost) => this.pushAll(host),
    };
    this.view = new GlanceView(context.extensionUri, listener);
    context.subscriptions.push(vscode.window.registerWebviewViewProvider(GlanceView.id, this.view,
      { webviewOptions: { retainContextWhenHidden: true } }));
    this.float = new GlanceFloat(context.extensionUri, listener);
    this.float.onDidChange = () => {
      if (this.float.isOpen) this.unseen = false;
      // Closed before it drew the reply: don't leave the narration waiting for it.
      if (this.renderingOn && !this.hosts.includes(this.renderingOn)) { this.renderingOn = undefined; this.rendered(); }
      this.updateStatusBar();
    };
    context.subscriptions.push({ dispose: () => this.float.close() });

    this.narrator = new Narrator(() => ({
      choice: this.voiceChoice,
      speed: this.prefs.speed,
      systemVoice: vscode.workspace.getConfiguration("glance").get<string>("systemVoice", ""),
      elevenLabs: this.elevenLabsKey ? {
        key: this.elevenLabsKey,
        voiceId: vscode.workspace.getConfiguration("glance").get<string>("elevenLabs.voiceId", "Xb7hH8MSUJpSbSDYk0k2"),
        model: vscode.workspace.getConfiguration("glance").get<string>("elevenLabs.model", "eleven_flash_v2_5"),
      } : undefined,
    }));
    this.narrator.onSegmentStart = (segment, ms) => this.segmentStarted(segment, ms);
    this.narrator.onFinish = () => this.narrationFinished();
    this.narrator.onNotice = (notice) => { this.notice = notice; this.pushState(); };

    this.status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    this.status.command = "glance.toggle";
    this.status.show();
    context.subscriptions.push(this.status);

    const commands: [string, () => unknown][] = [
      ["glance.toggle", () => this.toggle()],
      ["glance.playPause", () => this.playPause()],
      ["glance.stop", () => this.stopNarration()],
      ["glance.replayLast", () => this.render(true)],
      ["glance.setElevenLabsKey", () => this.setKey()],
      ["glance.clearElevenLabsKey", () => this.clearKey()],
    ];
    for (const [id, run] of commands) context.subscriptions.push(vscode.commands.registerCommand(id, run));

    this.watcher = new TranscriptWatcher(path.join(os.homedir(), ".claude", "projects"),
      (cwd) => this.accepts(cwd), (event) => this.handleSession(event));
    try {
      this.watcher.start();
    } catch (error) {
      void vscode.window.showWarningMessage(`Glance can't watch Claude Code transcripts: ${(error as Error).message}`);
    }

    context.subscriptions.push(vscode.workspace.onDidChangeConfiguration((e) => {
      if (!e.affectsConfiguration("glance.placement")) return;
      if (this.placement !== "orb") this.float.close();
      this.unseen = false;
      this.updateStatusBar();
    }));

    void context.secrets.get(KEY_SECRET).then((key) => { this.elevenLabsKey = key; this.pushPrefs(); });
    context.subscriptions.push(context.secrets.onDidChange(async (e) => {
      if (e.key === KEY_SECRET) { this.elevenLabsKey = await context.secrets.get(KEY_SECRET); this.pushPrefs(); }
    }));
    this.updateStatusBar();
  }

  dispose() {
    this.watcher.dispose();
    this.narrator.dispose();
  }

  // ── Claude Code sessions ─────────────────────────────────────

  private accepts(cwd: string | undefined): boolean {
    if (vscode.workspace.getConfiguration("glance").get("watch") === "everywhere") return true;
    const folders = vscode.workspace.workspaceFolders ?? [];
    if (!folders.length) return true;
    if (!cwd) return false;
    const norm = (p: string) => (process.platform === "linux" ? p : p.toLowerCase()).replace(/[\\/]+$/, "");
    return folders.some((f) => {
      const root = norm(f.uri.fsPath), dir = norm(cwd);
      return dir === root || dir.startsWith(root + path.sep) || dir.startsWith(root + "/");
    });
  }

  private handleSession(event: SessionEvent) {
    if (event.kind === "prompt") {
      this.stopNarration();
      this.setState("thinking");
      clearTimeout(this.thinkingTimeout);
      this.thinkingTimeout = setTimeout(() => { if (this.state === "thinking") this.setState("idle"); }, 600_000);
      return;
    }
    clearTimeout(this.thinkingTimeout);
    let reply: string | null = null;
    try { reply = lastReply(readTail(event.file)); } catch {}
    if (!reply) { if (this.state === "thinking") this.setState("idle"); return; }
    this.show(reply);
  }

  private show(reply: string) {
    this.stopNarration();
    this.notice = null;
    this.blocks = splitBlocks(reply);
    this.segments = this.blocks.flatMap((block, i) => {
      const text = speechText(block);
      return text ? [{ block: i, text }] : [];
    });
    this.anchors = diagramAnchors(this.blocks, this.segments.map((s) => s.block));
    this.setState("reading");
    // Short acknowledgements update the view quietly; explanations and diagrams bring it forward.
    const worthShowing = this.blocks.some((b) => b.kind === "mermaid") || this.segments.length >= 2;
    if (worthShowing) this.bringForward();
    this.render(this.auto);
  }

  /** Puts the reply on the open pages; narration starts once the first of them says it has drawn it. */
  private render(narrate: boolean) {
    if (!this.blocks.length) return;
    this.narrateWhenRendered = narrate;
    const ready = this.hosts.filter((h) => h.isReady);
    this.renderingOn = ready[0];
    if (!ready.length) {
      // No page yet: read anyway, the page shows the reply when it opens.
      this.rendered();
      return;
    }
    for (const host of ready) host.call("render", this.blocks);
  }

  /** A page that opened (or reloaded) after the reply arrived: show it as it stands now. */
  private catchUp(host: PageHost) {
    host.call("revealAll", 1200);
    if (this.narrator.isSpeaking) {
      host.call("narrating", true);
      if (this.speakingBlock !== undefined) host.call("speaking", this.speakingBlock);
    }
  }

  private rendered() {
    if (!this.narrateWhenRendered) {
      if (this.state === "reading") this.setState("idle");
      this.call("revealAll", 1800);
      return;
    }
    this.narrateWhenRendered = false;
    this.startNarration();
  }

  // ── Narration ────────────────────────────────────────────────

  private startNarration() {
    if (!this.segments.length) { this.setState("idle"); this.call("revealAll", 1800); return; }
    this.call("narrating", true);
    for (const diagram of this.anchors.get(-1) ?? []) this.call("reveal", diagram, 1800);
    this.narrator.speak(this.segments);
  }

  private segmentStarted(segment: Segment, ms: number) {
    this.setState(this.narrator.isPaused ? "paused" : "speaking");
    this.speakingBlock = segment.block;
    this.call("speaking", segment.block);
    for (const diagram of this.anchors.get(segment.block) ?? []) {
      this.call("reveal", diagram, Math.max(1400, Math.round(ms * 0.9)));
    }
  }

  private narrationFinished() {
    this.speakingBlock = undefined;
    this.setState("idle");
    this.call("narrating", false);
    this.call("revealAll", 1200);
  }

  private stopNarration() {
    this.narrator.stop();
    this.speakingBlock = undefined;
    this.call("narrating", false);
    if (this.state === "speaking" || this.state === "paused" || this.state === "reading") this.setState("idle");
  }

  private playPause() {
    if (this.narrator.isSpeaking) {
      this.narrator.togglePause();
      this.setState(this.narrator.isPaused ? "paused" : "speaking");
    } else if (this.blocks.length) {
      this.startNarration();
    }
  }

  // ── Where the page shows ─────────────────────────────────────

  private get placement(): Placement {
    return vscode.workspace.getConfiguration("glance").get<Placement>("placement", "orb") === "sidebar" ? "sidebar" : "orb";
  }

  /** The orb (status bar item) opens and closes the floating window; with the side bar placement it opens the view. */
  private async toggle() {
    if (this.placement === "sidebar") {
      await vscode.commands.executeCommand("workbench.view.extension.glance");
      return;
    }
    await this.float.toggle();
  }

  /**
   * An explanation or diagram arrived: the side bar view comes forward without taking focus, the floating window opens
   * or comes forward. With `revealOnReply` off, the orb says there's a new reply instead.
   */
  private bringForward() {
    if (!vscode.workspace.getConfiguration("glance").get("revealOnReply", true)) {
      if (this.placement === "orb" && !this.float.isOpen) { this.unseen = true; this.updateStatusBar(); }
      return;
    }
    if (this.placement === "sidebar") this.view.view?.show(true);
    else void this.float.open();
  }

  private get hosts(): PageHost[] {
    return [this.float.host, this.view.host].filter((h): h is PageHost => !!h);
  }

  /** Calls the page method in every open page. */
  private call(method: string, ...args: unknown[]) {
    for (const host of this.hosts) host.call(method, ...args);
  }

  // ── The page ─────────────────────────────────────────────────

  private handlePage(message: PageMessage, host: PageHost) {
    switch (message?.type) {
      case "ready":
        this.pushAll(host);
        if (this.blocks.length) host.call("render", this.blocks);
        break;
      case "rendered":
        if (host === this.renderingOn) { this.renderingOn = undefined; this.rendered(); }
        else this.catchUp(host);
        break;
      case "copy":
        void vscode.env.clipboard.writeText(message.text);
        break;
      case "open": {
        const uri = vscode.Uri.parse(message.url);
        if (uri.scheme === "http" || uri.scheme === "https") void vscode.env.openExternal(uri);
        break;
      }
      case "action":
        if (message.name === "playPause") this.playPause();
        else if (message.name === "play" && (!this.narrator.isSpeaking || this.narrator.isPaused)) this.playPause();
        else if (message.name === "pause" && this.narrator.isSpeaking && !this.narrator.isPaused) this.playPause();
        else if (message.name === "settingsWindow") void vscode.commands.executeCommand("workbench.action.openSettings", "@ext:glance.glance-claude");
        break;
      case "prefs":
        this.prefs = clampPrefs(message.prefs as Partial<PanelPrefs>);
        void this.context.globalState.update("panel", this.prefs);
        for (const other of this.hosts) if (other !== host) this.pushPrefs(other);
        break;
      case "voice":
        void this.pickVoice(message.id);
        break;
      case "auto":
        void this.context.globalState.update("auto", message.on);
        if (!message.on && this.narrator.isSpeaking) { this.stopNarration(); this.call("revealAll", 1200); }
        break;
    }
  }

  private get auto(): boolean { return this.context.globalState.get<boolean>("auto", true); }

  private get voiceChoice(): VoiceChoice {
    const saved = this.context.globalState.get<VoiceChoice>("voice");
    if (saved === "elevenlabs" && this.elevenLabsKey) return "elevenlabs";
    if (saved === "system") return "system";
    return this.elevenLabsKey ? "elevenlabs" : "system";
  }

  private async pickVoice(id: string) {
    if (id === "elevenlabs" && !this.elevenLabsKey) {
      if (!(await this.setKey())) { this.pushPrefs(); return; }
    }
    await this.context.globalState.update("voice", id === "elevenlabs" ? "elevenlabs" : "system");
    this.notice = null;
    this.pushPrefs();
    this.pushState();
  }

  private pushAll(host?: PageHost) { this.pushPrefs(host); this.pushState(host); }

  private pushState(host?: PageHost) {
    this.send(host, "state", {
      ...panelStatus(this.state, this.blocks.length > 0),
      playing: this.state === "speaking",
      hasReply: this.blocks.length > 0,
      notice: this.notice ?? undefined,
    });
  }

  private pushPrefs(host?: PageHost) {
    const system = process.platform === "darwin" ? "Mac" : "System";
    this.send(host, "prefs", {
      ...this.prefs,
      auto: this.auto,
      voices: {
        options: [
          { id: "system", name: system, title: "Your computer's built-in voice" },
          { id: "elevenlabs", name: "ElevenLabs", title: this.elevenLabsKey ? undefined : "Add a key: Glance: Set ElevenLabs API Key" },
        ],
        selected: this.voiceChoice,
      },
    });
  }

  /** Calls the page method in one page, or in every open page. */
  private send(host: PageHost | undefined, method: string, ...args: unknown[]) {
    if (host) host.call(method, ...args);
    else this.call(method, ...args);
  }

  private setState(state: OrbState) {
    if (this.state === state) return;
    this.state = state;
    this.pushState();
    this.updateStatusBar();
  }

  /** The orb: the status bar item at the bottom right, beside Claude Code's. */
  private updateStatusBar() {
    const icon = { idle: "$(circle-filled)", thinking: "$(loading~spin)", reading: "$(eye)", speaking: "$(unmute)", paused: "$(debug-pause)" }[this.state];
    const status = panelStatus(this.state, this.blocks.length > 0).header.toLowerCase();
    const orb = this.placement === "orb";
    if (this.unseen && this.state === "idle") {
      this.status.text = "$(sparkle) Glance: new reply";
    } else {
      const waiting = this.state === "idle" && !this.blocks.length;
      this.status.text = `${icon} Glance${waiting ? "" : `: ${status}`}`;
    }
    const action = !orb ? "Click to open the Glance view" : this.float.isOpen ? "Click to close Glance" : "Click to open Glance";
    this.status.tooltip = `Glance · ${status}\n${action}`;
  }

  // ── ElevenLabs key ───────────────────────────────────────────

  private async setKey(): Promise<boolean> {
    const key = await vscode.window.showInputBox({
      title: "ElevenLabs API key",
      prompt: "Stored in VS Code's secret storage. Get one at elevenlabs.io → Profile → API keys.",
      password: true,
      ignoreFocusOut: true,
      validateInput: (v) => (v.trim().length < 10 ? "That doesn't look like an API key" : null),
    });
    if (!key) return false;
    await this.context.secrets.store(KEY_SECRET, key.trim());
    this.elevenLabsKey = key.trim();
    await this.context.globalState.update("voice", "elevenlabs");
    this.pushPrefs();
    return true;
  }

  private async clearKey() {
    await this.context.secrets.delete(KEY_SECRET);
    this.elevenLabsKey = undefined;
    this.pushPrefs();
  }
}
