import { expect, test } from 'claude-code/testing'
import { palette } from '../hooks/raster.js'
import { completeTurn, endStep, newTracker, setMeasure, startStep, startTurn } from '../hooks/tracker.js'
import { drawHint, drawStatus, scanWidth } from '../hooks/view.js'

const PANE = {
  plugin: 'glance-status',
  component: 'Pane',
  requestId: 'view-test',
  surface: 'terminal',
  viewport: { columns: 160, rows: 50, isFullscreen: true },
  props: { title: 'Status', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: { offset: 0, bodyRows: 45 }, view: {} },
} as const

function busy() {
  const t = newTracker()
  startTurn(t, 't1', 0)
  startStep(t, { tool: 'TodoWrite', tool_use_id: 'p', todos: [
    { content: 'Model', status: 'completed', activeForm: 'Modelling' },
    { content: 'Wire the badge', status: 'in_progress', activeForm: 'Wiring the badge' },
    { content: 'Tests', status: 'pending', activeForm: 'Testing' },
  ] }, 1000, '/w')
  endStep(t, { tool: 'TodoWrite', tool_use_id: 'p' }, { result: {} }, 1500)
  startStep(t, { tool: 'Agent', tool_use_id: 'a', description: 'map plumbing', subagent_type: 'Explore' }, 2000, '/w')
  startStep(t, { tool: 'Edit', tool_use_id: 'e', file_path: '/w/TabSidebarView.swift' }, 40_000, '/w')
  setMeasure(t, { context: { tokens: 82_000, window: 200_000, percent: 41 }, rateLimits: [{ kind: 'five_hour', percentUsed: 32 }, { kind: 'seven_day', percentUsed: 18 }], cost: { usd: 1.24 } })
  return t
}

// The Buttons a drawing made, by key. The harness's `ui.press` only reaches Buttons drawn by the plugin's own
// register.js (a test-side `on` is not the plugin), so these tests call a Button's onPress themselves; the real press
// path is covered where register.js wires the pane.
const buttons = new Map<string, any>()
function recording(el: any) {
  return { ...el, Button: (p: any) => { buttons.set(p.key, p); return el.Button(p) } }
}
const press = (key: string) => buttons.get(key).onPress()

// The engine draws the pane with drawStatus, as register.js does.
function mountWith(on: any, snap: any, closed = { n: 0 }) {
  buttons.clear()
  on('ui.render', { component: 'Pane' }, ($: any, e: any) =>
    drawStatus(recording($.ui.resolve(e)), snap, e.props.bodyColumns, { close: () => { closed.n += 1 } }))
}

test('a working session: header, NOW, PLAN, RECENT, USAGE', async ($, on) => {
  const snap = { t: busy(), at: 42_000, cwd: '/w/glance-claude-status', model: 'claude-opus-5-5', pal: palette(false), scanPhase: 0, details: false }
  mountWith(on, snap)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: 'Status' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /glance-claude-status · Opus 5\.5/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: ' WORKING ' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Editing TabSidebarView.swift' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '0:42' })).toBeDefined()
  expect(await ui.find({ type: 'Raster', key: 'status-scan' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '1 helper agent running' })).toBeDefined()
  expect(await ui.find({ type: 'Raster', key: 'status-plan' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '1/3' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Wiring the badge' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Edit  ' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '41% context used' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '$1.24' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'week limit 18%' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /82k of 200k/ })).toBeUndefined() // behind Details
  expect(await ui.find({ type: 'Button', key: 'status-close' })).toBeDefined()
})

test('Details opens the token and context numbers', async ($, on) => {
  const snap = { t: busy(), at: 42_000, cwd: '/w', model: 'm', pal: palette(false), scanPhase: 0, details: true }
  mountWith(on, snap)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: /Context window {2}82k of 200k/ })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'status-details', text: '▾ Details' })).toBeDefined()
})

test('idle with no plan and no measurement', async ($, on) => {
  const t = newTracker()
  startTurn(t, 't1', 0)
  completeTurn(t, { turnId: 't1', durationMs: 72_000, isAborted: false, usage: { input_tokens: 1000, output_tokens: 500, cache_creation_input_tokens: 0, cache_read_input_tokens: 9000, model: 'm' } }, 72_000)
  mountWith(on, { t, at: 272_000, cwd: '/w/acme', model: 'm', pal: palette(true), scanPhase: 0, details: true })
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: ' IDLE ' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Idle · last turn 1m 12s · 3m ago' })).toBeDefined()
  expect(await ui.find({ type: 'Raster', key: 'status-scan' })).toBeUndefined()
  expect(await ui.find({ type: 'Raster', key: 'status-plan' })).toBeUndefined() // no plan: no PLAN section
  expect(await ui.find({ type: 'Text', text: /1\.5k/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /Cache reads {2}9k/ })).toBeDefined()
})

test('waiting: the amber phrase and a still track', async ($, on) => {
  const t = newTracker()
  startTurn(t, 't1', 0)
  startStep(t, { tool: 'Bash', tool_use_id: 'u', command: 'git push' }, 10, '')
  t.waiting = 'u'
  mountWith(on, { t, at: 5000, cwd: '/w', model: 'm', pal: palette(false), scanPhase: 0 })
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: ' NEEDS YOU ' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Waiting for you · Running git push' })).toMatchObject({ props: { color: 'warning' } })
  expect(await ui.find({ type: 'Raster', key: 'status-scan' })).toBeDefined()
})

test('narrow panes and long targets still draw', async ($, on) => {
  const t = busy()
  startStep(t, { tool: 'Bash', tool_use_id: 'long', command: 'x'.repeat(300) }, 41_000, '')
  mountWith(on, { t, at: 42_000, cwd: '/w', model: 'm', pal: palette(false), scanPhase: 0 })
  const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, bodyColumns: 30 } })
  expect(await ui.find({ type: 'Raster', key: 'status-plan' })).toBeDefined()
  expect(scanWidth(30)).toBeGreaterThanOrEqual(1)
  expect(scanWidth(4)).toBe(1)
})

test('the hint chip: working, waiting, idle', async ($, on) => {
  const HINT = { plugin: 'glance-status', component: 'PromptHint', requestId: 'hint', surface: 'terminal',
    viewport: { columns: 120, rows: 40, isFullscreen: true }, props: { isDraft: false, isWorking: true, hint: '? for shortcuts' } } as const
  buttons.clear()
  let snap: any = { t: busy(), at: 42_000, cwd: '/w', model: 'm', pal: palette(false), scanPhase: 0 }
  let opened = 0
  on('ui.render', { component: 'PromptHint' }, ($: any, e: any) => drawHint(recording($.ui.resolve(e)), snap, () => { opened += 1 }))
  let ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Button', key: 'status-open', text: 'Editing TabSidebarView.swift · 1/3 · 41%' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '● ' })).toMatchObject({ props: { color: 'planMode' } })
  press('status-open')
  expect(opened).toBe(1)

  const w = newTracker()
  startTurn(w, 't', 0)
  startStep(w, { tool: 'Bash', tool_use_id: 'u', command: 'git push' }, 1, '')
  w.waiting = 'u'
  snap = { ...snap, t: w }
  await ui.unmount()
  buttons.clear()
  ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Button', key: 'status-open', text: 'Waiting for you · Running git push' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '● ' })).toMatchObject({ props: { color: 'warning' } })

  const idle = newTracker()
  snap = { ...snap, t: idle }
  await ui.unmount()
  buttons.clear()
  ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Button', key: 'status-open', text: 'Status' })).toBeDefined()
  setMeasure(idle, { cost: { usd: 1.24 } })
  await ui.unmount()
  buttons.clear()
  ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Button', key: 'status-open', text: 'Status · $1.24' })).toBeDefined()

  const long = busy()
  startStep(long, { tool: 'Bash', tool_use_id: 'z', command: 'q'.repeat(200) }, 41_000, '')
  snap = { ...snap, t: long }
  await ui.unmount()
  buttons.clear()
  ui = await $.ui.mount(HINT)
  const chip: any = await ui.find({ type: 'Button', key: 'status-open' })
  expect(chip.props.label.length + 2).toBeLessThanOrEqual(48) // the dot counts
})

test('Close calls the action', async ($, on) => {
  const closed = { n: 0 }
  mountWith(on, { t: busy(), at: 1, cwd: '/w', model: 'm', pal: palette(false), scanPhase: 0 }, closed)
  const ui = await $.ui.mount(PANE)
  press('status-close')
  expect(closed.n).toBe(1)
})
