# glance-replies

A Claude Code mod (Claude Code 2.1.287 or later) that draws Claude's replies in Glance Studio's terminal with what
Claude Code's own renderer leaves raw:

| In the reply | Drawn as |
|---|---|
| `#` … `######` headings | coral bold (levels 1–2, a rule under level 1), bold below that |
| `-` / `*` / `1.` lists | coral `•` `◦` `▪` by depth, coloured numbers; a list holding a code fence stays Claude Code's |
| `> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]` | a callout with a coloured bar and label (theme colours) |
| `- [ ]` / `- [x]` | `○` / green `✓` rows, done ones dim |
| a closed ` ```mermaid ` fence | the diagram as box art (beautiful-mermaid's ASCII renderer), or the code if it can't be read |
| a closed code fence | Claude Code's highlighted code under a `lang  ⧉ Copy` row; a command (a `!` line, or a bash / sh / shell / zsh fence) also gets `▶ Run` |
| a `>` quote (often a drafted message) | a quote bar with `⧉ Copy` under it |
| `---` after a blank line | a rule |

Everything else (prose, lists, tables, code) stays Claude Code's drawing, and a reply with none of the above isn't
touched. Only the interactive terminal draws it; `claude -p` (Razor Chat, Inline Ask) is unchanged.

**Run** (`commands.js`): `▶ Run` runs the command through the login shell in the session's folder (a `!` is dropped; the
mod can't type into Claude Code's prompt), shows the end of its output in a Run pane (Copy output, Send to chat) and
toasts the result. A multi-line or destructive command (`rm -rf`, `sudo`, `curl … | sh`, forced git) asks first: the
button reads `Run? press again`. The output stays out of the conversation unless sent there.

**File links** (`links.js`): a markdown link or a path-like code span that names an existing file (relative to the
session's folder, absolute, or `~`) becomes a `file://` link with its line (`#L12`, `:12` → `file:///…:12`). Studio
opens those in Razor on ⌘-click (`GlanceEditorHost`). Without the mod, Studio still opens a relative link on its own,
`#L12` included; an absolute-path link Claude Code draws as plain text only the mod fixes.

**Pasted images** (`images.js`): Claude Code shows only `[Image #N]` and tells a mod nothing at the paste, so:
- *while writing*: twice a second the mod reads the draft; a new `[Image #N]` gets a thumbnail above the prompt, from
  the file just dropped on Studio's terminal (Studio writes `~/Library/Caches/Glance Studio/image-drops.json`), else
  the clipboard (a copied file, a pasted path, or image data: what Ctrl+V gives Claude Code);
- *once sent*: the message's own image bytes (or the history's, on a resumed session) as a thumbnail under it.
Thumbnails are PNGs made with `sips` in `$TMPDIR/glance-replies-<session>/` and drawn with `Image` (kitty graphics in
Ghostty; the `[Image #N]` alt text in a terminal without them). The `[Image #N] ↗` caption under one is a button that
shows the full picture in Quick Look over Studio's window, without switching apps: the mod posts
`{"path": …}` to Studio's local `POST /preview` (127.0.0.1:47823, `GLANCE_PORT`), else runs `qlmanage -p`. ⌘-clicking a
reply's link to a picture, PDF or document opens the same panel (`FilePreview` decides editor or Quick Look).

**Ask about a selection** (fullscreen mode, `CLAUDE_CODE_NO_FLICKER=1` or `/config`): select text in a reply and
`✦ Ask about selection` appears above the prompt (the mod polls `$.ui.selection()`; nothing announces one). It, or
`/ask [question]`, opens the Ask pane: the selection, then each question and its answer (`$.model.complete` with the
session's model, the reply the selection is from as context, earlier answers in the thread), a field for follow-ups,
`Copy answer`, `Send to chat` (the quoted selection and last question into the prompt), `History` and `Close`.
**History** lists this conversation's earlier asks, newest first (first question, the passage, how many questions,
when); a row, or its digit, opens that thread again to follow up, and selecting a passage asked about before reopens
its thread. `/ask` with nothing selected opens the history. Threads are kept in the mod's store per session (the last
30 asks of the last 10 conversations), so they survive a restart and `/resume`. `/copy`
(Claude Code's own) copies a whole reply. Nothing goes into the
conversation unless sent there.

**How Studio loads it:** `scripts/build-terminal.sh` copies `mods/` into the app's Resources; at launch
`ClaudeMods.export` (GlanceCore) copies them to `~/Library/Caches/Glance Studio/mods` (Claude Code writes type files
into a loaded mod, which would break the app's signature) and sets `CLAUDE_CODE_PLUGIN_DIRS` for every shell Studio
starts. `~/.claude` and other terminals never see it.

**Develop:** `claude --plugin-dir mods/glance-replies` (hot-reloads on save), `claude plugin test` and
`claude plugin validate .` in this directory. `vendor.sh` rebuilds `hooks/vendor/mermaid-ascii.js`.

**Known limits:** in left-to-right flowcharts, beautiful-mermaid leaves a gap in a labelled edge leaving a `{decision}`
node (top-down is fine). Diagram types the ASCII renderer doesn't know are drawn as code.
