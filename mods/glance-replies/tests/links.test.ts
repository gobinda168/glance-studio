import { expect, test } from 'claude-code/testing'
import { absolutePath, fileURL, linkTargets, rewriteLinks, splitTarget } from '../hooks/links.js'

test('lists file-like link targets and code spans, not web links or plain code', async () => {
  const text = [
    'See [App.swift:12](Sources/App.swift#L12), [docs](https://example.com) and [top](#intro).',
    'Run `npm test` in `Sources/App.swift:30`, or open `README.md`.',
    '```',
    '[inside](Sources/Nope.swift) `Sources/Nope.swift`',
    '```',
    '[abs](/Users/me/a.txt) [url](file:///Users/me/b.txt)',
  ].join('\n')
  expect(linkTargets(text)).toEqual([
    'Sources/App.swift#L12',
    'Sources/App.swift:30',
    'README.md',
    '/Users/me/a.txt',
    'file:///Users/me/b.txt',
  ])
})

test('a code span inside a link label is the label, not a target', async () => {
  expect(linkTargets('[`App.swift`](https://x.dev)')).toEqual([])
})

test('splits lines and columns off a target', async () => {
  expect(splitTarget('Sources/App.swift#L12')).toEqual({ path: 'Sources/App.swift', line: 12, column: undefined })
  expect(splitTarget('Sources/App.swift#L12C4-L20')).toEqual({ path: 'Sources/App.swift', line: 12, column: 4 })
  expect(splitTarget('a.txt:3:9')).toEqual({ path: 'a.txt', line: 3, column: 9 })
  expect(splitTarget('file:///Users/me/My%20App/a.txt')).toEqual({ path: '/Users/me/My App/a.txt', line: undefined, column: undefined })
})

test('resolves paths against the session folder and home', async () => {
  expect(absolutePath('Sources/../README.md', '/work/app', '/Users/me')).toBe('/work/app/README.md')
  expect(absolutePath('/etc/hosts', '/work', '/Users/me')).toBe('/etc/hosts')
  expect(absolutePath('~/notes.md', '/work', '/Users/me')).toBe('/Users/me/notes.md')
})

test('file URLs are encoded and carry the line after a colon', async () => {
  expect(fileURL('/Users/me/My App/a#1.swift', 12, 3)).toBe('file:///Users/me/My%20App/a%231.swift:12:3')
  expect(fileURL('/a.txt')).toBe('file:///a.txt')
})

test('rewrites what was found, outside code fences only', async () => {
  const files = new Map([
    ['Sources/App.swift#L12', 'file:///w/Sources/App.swift:12'],
    ['README.md', 'file:///w/README.md'],
  ])
  const text = 'See [App.swift:12](Sources/App.swift#L12) and `README.md`, not [x](Sources/Gone.swift).\n```\n`README.md`\n```'
  expect(rewriteLinks(text, files)).toBe(
    'See [App.swift:12](file:///w/Sources/App.swift:12) and [`README.md`](file:///w/README.md), not [x](Sources/Gone.swift).\n```\n`README.md`\n```',
  )
})
