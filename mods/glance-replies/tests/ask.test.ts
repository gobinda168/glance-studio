import { expect, test, type TestBody } from 'claude-code/testing'
import { askPrompt } from '../hooks/register.js'

test('the question reads the reply, the selection and the thread so far', async () => {
  const prompt = askPrompt({
    selection: 'publishes an event',
    reply: 'In EDA, a service publishes an event.',
    turns: [
      { question: 'what is an event?', answer: 'A fact that happened.', failure: null },
      { question: 'and a command?', answer: null, failure: null },
    ],
  })
  expect(prompt).toBe(
    'The reply the passage is from:\n<reply>\nIn EDA, a service publishes an event.\n</reply>\n\n' +
      'The selected passage:\n<selection>\npublishes an event\n</selection>\n\n' +
      'Earlier question: what is an event?\nYour answer: A fact that happened.\n\n' +
      'Question: and a command?',
  )
})

// The engine beneath the history: the session, its clock and an in-memory store.
function keepAsks(on: Parameters<TestBody>[1]) {
  const store = new Map<string, unknown>()
  on('store.get', ($, e) => ({ value: store.get(e.key) }))
  on('store.set', ($, e) => {
    store.set(e.key, e.value)
    return { value: undefined }
  })
  on('store.delete', ($, e) => {
    store.delete(e.key)
    return { value: undefined }
  })
  on('session.id', () => ({ value: 'session-1' }))
  on('clock.now', () => ({ value: 10 * 60000 }))
  return store
}

const PANE = {
  plugin: 'glance-replies',
  component: 'Pane',
  requestId: 'glance-ask',
  surface: 'terminal',
  viewport: { columns: 160, rows: 40, isFullscreen: true },
  props: { title: 'Ask', isFocused: true, bodyColumns: 50, placement: 'dock', scroll: { offset: 0, bodyRows: 30 }, view: {} },
} as const

test('/ask opens the pane on the selection and answers in it', async ($, on) => {
  keepAsks(on)
  on('ui.selection', () => ({ value: { text: 'publishes an event' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.model', () => ({ value: 'claude-test' }))
  let asked = ''
  on('model.complete', ($, e) => {
    asked = e.prompt
    return { value: { isAnswered: true, text: 'A **fact** that happened.', usage: { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } }
  })
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['drawn by Claude Code'] }))
  const answer = await $.command.run({ command: 'ask', args: 'what is an event?' })
  expect(answer).toEqual({})
  expect(asked).toContain('<selection>\npublishes an event\n</selection>')
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: '› what is an event?' })).toBeDefined()
  expect(await ui.find({ type: 'Markdown', text: 'A **fact** that happened.' })).toBeDefined()
  expect(await ui.find({ key: 'ask-input' })).toBeDefined()
})

test('/ask with nothing selected and nothing asked before says so', async ($, on) => {
  keepAsks(on)
  on('ui.selection', () => ({ value: undefined }))
  const answer = await $.command.run({ command: 'ask', args: '' })
  expect(answer.text).toMatch(/Select some text/)
})

test('an earlier ask stays in the history and opens again for a follow-up', async ($, on) => {
  const store = keepAsks(on)
  let selected: { text: string } | undefined = { text: 'publishes an event' }
  on('ui.selection', () => ({ value: selected }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.close', () => ({ value: undefined }))
  on('session.model', () => ({ value: 'claude-test' }))
  const prompts: string[] = []
  on('model.complete', ($, e) => {
    prompts.push(e.prompt)
    return { value: { isAnswered: true, text: `answer ${prompts.length}`, usage: { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } }
  })
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['drawn by Claude Code'] }))

  await $.command.run({ command: 'ask', args: 'what is an event?' })
  expect(store.get('asks:session-1')).toEqual([
    {
      selection: 'publishes an event',
      reply: '',
      at: 10 * 60000,
      turns: [{ question: 'what is an event?', answer: 'answer 1', failure: null }],
    },
  ])

  // Nothing selected: /ask shows the history.
  selected = undefined
  expect(await $.command.run({ command: 'ask', args: '' })).toEqual({})
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: 'HISTORY · 1 ask' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '▎ publishes an event' })).toBeDefined()

  // Its row opens the thread again, and a follow-up reads the earlier answer.
  await ui.press({ key: 'ask-thread-0-open' })
  expect(await ui.find({ type: 'Markdown', text: 'answer 1' })).toBeDefined()
  await ui.input({ key: 'ask-input', text: 'and a command?' })
  expect(prompts[1] ?? '').toContain('Earlier question: what is an event?\nYour answer: answer 1')
  expect(await ui.find({ type: 'Markdown', text: 'answer 2' })).toBeDefined()
  expect((store.get('asks:session-1') as { turns: unknown[] }[])[0].turns).toHaveLength(2)
})
