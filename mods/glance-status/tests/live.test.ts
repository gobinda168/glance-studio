import { expect, mock, test } from 'claude-code/testing'

const PANE = {
  plugin: 'glance-status',
  component: 'Pane',
  requestId: 'glance-status',
  surface: 'terminal',
  viewport: { columns: 160, rows: 50, isFullscreen: true },
  props: { title: 'Status', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: { offset: 0, bodyRows: 45 }, view: {} },
} as const

// The engine beneath the mod: a session in /w and a mocked clock the test moves (mock.clock). `periods` counts the
// clock.every dispatches the engine asked: one when a timer starts and one more each time it fires, none once it is
// cancelled, so it shows what really runs (the engine builds the Timer; a stub cannot fake its cancel).
function engine(on: any, messages: any[] = []) {
  const state: any = { periods: 0, messageReads: 0, clock: undefined }
  on('session.start', () => ({ cwd: '/w' }))
  on('session.end', ($: any, e: any) => ({ sessionId: e.sessionId ?? '' }))
  on('turn.start', ($: any, e: any) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('command.register', () => ({ value: undefined }))
  on('*', (_$: any, e: any, next: any) => {
    if (next.event === 'clock.every') state.periods += 1
    return next(e)
  })
  state.clock = mock.clock(on)
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.close', () => ({ value: undefined }))
  on('ui.blit', () => ({ value: {} }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 200_000 }, rateLimits: [] } }))
  on('session.model', () => ({ value: 'm' }))
  on('session.messages', () => {
    state.messageReads += 1
    return { value: messages }
  })
  on('config.list', () => ({ value: [] }))
  on('tool.call', () => ({ result: {} }))
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['drawn by Claude Code'] }))
  return state
}

async function start($: any) {
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/w' })
}

const done = (turnId: string) => ({ answer: '', durationMs: 1000, isAborted: false, turnId, reason: 'answer', category: null, explanation: null,
  usage: { input_tokens: 10, output_tokens: 10, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, model: 'm' } })

test('timers run only while the pane is open and a main turn runs', async ($, on) => {
  const s = engine(on)
  await start($)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await s.clock.advance(5_000)
  expect(s.periods).toBe(0) // pane shut: nothing ticks
  await $.command.run({ command: 'progress', args: '' })
  expect(s.periods).toBe(2) // opened mid-turn: both timers start
  await $.turn.complete(done('t1'))
  const settled = s.periods
  await s.clock.advance(5_000)
  expect(s.periods).toBe(settled) // turn over: both stopped
  await $.turn.start({ text: 'again', turnId: 't2' })
  expect(s.periods).toBe(settled + 2) // pane still open: a new turn starts them again
  await s.clock.advance(1_000)
  expect(s.periods).toBeGreaterThan(settled + 2)
})

test('reopening mid-turn shows the turn so far', async ($, on) => {
  engine(on)
  await start($)
  await $.command.run({ command: 'progress', args: '' })
  let ui = await $.ui.mount(PANE)
  await ui.press({ key: 'status-close' })
  await ui.unmount()
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.tool.call({ tool: 'Edit', tool_use_id: 'u1', file_path: '/w/a.ts' })
  await $.command.run({ command: 'progress', args: '' })
  ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: ' Edit ' })).toBeDefined()
})

test('a resumed session’s plan comes back from the transcript, read once', async ($, on) => {
  const s = engine(on, [{ role: 'assistant', content: [{ type: 'tool_use', id: 'x', name: 'TodoWrite', input: { todos: [
    { content: 'Build', status: 'completed', activeForm: 'Building' },
    { content: 'Ship', status: 'in_progress', activeForm: 'Shipping' },
  ] } }] }])
  await start($)
  await $.command.run({ command: 'progress', args: '' })
  let ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: '1/2' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Shipping' })).toBeDefined()
  expect(s.messageReads).toBe(1)
  await ui.unmount()
  await $.command.run({ command: 'progress', args: '' })
  ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: '1/2' })).toBeDefined()
  expect(s.messageReads).toBe(1) // not read again
})
