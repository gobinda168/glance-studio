// Inside Glance Studio's editor tab the native Glance pane sits beside VS Code, so the extension runs this instead
// of its panel: Glance Studio's defaults, shells to Glance Studio tabs, the task panel tidied after a successful
// task, and ⌘W with no file open closing the tab.
import * as vscode from "vscode";
import { InlineAsk } from "./ask";
import { Bridge } from "./bridge";
import { ChangeMark, markPositions, nextMark } from "./changes";
import { stillChanged } from "./claudeFiles";
import { EMBEDDED_DEFAULTS, defaultsToApply, isShellTerminal } from "./rules";

export function activateEmbedded(context: vscode.ExtensionContext, socketPath: string) {
  void vscode.commands.executeCommand("setContext", "glance.embedded", true);
  const folder = () => vscode.workspace.workspaceFolders?.[0]?.uri.path ?? "";
  const marks = new ClaudeMarks();
  context.subscriptions.push(marks);
  const claude = new ClaudeFiles();
  context.subscriptions.push(claude);
  const ask = new InlineAsk((message) => bridge.send(message), folder);
  context.subscriptions.push(ask);
  const bridge = new Bridge(socketPath, { type: "hello", folder: folder() }, 2000, (command) => {
    if (command.type === "open") void openFile(command.path, command.line, command.column);
    else if (command.type === "askEvent") ask.onEvent(command);
    else if (command.type === "claudeChanges") marks.set(command.files);
    else if (command.type === "claudeFiles") claude.set(command.paths);
  });
  context.subscriptions.push({ dispose: () => bridge.dispose() });
  void applyDefaults();

  let lastTaskStart: number | undefined;
  let lastDebugStart: number | undefined;
  const since = (t?: number) => (t === undefined ? undefined : Date.now() - t);

  context.subscriptions.push(
    vscode.commands.registerCommand("glance.openTerminalTab", () => bridge.send({ type: "openTerminal", cwd: folder() })),
    vscode.commands.registerCommand("glance.closeTab", () => bridge.send({ type: "closeTab" })),
    vscode.tasks.onDidStartTask(() => { lastTaskStart = Date.now(); }),
    vscode.debug.onDidStartDebugSession(() => { lastDebugStart = Date.now(); }),
    vscode.window.onDidOpenTerminal((terminal) => {
      if (!vscode.workspace.getConfiguration("glance").get<boolean>("terminal.redirect", true)) return;
      // A task's start event can arrive just after its terminal: decide a moment later.
      setTimeout(() => {
        const opened = {
          name: terminal.name,
          runningTasks: vscode.tasks.taskExecutions.map((e) => e.task.name),
          msSinceTaskStart: since(lastTaskStart),
          msSinceDebugStart: since(lastDebugStart),
        };
        if (!isShellTerminal(opened)) return;
        const options = terminal.creationOptions as vscode.TerminalOptions;
        const cwd = typeof options.cwd === "string" ? options.cwd : options.cwd?.path ?? folder();
        terminal.dispose();
        bridge.send({ type: "openTerminal", cwd });
      }, 300);
    }),
    vscode.commands.registerCommand("glance.nextClaudeChange", () => marks.go(1)),
    vscode.commands.registerCommand("glance.previousClaudeChange", () => marks.go(-1)),
    vscode.commands.registerCommand("glance.clearClaudeChanges", () => marks.set({})),
    vscode.window.onDidChangeVisibleTextEditors(() => marks.paint()),
    vscode.tasks.onDidEndTaskProcess((event) => {
      if (event.exitCode !== 0) return; // failures stay visible
      setTimeout(() => {
        if (vscode.tasks.taskExecutions.length === 0) void vscode.commands.executeCommand("workbench.action.closePanel");
      }, 3000);
    }),
  );
}

async function applyDefaults() {
  const config = vscode.workspace.getConfiguration();
  const globals: Record<string, unknown> = {};
  for (const key of Object.keys(EMBEDDED_DEFAULTS)) globals[key] = config.inspect(key)?.globalValue;
  for (const [key, value] of defaultsToApply(globals)) {
    await config.update(key, value, vscode.ConfigurationTarget.Global);
  }
}

/** The folder's file at `path` (absolute), keeping the workspace's URI scheme (VS Code's remote one). */
function fileUri(path: string): vscode.Uri {
  const root = vscode.workspace.workspaceFolders?.[0]?.uri;
  return root ? root.with({ path }) : vscode.Uri.file(path);
}

async function openFile(path: string, line?: number, column?: number) {
  const editor = await vscode.window.showTextDocument(fileUri(path), { preview: false });
  if (line) {
    const position = new vscode.Position(Math.max(0, line - 1), Math.max(0, (column ?? 1) - 1));
    editor.selection = new vscode.Selection(position, position);
    editor.revealRange(new vscode.Range(position, position), vscode.TextEditorRevealType.InCenterIfOutsideViewport);
  }
}

/** Claude's latest changed lines, drawn on every visible editor of a marked file. Each `set` replaces the last. */
class ClaudeMarks implements vscode.Disposable {
  private files: Record<string, ChangeMark[]> = {};
  private readonly types = {
    added: vscode.window.createTextEditorDecorationType({
      isWholeLine: true, borderStyle: "solid", borderWidth: "0 0 0 3px", borderColor: "#2ea04399",
      overviewRulerColor: "#2ea043", overviewRulerLane: vscode.OverviewRulerLane.Left,
    }),
    modified: vscode.window.createTextEditorDecorationType({
      isWholeLine: true, borderStyle: "solid", borderWidth: "0 0 0 3px", borderColor: "#1f6feb99",
      overviewRulerColor: "#1f6feb", overviewRulerLane: vscode.OverviewRulerLane.Left,
    }),
    deleted: vscode.window.createTextEditorDecorationType({
      isWholeLine: true, borderStyle: "solid", borderWidth: "2px 0 0 0", borderColor: "#f8514999",
      overviewRulerColor: "#f85149", overviewRulerLane: vscode.OverviewRulerLane.Left,
    }),
  };

  set(files: Record<string, ChangeMark[]>) {
    this.files = files;
    this.paint();
  }

  paint() {
    const root = vscode.workspace.workspaceFolders?.[0]?.uri.path ?? "";
    for (const editor of vscode.window.visibleTextEditors) {
      const relative = editor.document.uri.path.startsWith(root + "/") ? editor.document.uri.path.slice(root.length + 1) : "";
      const marks = this.files[relative] ?? [];
      for (const kind of ["added", "modified", "deleted"] as const) {
        const ranges = marks.filter((m) => m.kind === kind && m.start <= editor.document.lineCount)
          .map((m) => new vscode.Range(m.start - 1, 0, Math.min(m.end, editor.document.lineCount) - 1, 0));
        editor.setDecorations(this.types[kind], ranges);
      }
    }
  }

  go(direction: 1 | -1) {
    const root = vscode.workspace.workspaceFolders?.[0]?.uri.path ?? "";
    const editor = vscode.window.activeTextEditor;
    const relative = editor?.document.uri.path.startsWith(root + "/") ? editor.document.uri.path.slice(root.length + 1) : undefined;
    const here = editor && relative !== undefined ? { path: relative, line: editor.selection.active.line + 1 } : undefined;
    const target = nextMark(markPositions(this.files), here, direction);
    if (target) void openFile(`${root}/${target.path}`, target.line);
  }

  dispose() {
    for (const type of Object.values(this.types)) type.dispose();
  }
}

interface GitChange { uri: vscode.Uri }
interface GitRepository { rootUri: vscode.Uri; state: { workingTreeChanges: GitChange[]; indexChanges: GitChange[]; untrackedChanges?: GitChange[]; onDidChange: vscode.Event<void> } }
interface GitApi { repositories: GitRepository[]; toGitUri(uri: vscode.Uri, ref: string): vscode.Uri; onDidOpenRepository: vscode.Event<GitRepository> }

/** Claude's files from Glance Studio: a "C" badge in the Explorer and Source Control, and the "Claude's Changes"
 *  view of those still uncommitted, which opens VS Code's diff against HEAD. `glance.markClaudeChanges` turns it off. */
class ClaudeFiles implements vscode.Disposable, vscode.FileDecorationProvider, vscode.TreeDataProvider<string> {
  private paths: string[] = [];
  private git?: GitApi;
  private readonly decorations = new vscode.EventEmitter<vscode.Uri[] | undefined>();
  private readonly tree = new vscode.EventEmitter<void>();
  readonly onDidChangeFileDecorations = this.decorations.event;
  readonly onDidChangeTreeData = this.tree.event;
  private readonly disposables: vscode.Disposable[] = [];

  constructor() {
    this.disposables.push(
      vscode.window.registerFileDecorationProvider(this),
      vscode.window.registerTreeDataProvider("glance.claudeChanges", this),
      vscode.workspace.onDidChangeConfiguration((e) => { if (e.affectsConfiguration("glance.markClaudeChanges")) this.refresh(); }),
    );
    void this.connectGit();
  }

  private get on(): boolean { return vscode.workspace.getConfiguration("glance").get<boolean>("markClaudeChanges", true); }
  private get root(): vscode.Uri | undefined { return vscode.workspace.workspaceFolders?.[0]?.uri; }
  private relative(uri: vscode.Uri): string | undefined {
    const root = this.root?.path;
    return root && uri.path.startsWith(root + "/") ? uri.path.slice(root.length + 1) : undefined;
  }

  private async connectGit() {
    const extension = vscode.extensions.getExtension<{ getAPI(version: 1): GitApi }>("vscode.git");
    if (!extension) return;
    const api = (extension.isActive ? extension.exports : await extension.activate()).getAPI(1);
    this.git = api;
    const watch = (repo: GitRepository) => this.disposables.push(repo.state.onDidChange(() => this.tree.fire()));
    api.repositories.forEach(watch);
    this.disposables.push(api.onDidOpenRepository(watch));
    this.tree.fire();
  }

  set(paths: string[]) {
    this.paths = paths;
    this.refresh();
  }

  private refresh() {
    this.decorations.fire(undefined);
    this.tree.fire();
  }

  provideFileDecoration(uri: vscode.Uri): vscode.FileDecoration | undefined {
    const path = this.relative(uri);
    if (!this.on || path === undefined || !this.paths.includes(path)) return undefined;
    return new vscode.FileDecoration("C", "Changed by Claude", new vscode.ThemeColor("charts.orange"));
  }

  getChildren(element?: string): string[] {
    if (element || !this.on) return [];
    const repo = this.git?.repositories[0];
    const changes = repo ? [...repo.state.workingTreeChanges, ...repo.state.indexChanges, ...(repo.state.untrackedChanges ?? [])] : [];
    return stillChanged(this.paths, changes.map((c) => this.relative(c.uri)).filter((p): p is string => p !== undefined));
  }

  getTreeItem(path: string): vscode.TreeItem {
    const root = this.root!;
    const uri = vscode.Uri.joinPath(root, path);
    const item = new vscode.TreeItem(uri, vscode.TreeItemCollapsibleState.None);
    item.description = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
    const head = this.git?.toGitUri(uri, "HEAD");
    item.command = head
      ? { title: "Open Changes", command: "vscode.diff", arguments: [head, uri, `${path} (HEAD ↔ Working Tree)`] }
      : { title: "Open", command: "vscode.open", arguments: [uri] };
    return item;
  }

  dispose() {
    for (const d of this.disposables) d.dispose();
    this.decorations.dispose();
    this.tree.dispose();
  }
}
