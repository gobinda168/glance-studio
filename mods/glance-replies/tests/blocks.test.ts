import { expect, test } from 'claude-code/testing'
import { hasOwnParts, parseReply } from '../hooks/blocks.js'

test('a reply with nothing of ours stays one markdown part', async () => {
  const parts = parseReply('Some **bold** text.\n\n| a | b |\n|---|---|\n| 1 | 2 |')
  expect(parts).toEqual([{ kind: 'markdown', text: 'Some **bold** text.\n\n| a | b |\n|---|---|\n| 1 | 2 |' }])
  expect(hasOwnParts(parts)).toBe(false)
})

test('headings are parts of their own', async () => {
  expect(parseReply('# Title\n\nText.\n\n### Small `code` #')).toEqual([
    { kind: 'heading', level: 1, text: 'Title' },
    { kind: 'markdown', text: 'Text.' },
    { kind: 'heading', level: 3, text: 'Small `code`' },
  ])
})

test('an alert takes its quoted lines and nothing after', async () => {
  const parts = parseReply('Before.\n\n> [!WARNING]\n> Line one\n> Line `two`\n\nAfter.')
  expect(parts).toEqual([
    { kind: 'markdown', text: 'Before.' },
    { kind: 'alert', type: 'WARNING', body: 'Line one\nLine `two`' },
    { kind: 'markdown', text: 'After.' },
  ])
})

test('a plain quote is a quote, not an alert', async () => {
  expect(parseReply('> just a quote\n> [!NOTE] not on its own line')).toEqual([
    { kind: 'quote', body: 'just a quote\n[!NOTE] not on its own line' },
  ])
})

test('a closed code fence is code; an open one (mid-stream) stays markdown', async () => {
  expect(parseReply('Run:\n\n```sh\nmake test\n```')).toEqual([
    { kind: 'markdown', text: 'Run:' },
    { kind: 'code', lang: 'sh', source: 'make test' },
  ])
  expect(hasOwnParts(parseReply('```sh\nmake'))).toBe(false)
})

test('a list keeps its items, depth, numbers, tasks and continuation lines', async () => {
  const parts = parseReply('- [x] done\n- [ ] open\n  - [X] nested\n- plain **bullet**\n  more of it\n\nAfter.')
  expect(parts).toEqual([
    {
      kind: 'list',
      items: [
        { depth: 0, marker: '•', task: true, text: 'done' },
        { depth: 0, marker: '•', task: false, text: 'open' },
        { depth: 1, marker: '•', task: true, text: 'nested' },
        { depth: 0, marker: '•', task: undefined, text: 'plain **bullet**\nmore of it' },
      ],
    },
    { kind: 'markdown', text: 'After.' },
  ])
})

test('numbered lists, nested bullets, and blank lines inside a list', async () => {
  const parts = parseReply('1. First\n   - nested\n\n2) Second\n\nDone.')
  expect(parts).toEqual([
    {
      kind: 'list',
      items: [
        { depth: 0, marker: '1.', task: undefined, text: 'First' },
        { depth: 1, marker: '•', task: undefined, text: 'nested' },
        { depth: 0, marker: '2.', task: undefined, text: 'Second' },
      ],
    },
    { kind: 'markdown', text: 'Done.' },
  ])
})

test('a list holding a code fence stays markdown', async () => {
  const text = '- step:\n  ```sh\n  make\n  ```\n- next'
  expect(hasOwnParts(parseReply(text))).toBe(false)
})

test('* * * is a rule, not a list', async () => {
  expect(parseReply('Text\n\n* * *').map((part) => part.kind)).toEqual(['markdown', 'rule'])
})

test('a closed mermaid fence becomes a diagram', async () => {
  const parts = parseReply('Look:\n\n```mermaid\ngraph TD\n  A --> B\n```\n')
  expect(parts).toEqual([
    { kind: 'markdown', text: 'Look:' },
    { kind: 'mermaid', source: 'graph TD\n  A --> B' },
  ])
})

test('an open mermaid fence (mid-stream) stays markdown', async () => {
  expect(hasOwnParts(parseReply('```mermaid\ngraph TD\n  A --> B'))).toBe(false)
})

test('nothing inside a code fence is ours', async () => {
  const source = '> [!NOTE]\n> x\n- [ ] y\n# h\n\n---\n```mermaid\ngraph TD\n```'
  expect(parseReply('````md\n' + source + '\n````')).toEqual([{ kind: 'code', lang: 'md', source }])
})

test('--- after a blank line is a rule, after text it is a heading underline', async () => {
  expect(parseReply('One\n\n---\n\nTwo').map((part) => part.kind)).toEqual(['markdown', 'rule', 'markdown'])
  expect(hasOwnParts(parseReply('Heading\n---\nBody'))).toBe(false)
})
