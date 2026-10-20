# Claude Code dialog captures

Captured by `scripts/capture-prompt-screens.py` (140x50 pty, pyte render, trailing spaces stripped) from
`claude --version` = `2.1.292 (Claude Code)`, Opus 5.5, `--permission-mode default` (plan scenario: `--permission-mode plan`).
All 13 scenarios opened their dialog (no `.timeout.txt`). Fixtures are never edited; constants and parsers follow these notes.

## Facts common to every capture

- Line 1 of every file is a stray `u` (terminal artifact from a keyboard-protocol query). Ignore it.
- Selected-row marker: `❯` (U+276F), then one space, then `N.`: ` ❯ 1. Yes`. Unselected rows have a space in the marker's column
  and then the number: `   2. No`. Only the selected row has a marker.
- Non-marker rows are indented to the same column as the marked ones (marker column replaced by a space).
- Rule characters: dialog top rule is `─` (U+2500) full width (140 columns, or indented 2 in plan). Inside permission dialogs the
  command / diff is framed by `╌` (U+254C) rules. In question dialogs a `─` rule is drawn BETWEEN the last answer option and
  the final "Chat about this" option.
- NBSP (U+00A0) appears only in non-dialog chrome (`❯ ` idle prompt, `⎿ ` result glyph); none inside the dialogs' numbered rows.
- Header/tab glyphs (question dialogs): `☐` U+2610 unanswered, `☒` U+2612 answered, `✔` U+2714 Submit tab, `←` `→` U+2190/2192.
- Multi-select option boxes: `[ ]` unticked, `[✔]` ticked, where `✔` is U+2714 (NOT U+2713 `✓`).
- Option numbers: `N.` then a single space then the label. Numbers run 1..N consecutively, including the free-text and
  "Chat about this" entries, even across the `─` rule.
- Wrapped labels: the continuation line has no number or marker and starts at the label's column (6 spaces in permission-bash, where the row is `   2. Yes...`).
- Descriptions (question dialogs): on the line(s) below the label, indented 5 spaces (single-select) or 9 spaces (multi-select,
  aligned past the `[ ] ` box). Never fewer than 4.

## Per fixture

### idle.txt
No dialog. Prompt `❯ Try "fix typecheck errors"` (NBSP after ❯) between two full-width `─` rules, `⏸ manual mode on` footer.
No numbered rows, no dialog footer.

### working.txt
No dialog. Spinner line `✻ Razzmatazzing… (4s · ↓ 138 tokens · thought for 2s)`, empty prompt `❯`, `⏸ manual mode on`. No dialog footer.

### permission-bash.txt (footer line 26)
- Footer: ` Esc to cancel · Tab to amend` (1 leading space).
- Layout (1-space indent everywhere): `─` rule, ` Bash command`, a ` Tip: auto mode handles these prompts for you — choose "switch to auto mode" below`
  line, description line ` Write probe text to file`, `╌` rule, command ` echo glance-probe > probe.txt`, `╌` rule,
  question ` Do you want to proceed?` (line directly above option 1, no blank), options, blank, footer.
- Options:
  1. ` ❯ 1. Yes`
  2. `   2. Yes, and always allow access to` + continuation line `      /private/tmp/.../capture-work from this project` (6 spaces) — wrapped label, the path is label continuation, not a note.
  3. `   3. Yes, and switch to auto mode · auto mode handles these prompts for you`
  4. `   4. No`
- Selected: option 1 (index 0).

### permission-bash-after-esc.txt
No dialog. `Ran 1 shell command` / `⎿  Interrupted · What should Claude do instead?`, empty prompt. No dialog footer.

### permission-edit.txt (footer line 25)
- Footer: ` Esc to cancel · Tab to amend`.
- ` Edit file`, ` notes.txt`, `╌` rule, diff (` 1 -hello`, ` 1 +goodbye`), `╌` rule, question ` Do you want to make this edit to notes.txt?`
- Options: `1. Yes` (selected), `2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session (shift+tab)` (one line, not wrapped), `3. No`.

### question-single.txt / question-single-down.txt (footer line 24)
- Footer: `Enter to select · ↑/↓ to navigate · Esc to cancel` (no leading space; `↑/↓` are U+2191/U+2193).
- Header row: ` ☐ Color` (1-space indent, tab glyph + header text; single question has no `←`/`→`/Submit).
- Question line: `Which color?` at column 0, blank line above and below it (option 1 is NOT directly under it; one blank between).
- Options (marker column then number):
  `❯ 1. red` / `     A warm, bold color` (5-space description); `  2. green` / `     A fresh, natural color`; `  3. blue` / `     A cool, calm color`;
  `  4. Type something.` (free-text, trailing period, no description); `─` rule; `  5. Chat about this`; blank; footer.
  Note: these rows start at column 0 (the marker is the first character, not preceded by a space), unlike permission dialogs.
- Free-text entry label: exactly `Type something.` (option 4). `Chat about this` (option 5) is a separate entry, not free-text.
- Down (question-single-down): the marker moved to `❯ 2. green`; every label and description otherwise identical.
- No Submit/Next entry in the single-question dialog.

### question-multi-1.txt (footer line 22) / question-multi-2.txt
- Footer: `Enter to select · Tab/Arrow keys to navigate · Esc to cancel` (differs from single: `Tab/Arrow keys`, not `↑/↓`).
- Tab row at line 10: `←  ☐ Color  ☐ Size  ✔ Submit  →` (column 0, `←` then two spaces; items separated by two spaces).
- Question `Which color?`; options `❯ 1. red` (+ `     Red`), `  2. green` (+ `     Green`), `  3. Type something.`, `─` rule, `  4. Chat about this`.
- Enter (on `1. red`) moved to question 2: tab row became `←  ☒ Color  ☐ Size  ✔ Submit  →`, question `Which size?`, options `1. small` (+`Small`), `2. large` (+`Large`), `3. Type something.`, `4. Chat about this`; the marker reset to option 1.
  So Enter on a single-select answer records it and advances to the next question tab.

### question-multi-submit.txt (the screen after the second Enter)
- NO footer line at all (file ends right after option 2). No `Esc to cancel`, no `Enter to select`.
- Tab row: `←  ☒ Color  ☒ Size  ✔ Submit  →`.
- `Review your answers`, then ` ● Which color?` / `   → red` / ` ● Which size?` / `   → small`, then `Ready to submit your answers?` (blank line between it and the options).
- Options: `❯ 1. Submit answers`, `  2. Cancel`.
- Selected: option 1.

### question-multiselect.txt / question-multiselect-space.txt (footer line 24)
- Footer: `Enter to select · ↑/↓ to navigate · Esc to cancel`.
- Tab row: `←  ☐ Fruits  ✔ Submit  →`.
- Options:
  `❯ 1. [ ] apple` / `         Apple` (9-space description); `  2. [ ] banana` / `Banana`; `  3. [ ] cherry` / `Cherry`;
  `  4. [ ] Type something` (free-text; here NO trailing period, and it carries a `[ ]` box) followed by an UNNUMBERED row `     Submit` (5 spaces) — this is the Submit entry; then the `─` rule; `  5. Chat about this`.
- Space (question-multiselect-space): ticked option 1: `❯ 1. [✔] apple`, tab row header `☐ Fruits` became `☒ Fruits`. The marker did not move. Space is the toggle key.
- A Submit entry exists (`     Submit`, unnumbered, under option 4 at indent 5, and the `✔ Submit` tab). It was not navigated to in the capture, so how to focus it (Down from option 4 or Tab/Right) is unverified.

### plan.txt (footer line 50, the last row of the viewport)
- NO `Esc to cancel` / `Enter to select` / `to navigate` anywhere. The only hint line is the last row:
  `  ctrl+g to edit in Vim · ~/.claude/plans/plan-adding-the-line-refactored-turing.md` (2-space indent; the filename varies).
- The viewport shows the plan body between two `╌` rules (indented 2, after a `─` rule and ` Ready to code?`), a second `─` rule, then
  the question `  Claude has written up a plan and is ready to execute. Would you like to proceed?` (indent 2, blank line below it).
- Options (3-space marker column then number; indent 3 for the marker/number):
  1. `   ❯ 1. Yes, and use auto mode`
  2. `     2. Yes, manually approve edits`
  3. `     3. Tell Claude what to change` + note line `        shift+tab to approve with this feedback` (indent 7)
  Selected: option 1. There is no "No" and no "Keep planning" option in 2.1.292; the decline path is `Tell Claude what to change`.
- Between the last option and the footer: one blank line (line 49).
- The plan body above contains numbered text (`  1. Append world ...`, `  2. Check the result ...`), 20 lines before the options; not a dialog by itself.

## Implications for later tasks

`PromptScreen.footers` (anchors; must be matched against the LAST line that contains one) — add to the defaults:
`"Esc to cancel"`, `"Enter to select"`, `"to navigate"` already match every question/permission capture. Missing: plan and the review screen.
Add `"ctrl+g to edit in Vim"` (plan) and anchor the review screen on `"Ready to submit your answers?"` (or: when no footer is found,
fall back to the last numbered row of the screen, requiring the row sequence to reach 1 and one marked row). Both lack all current footers,
so the plan's parser as written returns nil for `plan` and `question-multi-submit`.

`PromptScreen.markers`: `❯` (U+276F) is the only one seen; keep `›` and `>` as harmless extras.

`PromptScreen.checkboxes`: real glyphs are `[ ]` (false) and `[✔]` (true, `✔` = U+2714). The default list has `[✓]` (U+2713), which does NOT
match; add `("[✔]", true)`. The bare `✔` entry is fine as a fallback; `☐`/`☒` are tab-row glyphs, not option boxes.

`PromptScreen.isFreeText`: `Type something.` (single-select, with a trailing period) and `Type something` (multi-select, after the `[ ]` box
is stripped). `hasPrefix("type something")` after lowercasing covers both. `Chat about this` is not free text (it opens a chat; do not
treat as a typed answer; consider exposing it separately).

`PromptKeys.toggleKey`: Space (`" "`). Verified in question-multiselect-space (box ticked, marker stays).

`PromptKeys.isSubmit`: the review screen's label is `Submit answers` (option 1, followed by `2. Cancel`); the multi-select list also
has an unnumbered `Submit` row. A safe predicate: `label == "Submit answers"` (numbered) plus the multiselect's `Submit` row if it is handled.
Option 1 of the review screen is already selected, so Enter submits.

`PromptKeys.isKeepPlanning`: there is no "Keep planning" label in this version. The plan's decline option is `Tell Claude what to change`
(option 3). Match `lower.hasPrefix("tell claude what to change")` (keep `"keep planning"` and `hasPrefix("no")` as legacy fallbacks).
The approve options are `Yes, and use auto mode` and `Yes, manually approve edits`.

What the parser in task 3 would get wrong on these screens:
1. `plan.txt` and `question-multi-submit.txt` return nil (no recognised footer; see above).
2. Permission dialogs: `detail` stops at the first `╌` rule because `isRule` includes `╌`, so the command/diff
   (between the two `╌` rules) is never included (`permission-bash` test expecting `echo glance-probe > probe.txt` in `detail` fails;
   same for the edit diff). The detail walk should treat `╌` as a separator to skip (not stop) and stop only at `─` (U+2500), or `isRule` for
   the question-walk should not stop on `╌` for the detail search.
3. Question dialogs: a `─` rule sits between the last answer option and `Chat about this`. The upward walk skips rule lines, so it works,
   but `Chat about this` is a numbered option (not part of the answer list proper) and `labels` includes it.
4. Question dialogs: the question line is NOT directly above option 1; one blank line separates them (the parser skips blanks, so it is OK).
   The tab row (` ☐ Color`, `←  ☐ Color  ☐ Size  ✔ Submit  →`) lands in `detail`; the answered/unanswered state is there, and a multi-question
   dialog's current question is the one under the tab row.
5. Multi-select: an unnumbered `     Submit` row (indent 5) follows option 4; the parser attaches it as option 4's `note` ("Submit"). Decide whether to model
   it as its own entry. The `[ ]` box is also present on `Type something` (box strip leaves `Type something`, fine).
6. Notes indentation is always >= 5 (single/multi 5 or 9, plan note 7, bash label continuation 6), so the `>= 4` threshold holds. The bash
   wrapped-label continuation is therefore folded into `note` ("/private/tmp/... from this project") rather than the label; the synthetic test expects the same.
7. Plan: the option rows are indented 3 (` ❯` at column 3); the regex tolerates that. The plan body above the dialog contains numbered lines
   ("1. Append world...", "2. Check the result...") but the walk stops at option 1, and the `─` rule at line 42 bounds `detail`, so detail is empty.
8. Question dialogs start at column 0 for the marker row (`❯ 1. red`), permission dialogs at column 1; both parse.
9. Not-dialog screens (idle, working, after-esc) have no footer, so `nil` is already correct. The stray `u` on line 1 and NBSP chrome are harmless.
