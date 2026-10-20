import { expect, test } from 'claude-code/testing'
import { guessOutputPath, newShells, ordered, running, shellNotified, shellResult, shellStarted, shortCommand, tail, titleOf } from '../hooks/shells.js'
import { drawShells } from '../hooks/shellsview.js'

const DEPLOY =
  'D=/private/tmp/claude-501/-Users-g-Work-codebase/d1c4eef3/scratchpad/ghbin && PATH="$D:$PATH" ~/Work/automations/staging/staging deployment 156039037ccc83cb646a96ebc7c27b408432bab7 frontend "DEV-9269: show the steps of filing a self-service ticket"'

const PANE = {
  plugin: 'glance-status',
  component: 'Pane',
  requestId: 'view-test',
  surface: 'terminal',
  viewport: { columns: 160, rows: 50, isFullscreen: true },
  props: { title: 'Shells', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: { offset: 0, bodyRows: 45 }, view: {} },
} as const

test('the command loses its plumbing and long hashes', () => {
  expect(shortCommand(DEPLOY)).toBe('staging deployment 1560390… frontend "DEV-9269: show the steps of filing a self-service ticket"')
  expect(shortCommand('cd /w/app && npm test -- --watch')).toBe('npm test -- --watch')
  expect(shortCommand('sleep 30')).toBe('sleep 30')
})

test('the title is Claude\'s description, else the command\'s first words', () => {
  const s = newShells()
  shellStarted(s, { tool: 'Bash', tool_use_id: 'a', run_in_background: true, command: DEPLOY, description: 'Deploy DEV-9269 to staging' }, 0)
  shellStarted(s, { tool: 'Bash', tool_use_id: 'b', run_in_background: true, command: DEPLOY }, 0)
  expect(titleOf(s.list[0])).toBe('Deploy DEV-9269 to staging')
  expect(titleOf(s.list[1])).toBe('staging deployment')
})

test('a shell is tracked from call to result to notification', () => {
  const s = newShells()
  shellStarted(s, { tool: 'Bash', tool_use_id: 'a', run_in_background: true, command: 'sleep 9' }, 1000)
  shellStarted(s, { tool: 'Bash', tool_use_id: 'x', command: 'ls' }, 1000) // foreground: not tracked
  expect(s.list).toHaveLength(1)
  shellResult(s, { tool: 'Bash', tool_use_id: 'a' }, { result: { backgroundTaskId: 'bx1', stdout: 'Output is being written to: /tmp/claude-1/p/s/tasks/bx1.output' } }, 1100)
  expect(s.list[0].id).toBe('bx1')
  expect(s.list[0].outputPath).toBe('/tmp/claude-1/p/s/tasks/bx1.output')
  expect(running(s)).toHaveLength(1)
  shellNotified(s, { id: 'bx1', status: 'completed' }, 9000)
  expect(running(s)).toHaveLength(0)
  expect(s.list[0].status).toBe('done')
  expect(ordered(s)[0].callId).toBe('a')
})

test('a Ctrl+B background is picked up from the result', () => {
  const s = newShells()
  shellResult(s, { tool: 'Bash', tool_use_id: 'c', command: 'make' }, { result: { backgroundTaskId: 'bx2' } }, 5)
  expect(s.list[0].id).toBe('bx2')
})

test('the output file is found beside the scratchpad when nothing names it', () => {
  const sh = { id: 'bx1', outputPath: null, command: DEPLOY } as any
  expect(guessOutputPath(sh)).toBe('/private/tmp/claude-501/-Users-g-Work-codebase/d1c4eef3/tasks/bx1.output')
})

test('the tail keeps the last lines and drops colour codes', () => {
  expect(tail('a\n\u001b[31mb\u001b[0m\nc\n\n', 2, 20)).toEqual(['b', 'c'])
  expect(tail('', 3, 20)).toEqual([])
})

test('the pane tells a quiet running shell plainly and offers Stop', async ($, on) => {
  const s = newShells()
  shellStarted(s, { tool: 'Bash', tool_use_id: 'a', run_in_background: true, command: DEPLOY, description: 'Deploy DEV-9269 to staging' }, 0)
  shellResult(s, { tool: 'Bash', tool_use_id: 'a' }, { result: { backgroundTaskId: 'bx1' } }, 1)
  on('ui.render', { component: 'Pane' }, ($: any, e: any) =>
    drawShells($.ui.resolve(e), { shells: s, at: 342_000, output: { lines: [], state: 'empty' } }, 80, { select() {}, toggleCommand() {}, copy() {}, stop() {}, close() {} }))
  const ui = await $.ui.mount(PANE)
  const misses: string[] = []
  if (!(await ui.find({ type: 'Text', text: 'Deploy DEV-9269 to staging' }))) misses.push("ui.find({ type: 'Text', text: 'Deploy DEV-9269 to staging' })")
  if (!(await ui.find({ type: 'Text', text: /Nothing printed yet/ }))) misses.push("ui.find({ type: 'Text', text: /Nothing printed yet/ })")
  if (!(await ui.find({ type: 'Text', text: /Running/ }))) misses.push("ui.find({ type: 'Text', text: /Running/ })")
  if (!(await ui.find({ type: 'Button', key: 'shell-stop' }))) misses.push("ui.find({ type: 'Button', key: 'shell-stop' })")
  if (!(await ui.find({ type: 'Button', key: 'cmd-expand' }))) misses.push("ui.find({ type: 'Button', key: 'cmd-expand' })")
  expect(misses).toEqual([])
})

// End to end through register.js: a background Bash call, then /shells draws it with a plain title and the quiet note.
test('/shells lists a background shell Claude started', async ($, on) => {
  on('session.start', () => ({ cwd: '/w' }))
  on('command.register', () => ({ value: undefined }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['drawn by Claude Code'] }))
  on('session.usage', () => ({ value: { startedAt: 0, context: null, rateLimits: [], cost: null } }))
  on('tool.call', () => ({ result: { backgroundTaskId: 'bx1', stdout: '' } }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/w' })
  await $.tool.call({ tool: 'Bash', tool_use_id: 'u1', command: DEPLOY, description: 'Deploy DEV-9269 to staging', run_in_background: true })
  expect(await $.command.run({ command: 'shells', args: '' })).toEqual({})
  const ui = await $.ui.mount({ ...PANE, requestId: 'glance-shells' } as any)
  expect(await ui.find({ type: 'Text', text: 'Deploy DEV-9269 to staging' })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'shell-stop' })).toBeDefined()
})
