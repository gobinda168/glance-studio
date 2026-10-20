// Numbers, times and names as the Status pane shows them: mono columns that don't jump as they change.

export function clock(ms) {
  const s = Math.max(0, Math.floor(ms / 1000))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const two = (n) => String(n).padStart(2, '0')
  return h > 0 ? `${h}:${two(m)}:${two(s % 60)}` : `${m}:${two(s % 60)}`
}

export function words(ms) {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return `${s}s`
  if (s < 3600) return s % 60 === 0 ? `${Math.floor(s / 60)}m` : `${Math.floor(s / 60)}m ${s % 60}s`
  const m = Math.floor((s % 3600) / 60)
  return m === 0 ? `${Math.floor(s / 3600)}h` : `${Math.floor(s / 3600)}h ${m}m`
}

export function ago(ms) {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 10) return 'just now'
  if (s < 60) return `${s}s ago`
  if (s < 3600) return `${Math.round(s / 60)}m ago`
  return `${Math.round(s / 3600)}h ago`
}

export function compact(n) {
  const one = (x) => x.toFixed(1).replace(/\.0$/, '')
  if (n < 1000) return String(Math.round(n))
  if (n < 10_000) return `${one(n / 1000)}k`
  if (n < 1_000_000) return `${Math.round(n / 1000)}k`
  if (n < 10_000_000) return `${one(n / 1_000_000)}M`
  return `${Math.round(n / 1_000_000)}M`
}

// `claude-opus-5-5` → `Opus 5.5`; anything else as it came.
export function modelLabel(id) {
  const m = /^claude-([a-z]+)-(\d+)-(\d+)/.exec(id ?? '')
  return m ? `${m[1][0].toUpperCase()}${m[1].slice(1)} ${m[2]}.${m[3]}` : (id ?? '')
}

export function limitLabel(kind) {
  return { five_hour: '5h', seven_day: 'week' }[kind] ?? kind.replace(/_/g, ' ')
}

export function folderName(path) {
  return (path ?? '').replace(/\/+$/, '').split('/').pop() ?? ''
}

// `text` in at most `max` columns: a sentence loses its end, a path its start (the file name is what matters).
export function fit(text, max) {
  if (max <= 0) return ''
  if (text.length <= max) return text
  if (max === 1) return '…'
  const isPath = text.includes('/') && !text.includes(' ')
  return isPath ? `…${text.slice(text.length - (max - 1))}` : `${text.slice(0, max - 1)}…`
}
