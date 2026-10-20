import { expect, test } from 'claude-code/testing'
import { parseBranch, sameBranch } from '../hooks/branch.js'

const HINT = {
  plugin: 'glance-replies',
  component: 'PromptHint',
  requestId: 'hint',
  surface: 'terminal',
  viewport: { columns: 100, rows: 40, isFullscreen: true },
  props: { isDraft: false, isWorking: false, hint: '? for shortcuts' },
} as const

// Stands for Claude Code's own hint line.
const ENGINE = { type: 'Text', props: {}, children: ['? for shortcuts'] }

test('reads the branch and a linked worktree from the script', async () => {
  expect(parseBranch(0, 'main\n\n')).toEqual({ name: 'main', worktree: null })
  expect(parseBranch(0, 'feat/x\nglance-wt\n')).toEqual({ name: 'feat/x', worktree: 'glance-wt' })
  expect(parseBranch(0, 'a1b2c3d\n\n')).toEqual({ name: 'a1b2c3d', worktree: null })
  expect(parseBranch(1, '')).toBeNull()
  expect(parseBranch(0, '')).toBeNull()
  expect(sameBranch({ name: 'main', worktree: null }, { name: 'main', worktree: null })).toBe(true)
  expect(sameBranch({ name: 'main', worktree: null }, null)).toBe(false)
})

async function startIn($: any, on: any, stdout: string, exitCode = 0) {
  on('session.start', () => ({ cwd: '/work' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('env.get', () => ({ value: undefined }))
  on('session.id', () => ({ value: 's1' }))
  on('command.register', () => ({ value: undefined }))
  on('clock.every', () => ({ value: { cancel() {} } }))
  on('process.run', ($: any, e: any) =>
    e.argv[2]?.includes('symbolic-ref') ? { value: { exitCode, stdout, stderr: '' } } : { value: { exitCode: 0, stdout: '', stderr: '' } },
  )
  on('ui.render', () => ENGINE)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  // The read runs beside session.start; let it land.
  await new Promise((resolve) => setTimeout(resolve, 0))
}

test('the branch leads the hint line, which Claude Code still draws', async ($, on) => {
  await startIn($, on, 'main\n\n')
  const ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Text', text: ' ⎇ main ' })).toMatchObject({ props: { backgroundColor: 'claude', bold: true } })
  expect(await ui.find({ type: 'Text', text: '? for shortcuts' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: / worktree / })).toBeUndefined()
})

test('a worktree is named beside its branch', async ($, on) => {
  await startIn($, on, 'feat/x\nglance-wt\n')
  const ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Text', text: ' ⎇ feat/x ' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: ' worktree glance-wt' })).toBeDefined()
})

test('outside a repository the hint line is left alone', async ($, on) => {
  await startIn($, on, '', 128)
  const ui = await $.ui.mount(HINT)
  expect(await ui.find({ type: 'Text', text: /⎇/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: '? for shortcuts' })).toBeDefined()
})
