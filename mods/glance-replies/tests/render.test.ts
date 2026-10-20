import { expect, test } from 'claude-code/testing'

const REPLY = {
  plugin: 'glance-replies',
  component: 'AssistantMessage',
  requestId: 'msg-1',
  surface: 'terminal',
  viewport: { columns: 100, rows: 40, isFullscreen: false },
} as const

// Stands for Claude Code's own drawing of the reply.
const ENGINE = { type: 'Text', props: {}, children: ['drawn by Claude Code'] }

test('a reply with nothing of ours is left to Claude Code', async ($, on) => {
  on('ui.render', () => ENGINE)
  const ui = await $.ui.mount({ ...REPLY, props: { text: 'Plain **markdown**.', isFirstOfReply: true } })
  expect(await ui.find({ type: 'Text', text: 'drawn by Claude Code' })).toBeDefined()
})

test('alerts, tasks, diagrams and rules are drawn, the rest is Markdown', async ($, on) => {
  on('ui.render', () => ENGINE)
  const text = [
    'Intro text.',
    '',
    '> [!IMPORTANT]',
    '> Read this.',
    '',
    '- [x] one',
    '- [ ] two',
    '',
    '```mermaid',
    'graph TD',
    '  A[Start] --> B[End]',
    '```',
    '',
    '---',
  ].join('\n')
  const ui = await $.ui.mount({ ...REPLY, props: { text, isFirstOfReply: true } })
  expect(await ui.find({ type: 'Text', text: 'drawn by Claude Code' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: '⏺' })).toBeDefined()
  expect(await ui.find({ type: 'Markdown', key: 'part-0' })).toMatchObject({ props: { text: 'Intro text.' } })
  expect(await ui.find({ type: 'Text', text: '◆ Important' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '✓ ' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '○ ' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /│ Start │/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'mermaid · graph' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^─+$/ })).toBeDefined()
})

test('a later block of a reply has no bullet', async ($, on) => {
  on('ui.render', () => ENGINE)
  const ui = await $.ui.mount({ ...REPLY, props: { text: '> [!TIP]\n> x', isFirstOfReply: false } })
  expect(await ui.find({ type: 'Text', text: '⏺' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: '✦ Tip' })).toBeDefined()
})

test('a diagram the renderer cannot read is drawn as code', async ($, on) => {
  on('ui.render', () => ENGINE)
  const ui = await $.ui.mount({ ...REPLY, props: { text: '```mermaid\nnot a diagram ((\n```', isFirstOfReply: true } })
  expect(await ui.find({ type: 'Markdown', text: /```mermaid/ })).toBeDefined()
})

test('a summary row is left to Claude Code', async ($, on) => {
  on('ui.render', () => ENGINE)
  const ui = await $.ui.mount({ ...REPLY, props: { text: '> [!NOTE]\n> x', isFirstOfReply: true, isSummary: true } })
  expect(await ui.find({ type: 'Text', text: 'drawn by Claude Code' })).toBeDefined()
})

test('a file a reply links is pointed at with its line', async ($, on) => {
  on('session.start', () => ({ cwd: '/work' }))
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/Users/me' : undefined }))
  on('session.id', () => ({ value: 's1' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '' } }))
  on('clock.every', () => ({ value: { cancel() {} } }))
  on('fs.stat', ($, e) => (e.path === '/work/Sources/App.swift' ? { value: { kind: 'file', size: 1, mtimeMs: 0, isLink: false } } : { deny: 'missing' }))
  // Claude Code's own drawing, given the text the hook passed on.
  on('ui.render', ($, e) => ({ type: 'Text', props: {}, children: [e.props.text] }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  const ui = await $.ui.mount({ ...REPLY, props: { text: 'In [App.swift:12](Sources/App.swift#L12) and [gone](Sources/Gone.swift).', isFirstOfReply: true } })
  expect(await ui.find({ type: 'Text', text: 'In [App.swift:12](file:///work/Sources/App.swift:12) and [gone](Sources/Gone.swift).' })).toBeDefined()
})

test('Copy on a code block copies its source, and says so', async ($, on) => {
  let copied = ''
  const toasts: string[] = []
  on('ui.copy', ($, e) => {
    copied = e.text
    return { value: { isCopied: true } }
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.render', () => ENGINE)
  const ui = await $.ui.mount({ ...REPLY, props: { text: 'Run:\n\n```sh\nmake\nmake test\n```', isFirstOfReply: true } })
  expect(await ui.find({ type: 'Code' })).toMatchObject({ props: { source: 'make\nmake test', language: 'sh' } })
  await ui.press({ key: 'part-1-copy' })
  expect(copied).toBe('make\nmake test')
  expect(toasts).toEqual(['Copied 2 lines'])
})

test('Run on a command block runs it in the shell and says how it went', async ($, on) => {
  const ran: string[][] = []
  const toasts: string[] = []
  on('process.run', ($, e) => {
    ran.push([...e.argv])
    return { value: { exitCode: 0, stdout: 'ok', stderr: '' } }
  })
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('env.get', () => ({ value: '/bin/zsh' }))
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.render', () => ENGINE)
  const ui = await $.ui.mount({ ...REPLY, props: { text: 'Update:\n\n```\n! claude plugin update x@y\n```', isFirstOfReply: true } })
  await ui.press({ key: 'part-1-run' })
  expect(ran[0].at(-1)).toBe('claude plugin update x@y')
  expect(toasts).toContain('Ran the command')
})

test('Run asks first for a destructive command', async ($, on) => {
  const ran: string[][] = []
  on('process.run', ($, e) => {
    ran.push([...e.argv])
    return { value: { exitCode: 0, stdout: '', stderr: '' } }
  })
  on('ui.render', () => ENGINE)
  const ui = await $.ui.mount({ ...REPLY, props: { text: 'Clean:\n\n```sh\nrm -rf build\n```', isFirstOfReply: true } })
  await ui.press({ key: 'part-1-run' })
  expect(ran).toEqual([])
})
