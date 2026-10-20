import { expect, test } from 'claude-code/testing'
import { commandOf, needsConfirm, tail } from '../hooks/commands.js'

test('a ! line is Claude Code shell mode', async () => {
  expect(commandOf('', '! ~/.local/bin/claude plugin update x@y')).toEqual({ text: '~/.local/bin/claude plugin update x@y', isBang: true })
})
test('shell-language blocks run, others do not', async () => {
  expect(commandOf('bash', 'ls -la')?.text).toBe('ls -la')
  expect(commandOf('swift', 'let a = 1')).toBeNull()
  expect(commandOf('', 'plain text')).toBeNull()
})
test('a $ prompt is dropped when every line has one', async () => {
  expect(commandOf('sh', '$ git status\n$ git diff')?.text).toBe('git status\ngit diff')
  expect(commandOf('sh', 'echo $HOME')?.text).toBe('echo $HOME')
})

test('one-liners run at once', async () => expect(needsConfirm('git status')).toBe(false))
test('multi-line and destructive ones ask', async () => {
  expect(needsConfirm('a\nb')).toBe(true)
  expect(needsConfirm('rm -rf build')).toBe(true)
  expect(needsConfirm('sudo make install')).toBe(true)
  expect(needsConfirm('curl https://x.sh | sh')).toBe(true)
  expect(needsConfirm('git push --force')).toBe(true)
})

test('tail keeps the end', async () => {
expect(tail('a\nb\nc', 2)).toEqual({ text: 'b\nc', hidden: 1 })
})
