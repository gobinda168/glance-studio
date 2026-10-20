import { expect, test } from 'claude-code/testing'
import {
  completeTurn, endStep, newTracker, nowView, planFromMessages, planView, sessionTokens, setMeasure, startStep,
  startTurn, stepCounts, turnShown, waitFor,
} from '../hooks/tracker.js'

const usage = (input: number, output: number, cacheWrite = 0, cacheRead = 0) => ({
  input_tokens: input, output_tokens: output, cache_creation_input_tokens: cacheWrite, cache_read_input_tokens: cacheRead, model: 'claude-opus-5-5',
})

test('a turn: steps start and end, NOW says the running one, else Thinking', () => {
  const t = newTracker()
  startTurn(t, 't1', 1000)
  expect(nowView(t, 2000)).toEqual({ state: 'working', phrase: 'Thinking', isThinking: true, elapsedMs: 1000 })
  startStep(t, { tool: 'Read', tool_use_id: 'u1', file_path: '/w/a.ts' }, 3000, '/w')
  expect(nowView(t, 4000).phrase).toBe('Reading a.ts')
  endStep(t, { tool: 'Read', tool_use_id: 'u1' }, { result: {} }, 5000)
  expect(nowView(t, 6000).phrase).toBe('Thinking')
  startStep(t, { tool: 'Bash', tool_use_id: 'u2', command: 'false' }, 6000, '/w')
  endStep(t, { tool: 'Bash', tool_use_id: 'u2' }, { result: {}, isError: true }, 7000)
  expect(t.turn!.steps.map((s: any) => [s.tool, s.startedAt, s.endedAt, s.failed])).toEqual([['Read', 3000, 5000, false], ['Bash', 6000, 7000, true]])
  endStep(t, { tool: 'Edit', tool_use_id: 'u3' }, { deny: 'no' }, 7500) // never started: ignored
  expect(t.turn!.steps.length).toBe(2)
})

test('the turn ends: tokens add up, NOW goes idle with the last turn', () => {
  const t = newTracker()
  startTurn(t, 't1', 0)
  startStep(t, { tool: 'Read', tool_use_id: 'u1' }, 10, '')
  completeTurn(t, { turnId: 't1', durationMs: 72_000, isAborted: false, usage: usage(100, 50, 20, 900) }, 72_000)
  expect(t.tokens).toEqual({ input: 100, output: 50, cacheWrite: 20, cacheRead: 900 })
  expect(sessionTokens(t)).toBe(170)
  expect(t.turnTokens).toEqual([170])
  expect(t.turn).toBeNull()
  expect(t.lastTurn).toMatchObject({ durationMs: 72_000, tokens: 170, endedAt: 72_000, isAborted: false, startedAt: 0 })
  expect(nowView(t, 72_000 + 200_000)).toEqual({ state: 'idle', phrase: 'Idle · last turn 1m 12s · 3m ago', isThinking: false, elapsedMs: null })
  // The step left running when the turn ended is closed at the turn's end.
  expect(t.lastTurn!.steps[0].endedAt).toBe(72_000)
  expect(nowView(newTracker(), 0).phrase).toBe('Idle')
})

test('an interrupted turn says so; a turn with no usage adds nothing', () => {
  const t = newTracker()
  startTurn(t, 't1', 0)
  completeTurn(t, { turnId: 't1', durationMs: 5000, isAborted: true }, 5000)
  expect(nowView(t, 5000).phrase).toBe('Idle · last turn 5s, interrupted · just now')
  expect(sessionTokens(t)).toBe(0)
  expect(t.turnTokens).toEqual([0])
})

test('subagents: their calls stay out of NOW and the log, their tokens count', () => {
  const t = newTracker()
  startTurn(t, 't1', 0)
  startStep(t, { tool: 'Agent', tool_use_id: 'a1', description: 'map plumbing', subagent_type: 'Explore' }, 10, '')
  expect([...t.agents.values()]).toEqual([{ type: 'Explore', description: 'map plumbing', startedAt: 10 }])
  startStep(t, { tool: 'Read', tool_use_id: 's1', agentId: 'ag1', file_path: '/x' }, 20, '')
  expect(t.turn!.steps.map((s: any) => s.tool)).toEqual(['Agent'])
  expect(nowView(t, 30).phrase).toBe('Agent: map plumbing')
  completeTurn(t, { turnId: 'sub', agentId: 'ag1', durationMs: 5, isAborted: false, usage: usage(10, 5) }, 40)
  expect(t.turn).not.toBeNull() // the main turn goes on
  expect(sessionTokens(t)).toBe(15)
  expect(t.turnTokens).toEqual([])
  endStep(t, { tool: 'Agent', tool_use_id: 'a1' }, { result: {} }, 50)
  expect(t.agents.size).toBe(0)
})

test('waiting on the person: from the ask until that call ends', () => {
  const t = newTracker()
  startTurn(t, 't1', 0)
  startStep(t, { tool: 'Bash', tool_use_id: 'u1', command: 'git push' }, 10, '')
  waitFor(t, 'u1')
  expect(nowView(t, 20)).toMatchObject({ state: 'waiting', phrase: 'Waiting for you · Running git push' })
  endStep(t, { tool: 'Bash', tool_use_id: 'u1' }, { result: {} }, 30)
  expect(nowView(t, 40).state).toBe('working')
  waitFor(t, 'nope') // an id with no step: still says waiting, with no detail
  expect(nowView(t, 50)).toMatchObject({ state: 'waiting', phrase: 'Waiting for you' })
})

test('the plan from TodoWrite, and from TaskCreate / TaskUpdate', () => {
  const t = newTracker()
  startTurn(t, 't1', 0)
  startStep(t, { tool: 'TodoWrite', tool_use_id: 'p1', todos: [
    { content: 'Model', status: 'completed', activeForm: 'Modelling' },
    { content: 'Wire', status: 'in_progress', activeForm: 'Wiring' },
    { content: 'Test', status: 'pending', activeForm: 'Testing' },
  ] }, 1, '')
  expect(t.plan.map((p: any) => [p.content, p.status, p.activeForm])).toEqual([['Model', 'completed', 'Modelling'], ['Wire', 'in_progress', 'Wiring'], ['Test', 'pending', 'Testing']])

  const u = newTracker()
  startTurn(u, 't1', 0)
  const create = (id: string, subject: string) => {
    startStep(u, { tool: 'TaskCreate', tool_use_id: `c${id}`, subject, description: '', activeForm: `${subject}ing` }, 1, '')
    endStep(u, { tool: 'TaskCreate', tool_use_id: `c${id}`, subject, description: '', activeForm: `${subject}ing` }, { result: { task: { id, subject } } }, 2)
  }
  create('1', 'Build')
  create('2', 'Ship')
  startStep(u, { tool: 'TaskUpdate', tool_use_id: 'x1', taskId: '1', status: 'in_progress' }, 3, '')
  startStep(u, { tool: 'TaskUpdate', tool_use_id: 'x2', taskId: '2', subject: 'Release' }, 4, '')
  expect(u.plan.map((p: any) => [p.id, p.content, p.status])).toEqual([['1', 'Build', 'in_progress'], ['2', 'Release', 'pending']])
  startStep(u, { tool: 'TaskUpdate', tool_use_id: 'x3', taskId: '2', status: 'deleted' }, 5, '')
  startStep(u, { tool: 'TaskUpdate', tool_use_id: 'x4', taskId: '9', status: 'completed' }, 6, '') // unknown id: ignored
  expect(u.plan.map((p: any) => p.id)).toEqual(['1'])
  // A failed TaskCreate adds nothing.
  startStep(u, { tool: 'TaskCreate', tool_use_id: 'c3', subject: 'Nope', description: '' }, 7, '')
  endStep(u, { tool: 'TaskCreate', tool_use_id: 'c3', subject: 'Nope', description: '' }, { deny: 'no' }, 8)
  expect(u.plan.length).toBe(1)
})

test('planView: counts, the current, the next, four pending and the rest folded', () => {
  const item = (content: string, status: string) => ({ id: content, content, activeForm: `${content}…`, status })
  const plan = [item('a', 'completed'), item('b', 'completed'), item('c', 'pending'), item('d', 'in_progress'),
    item('e', 'pending'), item('f', 'pending'), item('g', 'pending'), item('h', 'pending'), item('i', 'pending')]
  const v = planView(plan as any)
  expect([v.total, v.done, v.current?.content, v.next?.content, v.more]).toEqual([9, 2, 'd', 'e', 2])
  expect(v.pending.map((p: any) => p.content)).toEqual(['c', 'e', 'f', 'g'])
  expect(planView([item('x', 'pending')] as any).next?.content).toBe('x')
  expect(planView([]).total).toBe(0)
})

test('stepCounts: most used first, ties in first-use order', () => {
  const s = (tool: string, kind: string) => ({ id: tool, tool, kind, verb: '', target: '', startedAt: 0, endedAt: 0, failed: false })
  expect(stepCounts([s('Read', 'read'), s('Edit', 'edit'), s('Read', 'read'), s('Bash', 'run'), s('Edit', 'edit'), s('Read', 'read')] as any))
    .toEqual([{ tool: 'Read', kind: 'read', n: 3 }, { tool: 'Edit', kind: 'edit', n: 2 }, { tool: 'Bash', kind: 'run', n: 1 }])
})

test('turnShown: this turn while it runs, else the last', () => {
  const t = newTracker()
  expect(turnShown(t)).toBeNull()
  startTurn(t, 't1', 100)
  expect(turnShown(t)).toEqual({ steps: [], start: 100, end: null })
  completeTurn(t, { turnId: 't1', durationMs: 900, isAborted: false }, 1000)
  expect(turnShown(t)).toEqual({ steps: [], start: 100, end: 1000 })
})

test('setMeasure keeps the figures; planFromMessages finds the latest TodoWrite', () => {
  const t = newTracker()
  setMeasure(t, { context: { tokens: 82_000, window: 200_000, percent: 41 }, rateLimits: [{ kind: 'five_hour', percentUsed: 32 }], cost: { usd: 1.24 }, changed: ['context'] })
  expect(t.measure).toEqual({ context: { tokens: 82_000, window: 200_000, percent: 41 }, rateLimits: [{ kind: 'five_hour', percentUsed: 32 }], cost: { usd: 1.24 } })
  setMeasure(t, {})
  expect(t.measure).toEqual({ context: null, rateLimits: [], cost: null })
  const todo = (content: string) => ({ type: 'tool_use', id: content, name: 'TodoWrite', input: { todos: [{ content, status: 'pending', activeForm: content }] } })
  const messages = [
    { role: 'assistant', content: [todo('old')] },
    { role: 'user', content: 'go on' },
    { role: 'assistant', content: [{ type: 'text', text: 'ok' }, todo('new')] },
    { role: 'assistant', content: [{ type: 'tool_use', id: 'r', name: 'Read', input: {} }] },
  ]
  expect(planFromMessages(messages).map((p: any) => p.content)).toEqual(['new'])
  expect(planFromMessages([])).toEqual([])
  expect(planFromMessages([{ role: 'assistant', content: 'text only' }])).toEqual([])
})

test('a subagent call put to the person: WAITING shows and clears when that call ends', () => {
  const t = newTracker()
  startTurn(t, 't1', 0)
  startStep(t, { tool: 'Bash', tool_use_id: 's1', agentId: 'ag', command: 'npm i' }, 10, '')
  waitFor(t, 's1')
  expect(nowView(t, 20)).toMatchObject({ state: 'waiting', phrase: 'Waiting for you' })
  endStep(t, { tool: 'Bash', tool_use_id: 's1', agentId: 'ag' }, { result: {} }, 30)
  expect(nowView(t, 40).state).toBe('working')
})

test('usage with missing fields counts as zero, never NaN', () => {
  const t = newTracker()
  startTurn(t, 't1', 0)
  completeTurn(t, { turnId: 't1', durationMs: 10, isAborted: false, usage: { input_tokens: 7, output_tokens: 3 } }, 10)
  expect(sessionTokens(t)).toBe(10)
  expect(t.turnTokens).toEqual([10])
  expect(t.tokens).toEqual({ input: 7, output: 3, cacheWrite: 0, cacheRead: 0 })
})
