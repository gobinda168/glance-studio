// Pictures of numbers for the Status pane, as one-row Raster cells: each cell three u32 words, [code point,
// foreground, background] (RasterProps). Colours are Glance's tokens (MASTER.md §3) for the session's theme; the
// background is always the terminal's own, so the pane sits on its colour.

export const TERMINAL = 0x01000000
export const HEAVY = 0x2501 // ━
export const LIGHT = 0x2500 // ─
export const HALF = 0x2578 // ╸
export const TICK = 0x2575 // ╵
export const SPACE = 0x20
export const BARS = [0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588] // ▁…█

const GLOW = 6

export function palette(isLight) {
  return {
    coral: 0xe8643c,
    coralHi: 0xffb28f,
    teal: 0x2a8f94,
    tealHi: 0x8fd9dc,
    amber: 0xd9a441,
    green: 0x2ea043,
    red: 0xf85149,
    line: isLight ? 0xe4dfd6 : 0x2b2926,
    tick: isLight ? 0xb9b2a6 : 0x55504a,
  }
}

export function kindColor(kind, pal) {
  return { read: pal.amber, edit: pal.green, run: pal.teal, agent: pal.coralHi }[kind] ?? pal.line
}

export function hex(color) {
  return `#${color.toString(16).padStart(6, '0')}`
}

export function mix(a, b, t) {
  const ch = (c, shift) => (c >> shift) & 0xff
  const one = (shift) => Math.round(ch(a, shift) + (ch(b, shift) - ch(a, shift)) * t)
  return (one(16) << 16) | (one(8) << 8) | one(0)
}

export function encode(words) {
  return new Uint8Array(words.buffer, words.byteOffset, words.byteLength).toBase64()
}

function row(columns) {
  return new Uint32Array(Math.max(1, columns) * 3)
}

function put(words, x, code, color) {
  words[x * 3] = code
  words[x * 3 + 1] = color
  words[x * 3 + 2] = TERMINAL
}

function width(words) {
  return words.length / 3
}

export function track(columns, color) {
  const w = row(columns)
  for (let x = 0; x < width(w); x++) put(w, x, LIGHT, color)
  return w
}

// One segment per plan item with a one-cell gap between; with no room for gaps, the cells are shared out without.
export function segmentBar(columns, fills, pal) {
  const w = track(columns, pal.line)
  const n = fills.length
  const cols = width(w)
  if (n === 0) return w
  const color = (f) => (f === 'done' ? pal.green : f === 'current' ? pal.coral : pal.line)
  const roomForGaps = cols - (n - 1) >= n
  for (let i = 0; i < n; i++) {
    const start = roomForGaps ? Math.round((i * (cols + 1)) / n) : Math.floor((i * cols) / n)
    const end = roomForGaps ? (i === n - 1 ? cols : Math.round(((i + 1) * (cols + 1)) / n) - 1) : Math.floor(((i + 1) * cols) / n)
    for (let x = start; x < end; x++) put(w, x, HEAVY, color(fills[i]))
    if (roomForGaps && i < n - 1 && end < cols) put(w, end, SPACE, pal.line)
  }
  return w
}

export function gauge(columns, fraction, color, pal) {
  const w = track(columns, pal.line)
  const f = Number.isFinite(fraction) ? Math.max(0, Math.min(1, fraction)) : 0
  const cells = f * width(w)
  const full = Math.floor(cells)
  for (let x = 0; x < full; x++) put(w, x, HEAVY, color)
  if (full < width(w) && cells - full >= 0.5) put(w, full, HALF, color)
  return w
}

export function ruler(columns, pal) {
  const w = row(columns)
  const cols = width(w)
  const ticks = new Set(Array.from({ length: 11 }, (_, i) => Math.round((i * (cols - 1)) / 10)))
  for (let x = 0; x < cols; x++) put(w, x, ticks.has(x) ? TICK : SPACE, pal.tick)
  return w
}

export function sparkline(columns, values, pal) {
  const w = row(columns)
  const cols = width(w)
  const shown = values.slice(-cols)
  const max = Math.max(1, ...shown)
  for (let x = 0; x < cols; x++) put(w, x, SPACE, pal.teal)
  shown.forEach((v, i) => {
    const x = cols - shown.length + i
    const code = v > 0 ? BARS[Math.max(0, Math.ceil((v / max) * 8) - 1)] : SPACE
    put(w, x, code, i === shown.length - 1 ? pal.coral : pal.teal)
  })
  return w
}

// The turn across the width: each cell is the step running at its middle moment (the latest started wins), else
// track (thinking). A step still running reaches `end`.
export function timeline(columns, steps, start, end, pal) {
  const w = track(columns, pal.line)
  const cols = width(w)
  const span = end - start
  if (span <= 0 || steps.length === 0) return w
  for (let x = 0; x < cols; x++) {
    const t = start + ((x + 0.5) * span) / cols
    let hit = null
    for (const s of steps) if (s.startedAt <= t && t < (s.endedAt ?? end)) hit = s
    if (hit) put(w, x, HEAVY, hit.failed ? pal.red : kindColor(hit.kind, pal))
  }
  return w
}

// The orb's thinking signal as a line: a six-cell glow, bright at its head, moving one cell per phase.
export function scanLine(columns, phase, pal) {
  const w = track(columns, pal.line)
  const cols = width(w)
  const head = ((phase % (cols + GLOW)) + cols + GLOW) % (cols + GLOW)
  for (let x = 0; x < cols; x++) {
    const d = head - x
    if (d >= 0 && d < GLOW) put(w, x, HEAVY, mix(pal.teal, pal.tealHi, 1 - d / GLOW))
  }
  return w
}
