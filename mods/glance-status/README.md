# glance-status

A Claude Code mod (Claude Code 2.1.287 or later). `/progress` opens the **Status** pane beside the conversation: what
Claude is doing now, where it is in its plan, and what the session has cost. Esc closes it. Nothing shows until you
ask, apart from one small chip on the hint line under the prompt (`○ Status · $0.03` when idle; `● Editing
TabGroups.swift · 2/3 · 41%` while Claude works). Pressing the chip opens the pane too.

| Section | Shows |
|---|---|
| header | the folder and model, and a WORKING (teal) / NEEDS YOU (amber) / IDLE chip |
| NOW | the current step ("Editing TabGroups.swift", "Running the tests", "Thinking"), the turn's time, a teal scan line while Claude works, how many helper agents are running |
| PLAN | only when Claude made a todo list: a segmented bar with n/m, the current item and the next two |
| RECENT | the last three steps, newest first, as `Tool  target` |
| USAGE | one line: context used, $ cost, rate-limit windows (amber from 80%, red from 95%). A **Details** button opens the context window, tokens (in / out), cache reads and last turn |

The mod keeps track all session, so opening the pane mid-turn shows the whole turn. It only draws while the pane is
open. It only observes: every hook passes on what the hooks beneath returned.

## Shells

Claude Code's own "Shell details" view (status, raw command, "No output available") can't be replaced by a mod: it has
no draw site a mod can reach. So this mod keeps its own record of every Bash call that runs in the background and
shows it in plain words. `/shells`, the `● 2 shells` chip under the prompt, or **Open Shells** in the Status pane opens
the **Shells** pane:

- a title per shell (the description Claude gave it, else the command's first words), a status dot and the time
- the command without the plumbing (`cd … &&`, `PATH=… &&`, long hashes cut to seven characters); **Show full command**
  and **Copy** keep the whole text one press away
- the last lines of the shell's output, refreshed each second, or "Nothing printed yet" while it is quiet
- **Stop this shell** (the TaskStop tool)

Output is read from the shell's `tasks/<id>.output` file, found from the Bash result or from the scratchpad path in the
command. When neither says, the pane says it can't read the output rather than showing nothing.

**How Studio loads it:** as glance-replies: `scripts/build-terminal.sh` copies `mods/` into the app, `ClaudeMods.export`
copies them to `~/Library/Caches/Glance Studio/mods` and sets `CLAUDE_CODE_PLUGIN_DIRS` for Studio's shells.

**Develop:** `claude --plugin-dir mods/glance-status` (hot-reloads on save), `claude plugin test` and
`claude plugin validate .` in this directory. Spec: `docs/superpowers/specs/2026-10-11-claude-status-design.md`.

**Known limits:**
- NEEDS YOU is set when a permission prompt is asked and cleared when that call returns. Claude Code has no event for
  the answer, so after you approve, NEEDS YOU stays on while the approved tool runs (a `sleep 6` showed NEEDS YOU for its
  whole 6 s), then drops to WORKING.
- No context % or $ until Claude Code first reports usage (about the first response of the first turn): the USAGE line leaves them out until then. Tokens count
  from when this `claude` started; `$` is the session's own ledger.
- The plan comes from TodoWrite or the Task tools (TaskCreate/TaskUpdate). Interactive Claude Code 2.1.292 offers the
  Task tools (TodoWrite is not available there), and a model that makes no list leaves out the PLAN section. A resumed
  session's plan is rebuilt from its latest TodoWrite only (not from Task tools).
- Task steps all read "Updating the plan" in RECENT; the plan itself shows which task changed.
- The pane is a Claude Code pane: beside the conversation from about 140 columns, and docked below it on narrower
  windows, where it is about 14 rows tall and scrolls (the Details and Close rows sit below the fold; Esc or
  the ✕ still close it).
