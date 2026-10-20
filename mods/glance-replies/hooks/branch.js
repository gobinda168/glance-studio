// The branch Claude is working on: read with git in the session's current folder (which follows `cd` and worktree
// moves), drawn at the start of the hint line under the prompt.

// Prints the branch (or the short commit when HEAD is detached) and, in a linked worktree, the worktree's folder name
// on a second line. Exits non-zero outside a repository.
export const BRANCH_SCRIPT = `cd "$1" 2>/dev/null || exit 1
b=$(git symbolic-ref --short -q HEAD) || b=$(git rev-parse --short HEAD 2>/dev/null) || exit 1
dir=$(git rev-parse --absolute-git-dir 2>/dev/null)
common=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
wt=
[ -n "$dir" ] && [ -n "$common" ] && [ "$(cd "$dir" && pwd -P)" != "$common" ] && wt=$(basename "$(git rev-parse --show-toplevel)")
printf '%s\\n%s\\n' "$b" "$wt"`

/** `{ name, worktree }` from the script's output, or null when it found no repository. */
export function parseBranch(exitCode, stdout) {
  if (exitCode !== 0) return null
  const [name = '', worktree = ''] = stdout.split('\n').map((line) => line.trim())
  return name === '' ? null : { name, worktree: worktree === '' ? null : worktree }
}

export function sameBranch(a, b) {
  return (a?.name ?? null) === (b?.name ?? null) && (a?.worktree ?? null) === (b?.worktree ?? null)
}

/** The branch as a coral chip, then the worktree it's in (when it's one), before the engine's own hint line. */
export function drawBranch({ Box, Text }, branch, theirs) {
  const children = [
    Text({ backgroundColor: 'claude', color: 'inverseText', bold: true, wrap: 'truncate-end', children: [` ⎇ ${branch.name} `] }),
  ]
  if (branch.worktree) children.push(Text({ color: 'claude', wrap: 'truncate-end', children: [` worktree ${branch.worktree}`] }))
  children.push(Text({ children: ['  '] }))
  if (theirs) children.push(Box({ flexShrink: 1, children: [theirs] }))
  return Box({ flexDirection: 'row', children })
}
