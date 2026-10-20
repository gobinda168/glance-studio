// Background shells, as plain data and plain words (the Shells pane's model). Claude Code's own "Shell details" view
// is not something a mod can draw over (no ui.render site for it), so this mod keeps its own record of every Bash call
// that runs in the background and tells it in a way a person can read: a title, a status, a short command.

import { fit } from './format.js'

export function newShells() {
  return { list: [], selected: null, expanded: false, copied: false, stopping: new Set(), notices: new Map() }
}

// A Bash call that went to the background: from `run_in_background`, or (Ctrl+B, a timeout) from the result's id.
export function shellStarted(s, call, at) {
  if (call.tool !== 'Bash' || call.agentId) return
  if (call.run_in_background !== true) return
  if (s.list.some((x) => x.callId === call.tool_use_id)) return
  s.list.push({
    id: null,
    callId: call.tool_use_id,
    description: str(call.description),
    command: str(call.command),
    startedAt: at,
    endedAt: null,
    status: 'running',
    outputPath: null,
  })
}

// The Bash result carries the id of the background task, and often where its output goes.
export function shellResult(s, call, result, at) {
  if (call.tool !== 'Bash') return
  const r = result?.result
  const id = typeof r?.backgroundTaskId === 'string' ? r.backgroundTaskId : null
  if (!id) return
  let sh = s.list.find((x) => x.callId === call.tool_use_id)
  if (!sh) {
    // Backgrounded by Ctrl+B or by its timeout: the call did not ask, the result tells.
    sh = { id, callId: call.tool_use_id, description: str(call.description), command: str(call.command), startedAt: at, endedAt: null, status: 'running', outputPath: null }
    s.list.push(sh)
  }
  sh.id = id
  sh.outputPath = outputPathIn(`${str(r.stdout)}\n${str(r.stderr)}`) ?? sh.outputPath
}

// What a Stop event knows: the tasks still in flight. A shell we hold that is not among them has ended.
export function shellsInFlight(s, tasks, at) {
  if (!Array.isArray(tasks)) return
  const live = new Set(tasks.filter((t) => t?.type === 'shell' || t?.command !== undefined).map((t) => t.id))
  for (const sh of s.list) if (sh.endedAt === null && sh.id && !live.has(sh.id)) shellEnded(sh, 'done', at)
}

// A task notification row ("completed", "failed", "killed") names the shell by id.
export function shellNotified(s, task, at) {
  if (!task?.id) return
  const sh = s.list.find((x) => x.id === task.id)
  if (!sh || sh.endedAt !== null) return
  shellEnded(sh, task.status === 'failed' ? 'failed' : task.status === 'killed' ? 'stopped' : 'done', at)
}

export function shellEnded(sh, status, at) {
  sh.status = status
  sh.endedAt = at
}

export function running(s) {
  return s.list.filter((x) => x.endedAt === null)
}

// Running first (newest first), then the finished ones, newest first.
export function ordered(s) {
  const by = (a, b) => b.startedAt - a.startedAt
  return [...s.list.filter((x) => x.endedAt === null).sort(by), ...s.list.filter((x) => x.endedAt !== null).sort(by)]
}

export function selectedShell(s) {
  const all = ordered(s)
  return all.find((x) => x.callId === s.selected) ?? all[0] ?? null
}

// ---- words -----------------------------------------------------------------------------------------------------

// The title: what Claude said the shell is for, else what the command is: "staging deployment".
export function titleOf(sh) {
  const d = sh.description.trim()
  if (d) return d
  const parts = tidy(sh.command).split(/\s+/).filter(Boolean)
  if (parts.length === 0) return 'Shell command'
  const words = [parts[0]]
  for (const p of parts.slice(1)) {
    if (p.startsWith('-') || p.startsWith('"') || p.startsWith("'") || /\d/.test(p) || words.length >= 2) break
    words.push(p)
  }
  return words.join(' ')
}

// The command without the plumbing: no `cd x &&`, no `PATH=… &&` / `VAR=… &&`, paths down to their last part, long
// hashes down to their first seven characters. The full text stays one press away.
export function shortCommand(command) {
  return tidy(command)
}

function tidy(command) {
  let c = command.trim().replace(/\s*\n\s*/g, ' ; ')
  // Leading `cd dir &&` and `NAME=value &&` setup.
  for (;;) {
    const next = c.replace(/^(?:cd\s+\S+|[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)(?:\s+[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*))*)\s*(?:&&|;)\s*/, '')
    if (next === c) break
    c = next
  }
  // A leading `NAME=value` prefix on the command itself (`PATH="$D:$PATH" tool args`).
  c = c.replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+)+/, '')
  return c
    .split(/(\s+)/)
    .map((tok) => shortToken(tok))
    .join('')
}

function shortToken(tok) {
  if (/^[0-9a-f]{12,}$/i.test(tok)) return `${tok.slice(0, 7)}…`
  if (/^~?\/.*\//.test(tok) && !tok.includes(' ')) {
    const parts = tok.replace(/\/+$/, '').split('/')
    return parts[parts.length - 1] || tok
  }
  return tok
}

// "running", "finished", "failed", "stopped": the status as a sentence would say it.
export function statusWord(sh) {
  return { running: 'Running', done: 'Finished', failed: 'Failed', stopped: 'Stopped' }[sh.status] ?? sh.status
}

export function statusColor(sh) {
  return { running: 'planMode', done: 'success', failed: 'error', stopped: 'inactive' }[sh.status] ?? 'inactive'
}

export function elapsedOf(sh, at) {
  return (sh.endedAt ?? at) - sh.startedAt
}

export function summaryLine(s) {
  const n = running(s).length
  return n === 0 ? '' : `${n} shell${n === 1 ? '' : 's'} running`
}

// ---- output ----------------------------------------------------------------------------------------------------

export function outputPathIn(text) {
  const m = /(\/[^\s"'`]*\/tasks\/[A-Za-z0-9_-]+\.output)/.exec(text) ?? /(\/[^\s"'`]+\.output)\b/.exec(text)
  return m ? m[1] : null
}

// Where Claude Code keeps a background shell's output: `<session dir>/tasks/<id>.output`, the session dir being the
// parent of the `scratchpad` named in the command (or in the output notice). Best effort: null when nothing tells.
export function guessOutputPath(sh) {
  if (sh.outputPath) return sh.outputPath
  if (!sh.id) return null
  const m = /(\/[^\s"'`]*?)\/scratchpad\b/.exec(sh.command)
  return m ? `${m[1]}/tasks/${sh.id}.output` : null
}

// The last `rows` lines of the output, each at most `width` columns, ignoring colour codes and a trailing blank.
export function tail(text, rows, width) {
  const clean = text.replace(/\u001b\[[0-9;?]*[A-Za-z]/g, '').replace(/\r(?!\n)/g, '\n').replace(/\s+$/, '')
  if (!clean) return []
  return clean.split('\n').slice(-rows).map((l) => fit(l, width))
}

function str(v) {
  return typeof v === 'string' ? v : ''
}
