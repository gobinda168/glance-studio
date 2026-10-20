// Which code blocks in a reply are commands Glance can run, and when running one asks first.

const SHELLS = new Set(['bash', 'sh', 'shell', 'zsh', 'console'])

// Patterns that make a command ask before it runs, however short.
const RISKY = [
  /\brm\s+(-[a-z]*\s+)*-[a-z]*[rf]/i,
  /\bsudo\b/,
  /\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(ba|z|da)?sh\b/,
  /\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f|push\s+(-f|--force))/,
  /\bmkfs\b|\bdd\s+if=|>\s*\/dev\/(sd|disk)/,
  /\bchmod\s+-R\b|\bchown\s+-R\b/,
]

// The runnable command of a code block, or null: a `!` line (Claude Code's shell mode) or a shell-language block.
export function commandOf(lang, source) {
  const body = source.replace(/\s+$/, '')
  if (body.trim() === '') return null
  const first = body.split('\n').find((line) => line.trim() !== '') ?? ''
  const isBang = /^\s*!\s*\S/.test(first)
  if (!isBang && !SHELLS.has((lang || '').toLowerCase())) return null
  const lines = body.split('\n').map((line) => (isBang ? line.replace(/^(\s*)!\s?/, '$1') : line))
  // A `$ ` prompt in front of a line is decoration, not part of the command.
  const stripped = SHELLS.has((lang || '').toLowerCase()) && lines.every((l) => l.trim() === '' || /^\s*\$\s/.test(l))
  const text = (stripped ? lines.map((l) => l.replace(/^(\s*)\$\s/, '$1')) : lines).join('\n').trim()
  return text === '' ? null : { text, isBang }
}

// Several lines or anything destructive: the first press asks, the second runs.
export function needsConfirm(command) {
  return command.includes('\n') || RISKY.some((pattern) => pattern.test(command))
}

// The last `max` lines of the output, and how many were left out above.
export function tail(output, max) {
  const lines = output.replace(/\s+$/, '').split('\n')
  return lines.length <= max ? { text: lines.join('\n'), hidden: 0 } : { text: lines.slice(-max).join('\n'), hidden: lines.length - max }
}
