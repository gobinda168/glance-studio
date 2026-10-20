// Everything the Status pane shows, kept as plain data all session (the pane may open at any moment): the plan,
// this turn's steps, the agents still running, the session's tokens and its last measurement. Pure functions over
// that state, so the tests drive it without a session.

import { ago, words } from './format.js'
import { describeCall, phrase } from './phrases.js'

export function newTracker() {
  return {
    plan: [],
    turn: null,
    lastTurn: null,
    agents: new Map(),
    waiting: null,
    tokens: { input: 0, output: 0, cacheWrite: 0, cacheRead: 0 },
    turnTokens: [],
    measure: { context: null, rateLimits: [], cost: null },
  }
}

export function startTurn(t, turnId, at) {
  t.turn = { id: turnId, startedAt: at, steps: [] }
  t.waiting = null
}

// A main-loop call: a step of the turn (and maybe a plan change or an agent). A subagent's own calls (`agentId`) only
// show as its agent running.
export function startStep(t, call, at, cwd) {
  if (call.agentId) return
  if (call.tool === 'TodoWrite' && Array.isArray(call.todos)) t.plan = todosToPlan(call.todos)
  if (call.tool === 'TaskUpdate') updateTask(t, call)
  if (call.tool === 'Agent') {
    t.agents.set(call.tool_use_id, { type: str(call.subagent_type) || 'agent', description: str(call.description), startedAt: at })
  }
  if (!t.turn) startTurn(t, '', at)
  t.turn.steps.push({ id: call.tool_use_id, ...describeCall(call, cwd), startedAt: at, endedAt: null, failed: false })
}

export function endStep(t, call, result, at) {
  if (t.waiting === call.tool_use_id) t.waiting = null
  if (call.agentId) return
  const failed = Boolean(result?.deny) || result?.isError === true
  if (call.tool === 'TaskCreate' && !failed) {
    const id = result?.result?.task?.id
    if (typeof id === 'string') {
      const content = str(call.subject)
      t.plan.push({ id, content, activeForm: str(call.activeForm) || content, status: 'pending' })
    }
  }
  t.agents.delete(call.tool_use_id)
  const step = t.turn?.steps.find((s) => s.id === call.tool_use_id && s.endedAt === null)
  if (!step) return
  step.endedAt = at
  step.failed = failed
}

export function waitFor(t, toolUseId) {
  t.waiting = toolUseId ?? ''
}

// The end of a turn. A subagent's (`agentId`) adds its tokens to the session and nothing else.
export function completeTurn(t, e, at) {
  const u = e.usage
  const input = u?.input_tokens ?? 0
  const output = u?.output_tokens ?? 0
  const cacheWrite = u?.cache_creation_input_tokens ?? 0
  const cacheRead = u?.cache_read_input_tokens ?? 0
  const turnTotal = input + cacheWrite + output
  t.tokens.input += input
  t.tokens.output += output
  t.tokens.cacheWrite += cacheWrite
  t.tokens.cacheRead += cacheRead
  if (e.agentId) return
  const steps = t.turn?.steps ?? []
  for (const s of steps) if (s.endedAt === null) s.endedAt = at
  t.turnTokens.push(turnTotal)
  t.lastTurn = {
    steps,
    startedAt: t.turn?.startedAt ?? at - e.durationMs,
    durationMs: e.durationMs,
    tokens: turnTotal,
    endedAt: at,
    isAborted: e.isAborted === true,
  }
  t.turn = null
  t.waiting = null
}

export function setMeasure(t, m) {
  t.measure = { context: m.context ?? null, rateLimits: m.rateLimits ?? [], cost: m.cost ?? null }
}

// A resumed session's plan: the latest TodoWrite in the transcript (`$.session.messages({ as: 'api' })`).
export function planFromMessages(messages) {
  for (let i = messages.length - 1; i >= 0; i--) {
    const content = messages[i]?.content
    if (!Array.isArray(content)) continue
    for (let j = content.length - 1; j >= 0; j--) {
      const block = content[j]
      if (block?.type === 'tool_use' && block.name === 'TodoWrite' && Array.isArray(block.input?.todos)) return todosToPlan(block.input.todos)
    }
  }
  return []
}

export function nowView(t, at) {
  if (t.waiting !== null) {
    const step = t.turn?.steps.find((s) => s.id === t.waiting)
    return { state: 'waiting', phrase: step ? `Waiting for you · ${phrase(step)}` : 'Waiting for you', isThinking: false, elapsedMs: t.turn ? at - t.turn.startedAt : null }
  }
  if (t.turn) {
    const running = [...t.turn.steps].reverse().find((s) => s.endedAt === null)
    return { state: 'working', phrase: running ? phrase(running) : 'Thinking', isThinking: !running, elapsedMs: at - t.turn.startedAt }
  }
  if (!t.lastTurn) return { state: 'idle', phrase: 'Idle', isThinking: false, elapsedMs: null }
  const last = t.lastTurn
  const length = `${words(last.durationMs)}${last.isAborted ? ', interrupted' : ''}`
  return { state: 'idle', phrase: `Idle · last turn ${length} · ${ago(at - last.endedAt)}`, isThinking: false, elapsedMs: null }
}

export function planView(plan, maxPending = 4) {
  const done = plan.filter((p) => p.status === 'completed').length
  const current = plan.find((p) => p.status === 'in_progress') ?? null
  const pendingAll = plan.filter((p) => p.status === 'pending')
  const after = current ? plan.slice(plan.indexOf(current) + 1) : plan
  const next = after.find((p) => p.status === 'pending') ?? pendingAll[0] ?? null
  const pending = pendingAll.slice(0, maxPending)
  return { total: plan.length, done, current, next, pending, more: pendingAll.length - pending.length }
}

export function stepCounts(steps) {
  const counts = new Map()
  for (const s of steps) {
    const c = counts.get(s.tool) ?? { tool: s.tool, kind: s.kind, n: 0 }
    c.n += 1
    counts.set(s.tool, c)
  }
  return [...counts.values()].sort((a, b) => b.n - a.n)
}

export function turnShown(t) {
  if (t.turn) return { steps: t.turn.steps, start: t.turn.startedAt, end: null }
  if (t.lastTurn) return { steps: t.lastTurn.steps, start: t.lastTurn.startedAt, end: t.lastTurn.endedAt }
  return null
}

export function sessionTokens(t) {
  return t.tokens.input + t.tokens.cacheWrite + t.tokens.output
}

function todosToPlan(todos) {
  return todos
    .filter((x) => x && typeof x.content === 'string')
    .map((x, i) => ({ id: String(i), content: x.content, activeForm: str(x.activeForm) || x.content, status: x.status }))
}

function updateTask(t, call) {
  const i = t.plan.findIndex((p) => p.id === call.taskId)
  if (i < 0) return
  if (call.status === 'deleted') {
    t.plan.splice(i, 1)
    return
  }
  const item = t.plan[i]
  if (typeof call.status === 'string') item.status = call.status
  if (typeof call.subject === 'string') item.content = call.subject
  if (typeof call.activeForm === 'string') item.activeForm = call.activeForm
}

function str(v) {
  return typeof v === 'string' ? v : ''
}
