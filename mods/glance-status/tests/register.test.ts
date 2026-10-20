import { expect, mock, test } from 'claude-code/testing'

const PANE = {
  plugin: 'glance-status',
  component: 'Pane',
  requestId: 'glance-status',
  surface: 'terminal',
  viewport: { columns: 160, rows: 50, isFullscreen: true },
  props: { title: 'Status', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: { offset: 0, bodyRows: 45 }, view: {} },
} as const

// The engine beneath the mod: a session in /w, a mocked clock the test moves (mock.clock), the pane placed unless the
// test says otherwise. `periods` counts the clock.every dispatches the engine asked: one when a timer starts and one
// more each time it fires, none once it is cancelled, so it shows what really runs (the engine builds the Timer; a
// stub cannot fake its cancel).
function engine(on: any, options: { clock?: boolean } = {}) {
  const state: any = { opened: [] as any[], closed: [] as any[], blits: 0, periods: 0, placed: true, registerFails: false, clock: undefined }
  // Terminals the engine itself would answer beneath the mod's hooks.
  on('session.start', () => ({ cwd: '/w' }))
  on('session.end', ($: any, e: any) => ({ sessionId: e.sessionId ?? '' }))
  on('turn.start', ($: any, e: any) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('session.measure', ($: any, e: any) => ({ changed: e.changed }))
  on('command.register', () => {
    if (state.registerFails) throw new Error('no register')
    return { value: undefined }
  })
  on('*', (_$: any, e: any, next: any) => {
    if (next.event === 'clock.every') state.periods += 1
    return next(e)
  })
  if (options.clock !== false) state.clock = mock.clock(on)
  on('ui.open', ($: any, e: any) => { state.opened.push(e); return { value: { isPlaced: state.placed } } })
  on('ui.close', ($: any, e: any) => { state.closed.push(e); return { value: undefined } })
  on('ui.blit', () => { state.blits += 1; return { value: {} } })
  on('session.usage', () => ({ value: { startedAt: 0, context: { tokens: 82_000, window: 200_000, percent: 41 }, rateLimits: [], cost: { usd: 0.5 } } }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.messages', () => ({ value: [] }))
  on('config.list', () => ({ value: [{ key: 'theme', label: 'Theme', kind: 'enum', value: 'dark' }] }))
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['drawn by Claude Code'] }))
  return state
}

async function start($: any) {
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/w' })
}

test('/progress opens the pane and it shows the session so far', async ($, on) => {
  const s = engine(on)
  on('tool.call', () => ({ result: {} }))
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await s.clock.set(5_000)
  await $.tool.call({ tool: 'Read', tool_use_id: 'u1', file_path: '/w/a.ts' })
  expect(await $.command.run({ command: 'progress', args: '' })).toEqual({})
  expect(s.opened[0]).toMatchObject({ id: 'glance-status', title: 'Status', focus: true, closeOnEscape: true })
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: ' WORKING ' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: ' Read ' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /41%/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '$0.50' })).toBeDefined()
  expect(s.periods).toBe(2) // the second ticker and the scan line
  await s.clock.advance(1_000)
  expect(s.blits).toBeGreaterThan(0) // the scan line is repainted
})

test('tool results pass through untouched, failures and throws included', async ($, on) => {
  engine(on)
  let mode = 'ok'
  on('tool.call', () => {
    if (mode === 'throw') throw new Error('boom')
    return mode === 'error' ? { result: { stderr: 'x' }, isError: true } : { result: { ok: 1 } }
  })
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  expect(await $.tool.call({ tool: 'Bash', tool_use_id: 'u1', command: 'true' })).toMatchObject({ result: { ok: 1 } })
  mode = 'error'
  expect(await $.tool.call({ tool: 'Bash', tool_use_id: 'u2', command: 'false' })).toMatchObject({ isError: true })
  mode = 'throw'
  await expect($.tool.call({ tool: 'Bash', tool_use_id: 'u3', command: 'boom' })).rejects.toBeDefined()
  await $.command.run({ command: 'progress', args: '' })
  const ui = await $.ui.mount(PANE)
  // u3 ended (failed) instead of running forever: NOW is Thinking, not "Running boom".
  expect(await ui.find({ type: 'Text', text: 'Thinking' })).toBeDefined()
})

test('subagent calls and turns stay out of NOW; their tokens count', async ($, on) => {
  engine(on)
  on('tool.call', () => ({ result: {} }))
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.tool.call({ tool: 'Read', tool_use_id: 's1', agentId: 'ag', file_path: '/w/x.ts' })
  await $.turn.complete({ answer: '', durationMs: 10, isAborted: false, turnId: 'sub', agentId: 'ag', reason: 'answer', category: null, explanation: null,
    usage: { input_tokens: 1000, output_tokens: 1000, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, model: 'm' } })
  await $.command.run({ command: 'progress', args: '' })
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: ' WORKING ' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'No steps yet.' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '2k' })).toBeDefined()
})

test('a permission ask shows as waiting until the call ends', async ($, on) => {
  engine(on)
  on('tool.check', () => ({ decision: 'ask' }))
  let release: () => void = () => {}
  on('tool.call', () => new Promise((resolve) => { release = () => resolve({ result: {} }) }))
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  const call = $.tool.call({ tool: 'Bash', tool_use_id: 'u1', command: 'git push' })
  await $.tool.check({ tool: 'Bash', input: { command: 'git push' }, tool_use_id: 'u1' })
  await $.command.run({ command: 'progress', args: '' })
  let ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: ' NEEDS YOU ' })).toBeDefined()
  release()
  await call
  await ui.unmount()
  ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: ' WORKING ' })).toBeDefined()
})

const HINT = { plugin: 'glance-status', component: 'PromptHint', requestId: 'hint', surface: 'terminal',
  viewport: { columns: 120, rows: 40, isFullscreen: true }, props: { isDraft: false, isWorking: true, hint: '? for shortcuts' } } as const

test('the hint chip follows the running step and opens the pane', async ($, on) => {
  const s = engine(on)
  on('tool.call', () => new Promise(() => {}))
  await start($)
  let ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Button', key: 'status-open', text: 'Status' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'drawn by Claude Code' })).toBeDefined() // Claude Code's own hint stays
  await $.turn.start({ text: 'go', turnId: 't1' })
  await ui.unmount()
  void $.tool.call({ tool: 'Edit', tool_use_id: 'u1', file_path: '/w/a.ts' })
  await new Promise((r) => setTimeout(r, 0))
  ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Button', key: 'status-open', text: 'Editing a.ts' })).toBeDefined()
  expect(s.periods).toBe(0) // the chip needs no timer
  await ui.press({ key: 'status-open' })
  expect(s.opened[0]).toMatchObject({ id: 'glance-status', title: 'Status', focus: true, closeOnEscape: true })
  expect(s.periods).toBe(2)
})

test('idle, the chip says Status and the cost', async ($, on) => {
  engine(on)
  await start($)
  await $.session.measure({ context: { window: 200_000 }, rateLimits: [], cost: { usd: 0.5 }, changed: ['cost'] })
  const ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Button', key: 'status-open', text: 'Status · $0.50' })).toBeDefined()
})

test('narrow pane, long command: still draws', async ($, on) => {
  engine(on)
  on('tool.call', () => new Promise(() => {}))
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  void $.tool.call({ tool: 'Bash', tool_use_id: 'u1', command: 'y'.repeat(300) })
  await new Promise((r) => setTimeout(r, 0))
  await $.command.run({ command: 'progress', args: '' })
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, bodyColumns: 24 } })
  expect(await ui.find({ type: 'Raster', key: 'status-scan' })).toBeDefined()
})

const MAIN_DONE = { answer: '', durationMs: 10, isAborted: false, turnId: 't1', reason: 'answer', category: null, explanation: null,
  usage: { input_tokens: 10, output_tokens: 10, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, model: 'm' } } as const

test('the turn ends: both timers are cancelled and nothing is asked again', async ($, on) => {
  const s = engine(on)
  on('tool.call', () => ({ result: {} }))
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.command.run({ command: 'progress', args: '' })
  await $.ui.mount(PANE)
  expect(s.periods).toBe(2)
  await s.clock.advance(1_000)
  expect(s.periods).toBeGreaterThan(2) // running: the clock keeps asking
  await $.turn.complete(MAIN_DONE)
  const settled = s.periods
  await s.clock.advance(5_000)
  expect(s.periods).toBe(settled)
})

test('closing the pane cancels the timers', async ($, on) => {
  const s = engine(on)
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.command.run({ command: 'progress', args: '' })
  const ui = await $.ui.mount(PANE)
  await s.clock.advance(1_000)
  await ui.press({ key: 'status-close' }) // the pane's own Close asks the engine to close it
  expect(s.closed[0]).toMatchObject({ id: 'glance-status' })
  const settled = s.periods
  await s.clock.advance(5_000)
  expect(s.periods).toBe(settled)
})

test('/clear while the timers run: they stop, and the next session uses its own folder', async ($, on) => {
  const s = engine(on)
  on('tool.call', () => new Promise(() => {}))
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.command.run({ command: 'progress', args: '' })
  await $.ui.mount(PANE)
  await s.clock.advance(1_000)
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: {} })
  const settled = s.periods
  await s.clock.advance(5_000)
  expect(s.periods).toBe(settled)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/w2' })
  await $.turn.start({ text: 'again', turnId: 't2' })
  void $.tool.call({ tool: 'Edit', tool_use_id: 'u9', file_path: '/w2/sub/a.ts' })
  await new Promise((r) => setTimeout(r, 0))
  const ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Button', key: 'status-open', text: 'Editing sub/a.ts' })).toBeDefined()
})

test('a pane that is not placed starts no timers', async ($, on) => {
  const s = engine(on)
  s.placed = false
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  expect(await $.command.run({ command: 'progress', args: '' })).toEqual({})
  await s.clock.advance(1_000)
  expect(s.periods).toBe(0)
})

test('a command.register that fails still leaves the folder set', async ($, on) => {
  const s = engine(on)
  s.registerFails = true
  on('tool.call', () => new Promise(() => {}))
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  void $.tool.call({ tool: 'Edit', tool_use_id: 'u1', file_path: '/w/a.ts' })
  await new Promise((r) => setTimeout(r, 0))
  const ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Button', key: 'status-open', text: 'Editing a.ts' })).toBeDefined()
})

test('a clock that fails still ends the step', async ($, on) => {
  engine(on, { clock: false })
  let calls = 0
  on('clock.now', () => {
    calls += 1
    if (calls === 2) throw new Error('clock gone') // the start read answers, the end read fails
    return { value: 100 }
  })
  on('clock.every', () => ({ value: undefined }))
  on('tool.call', () => ({ result: {} }))
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  calls = 0
  expect(await $.tool.call({ tool: 'Bash', tool_use_id: 'u1', command: 'true' })).toMatchObject({ result: {} })
  await $.command.run({ command: 'progress', args: '' })
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: 'Thinking' })).toBeDefined()
})
