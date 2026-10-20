import { expect, test } from 'claude-code/testing'
import { describeCall, phrase } from '../hooks/phrases.js'

const CWD = '/work/acme'

test('every tool row of the spec says what it does', () => {
  const said = (call: any) => phrase(describeCall(call, CWD))
  expect(said({ tool: 'Read', file_path: '/work/acme/src/a.ts' })).toBe('Reading src/a.ts')
  expect(said({ tool: 'Edit', file_path: '/work/acme/src/a.ts' })).toBe('Editing src/a.ts')
  expect(said({ tool: 'Write', file_path: '/tmp/x.md' })).toBe('Editing /tmp/x.md')
  expect(said({ tool: 'NotebookEdit', notebook_path: '/work/acme/n.ipynb' })).toBe('Editing n.ipynb')
  expect(said({ tool: 'Bash', command: 'swift test\n--filter X', description: 'Run the tests' })).toBe('Running Run the tests')
  expect(said({ tool: 'Bash', command: 'swift test\n--filter X' })).toBe('Running swift test')
  expect(said({ tool: 'Grep', pattern: 'claudeTurn' })).toBe('Searching claudeTurn')
  expect(said({ tool: 'Glob', pattern: '**/*.swift' })).toBe('Searching **/*.swift')
  expect(said({ tool: 'Agent', description: 'map plumbing', subagent_type: 'Explore' })).toBe('Agent: map plumbing')
  expect(said({ tool: 'WebSearch', query: 'kitty graphics' })).toBe('Searching the web: kitty graphics')
  expect(said({ tool: 'WebFetch', url: 'https://example.com/a?b' })).toBe('Reading example.com')
  expect(said({ tool: 'TodoWrite', todos: [] })).toBe('Updating the plan')
  expect(said({ tool: 'TaskUpdate', taskId: '1' })).toBe('Updating the plan')
  expect(said({ tool: 'mcp__github__create_issue', title: 'x' })).toBe('github: create_issue')
  expect(said({ tool: 'LSP' })).toBe('LSP')
})

test('each call has the kind that colours it and the tool its chip names', () => {
  const kind = (call: any) => describeCall(call, CWD).kind
  expect(kind({ tool: 'Read' })).toBe('read')
  expect(kind({ tool: 'Grep' })).toBe('read')
  expect(kind({ tool: 'WebFetch', url: 'https://a.b' })).toBe('read')
  expect(kind({ tool: 'Edit' })).toBe('edit')
  expect(kind({ tool: 'Bash' })).toBe('run')
  expect(kind({ tool: 'mcp__glance__nudge' })).toBe('run')
  expect(kind({ tool: 'Agent' })).toBe('agent')
  expect(kind({ tool: 'TaskCreate' })).toBe('plan')
  expect(kind({ tool: 'LSP' })).toBe('other')
  expect(describeCall({ tool: 'mcp__github__create_issue' }, CWD).tool).toBe('github')
})

test('missing or odd arguments never throw', () => {
  expect(phrase(describeCall({ tool: 'Read' }, CWD))).toBe('Reading')
  expect(phrase(describeCall({ tool: 'Bash', command: 42 } as any, CWD))).toBe('Running')
  expect(phrase(describeCall({ tool: 'WebFetch', url: 'not a url' }, CWD))).toBe('Reading not a url')
})
