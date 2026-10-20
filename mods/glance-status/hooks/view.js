// The Status pane, kept short: what Claude is doing (and whether it needs you), the plan if there is one, the last few
// steps, and one line of usage. The token and context detail sits behind a "Details" button. Text takes Claude Code
// theme keys; the scan line and the plan bar are the only Rasters.

import { clock, compact, fit, folderName, limitLabel, modelLabel, words } from './format.js'
import { encode, hex, scanLine, segmentBar, track } from './raster.js'
import { elapsedOf, ordered, running, statusColor, titleOf } from './shells.js'
import { nowView, planView, sessionTokens, turnShown } from './tracker.js'

const ON_FILL = '#1c1a17'

export const LABEL = 8
const RIGHT = 6 // the n/m column
const RECENT = 3

export function scanWidth(columns) {
  return Math.max(1, columns - LABEL)
}

export function drawStatus(el, snap, columns, actions) {
  const { Text } = el
  const w = scanWidth(columns)
  const gap = (key) => Text({ key, children: [' '] })
  const sections = [
    ['NOW', now(el, snap, w)],
    ['PLAN', plan(el, snap, w)],
    ['RECENT', recent(el, snap, w)],
    ['SHELLS', shells(el, snap, w, actions)],
    ['USAGE', usage(el, snap, w, actions)],
  ].filter(([, rows]) => rows.length > 0)
  return el.Box({
    flexDirection: 'column',
    children: [
      header(el, snap, columns),
      ...sections.flatMap(([label, rows]) => [gap(`gap-${label}`), section(el, label, rows)]),
      gap('gap-footer'),
      footer(el, snap, actions),
    ],
  })
}

function header(el, snap, columns) {
  const { Box, Text } = el
  const n = nowView(snap.t, snap.at)
  const [label, fill] = n.state === 'working' ? ['WORKING', snap.pal.teal] : n.state === 'waiting' ? ['NEEDS YOU', snap.pal.amber] : ['IDLE', snap.pal.line]
  const where = [folderName(snap.cwd), modelLabel(snap.model)].filter(Boolean).join(' · ')
  return Box({
    key: 'status-header',
    flexDirection: 'row',
    children: [
      Text({ color: 'claude', children: ['● '] }),
      Text({ bold: true, children: ['Status'] }),
      Text({ color: 'inactive', wrap: 'truncate-end', children: [`   ${fit(where, Math.max(0, columns - 26))}`] }),
      Box({ flexGrow: 1 }),
      Text({ bold: true, backgroundColor: hex(fill), color: n.state === 'idle' ? 'inactive' : ON_FILL, children: [` ${label} `] }),
    ],
  })
}

function section(el, label, rows) {
  const { Box, Text } = el
  return Box({
    key: `status-${label.toLowerCase()}`,
    flexDirection: 'row',
    children: [
      Text({ bold: true, color: 'inactive', children: [label.padEnd(LABEL)] }),
      Box({ flexDirection: 'column', flexGrow: 1, children: rows }),
    ],
  })
}

function line(el, key, children) {
  return el.Box({ key, flexDirection: 'row', children })
}

function raster(el, key, cells) {
  return el.Raster({ key, columns: cells.length / 3, rows: 1, cells: encode(cells) })
}

function now(el, snap, w) {
  const { Text, Box } = el
  const { t, pal } = snap
  const n = nowView(t, snap.at)
  const color = n.state === 'waiting' ? 'warning' : n.state === 'idle' ? 'inactive' : n.isThinking ? 'planMode' : undefined
  const time = n.elapsedMs === null ? '' : clock(n.elapsedMs)
  const rows = [
    line(el, 'now-phrase', [
      Text({ bold: n.state !== 'idle', color, wrap: 'truncate-end', children: [fit(n.phrase, Math.max(1, w - time.length - 2))] }),
      Box({ flexGrow: 1 }),
      Text({ color: 'inactive', children: [time] }),
    ]),
  ]
  if (n.state === 'working') rows.push(raster(el, 'status-scan', scanLine(w, snap.scanPhase, pal)))
  if (n.state === 'waiting') rows.push(raster(el, 'status-scan', track(w, pal.amber)))
  if (t.agents.size > 0) {
    const n = t.agents.size
    rows.push(Text({ key: 'now-agents', color: 'inactive', wrap: 'truncate-end', children: [fit(`${n} helper agent${n === 1 ? '' : 's'} running`, w)] }))
  }
  return rows
}

// Nothing when Claude has made no plan: an empty section is noise.
function plan(el, snap, w) {
  const { Text, Box } = el
  const { t, pal } = snap
  const v = planView(t.plan, 2)
  if (v.total === 0) return []
  const fills = t.plan.map((p) => (p.status === 'completed' ? 'done' : p.status === 'in_progress' ? 'current' : 'pending'))
  const rows = [
    line(el, 'plan-bar', [
      raster(el, 'status-plan', segmentBar(Math.max(1, w - RIGHT), fills, pal)),
      Box({ flexGrow: 1 }),
      Text({ children: [`${v.done}/${v.total}`] }),
    ]),
  ]
  if (v.current) {
    rows.push(line(el, 'plan-current', [Text({ color: 'claude', children: ['◐ '] }), Text({ bold: true, wrap: 'truncate-end', children: [fit(v.current.activeForm, w - 2)] })]))
  }
  v.pending.forEach((p, i) => {
    rows.push(line(el, `plan-p-${i}`, [Text({ color: 'inactive', wrap: 'truncate-end', children: [`○ ${fit(p.content, w - 2)}`] })]))
  })
  if (v.more > 0) rows.push(Text({ key: 'plan-more', color: 'inactive', children: [`  …and ${v.more} more`] }))
  return rows
}

// The last few steps, newest first, as plain "Tool  target" lines.
function recent(el, snap, w) {
  const { Text } = el
  const shown = turnShown(snap.t)
  if (!shown || shown.steps.length === 0) return []
  return shown.steps.slice(-RECENT).reverse().map((s, i) =>
    line(el, `recent-${i}`, [
      Text({ color: s.failed ? 'error' : 'inactive', children: [s.failed ? '✗ ' : '· '] }),
      Text({ color: 'inactive', children: [`${s.tool}  `] }),
      Text({ wrap: 'truncate-end', children: [fit(s.target || s.verb, Math.max(1, w - s.tool.length - 4))] }),
    ]),
  )
}

// Background shells, one plain line each (title and time), and a button to the Shells pane. Nothing without a shell.
function shells(el, snap, w, actions) {
  const { Text, Box } = el
  if (!snap.shells || snap.shells.list.length === 0) return []
  const live = running(snap.shells)
  const shown = (live.length > 0 ? live : ordered(snap.shells)).slice(0, 3)
  const rows = shown.map((sh) => {
    const time = clock(elapsedOf(sh, snap.at))
    return line(el, `shell-${sh.callId}`, [
      Text({ color: statusColor(sh), children: [sh.endedAt === null ? '● ' : '○ '] }),
      Text({ wrap: 'truncate-end', children: [fit(titleOf(sh), Math.max(1, w - time.length - 4))] }),
      Box({ flexGrow: 1 }),
      Text({ color: 'inactive', children: [time] }),
    ])
  })
  rows.push(el.Button({ key: 'status-shells', label: '▸ Open Shells', plain: true, dimColor: true, onPress: () => actions.openShells?.() }))
  return rows
}

// One line of plain figures (context used, cost, rate limits), amber from 80% and red from 95%, and a Details button
// that opens the token and context numbers.
function usage(el, snap, w, actions) {
  const { Text } = el
  const { t } = snap
  const c = t.measure.context
  const pct = typeof c?.percent === 'number' ? c.percent : null
  const tone = (p) => (p >= 95 ? 'error' : p >= 80 ? 'warning' : undefined)
  const parts = []
  if (pct !== null) parts.push({ text: `${pct}% context used`, color: tone(pct) })
  if (t.measure.cost) parts.push({ text: `$${t.measure.cost.usd.toFixed(2)}` })
  for (const r of t.measure.rateLimits) {
    const p = Math.round(r.percentUsed)
    parts.push({ text: `${limitLabel(r.kind)} limit ${p}%`, color: tone(p) })
  }
  if (parts.length === 0 && sessionTokens(t) === 0) return []
  const rows = [
    line(el, 'usage-line', parts.flatMap((p, i) => [
      ...(i > 0 ? [Text({ key: `usage-sep-${i}`, color: 'inactive', children: [' · '] })] : []),
      Text({ key: `usage-${i}`, color: p.color, children: [p.text] }),
    ])),
  ]
  rows.push(el.Button({ key: 'status-details', label: `${snap.details ? '▾' : '▸'} Details`, plain: true, dimColor: !snap.details, onPress: () => actions.toggleDetails?.() }))
  if (snap.details) {
    const detail = []
    if (c?.tokens !== undefined) detail.push(`Context window  ${compact(c.tokens)} of ${compact(c.window)}`)
    detail.push(`Tokens  ${compact(sessionTokens(t))} (in ${compact(t.tokens.input + t.tokens.cacheWrite)}, out ${compact(t.tokens.output)})`)
    if (t.tokens.cacheRead > 0) detail.push(`Cache reads  ${compact(t.tokens.cacheRead)}`)
    if (t.lastTurn) detail.push(`Last turn  ${compact(t.lastTurn.tokens)} tokens in ${words(t.lastTurn.durationMs)}`)
    detail.forEach((d, i) => rows.push(Text({ key: `detail-${i}`, color: 'inactive', wrap: 'truncate-end', children: [fit(d, w)] })))
  }
  return rows
}

// The chip on the hint line under the prompt (spec §1): the running step, plan count and context while Claude works,
// "Status" and the cost when idle. A press opens the pane.
export const HINT_MAX = 48

export function drawHint(el, snap, open) {
  const { Box, Text, Button } = el
  const n = nowView(snap.t, snap.at)
  const v = planView(snap.t.plan)
  const pct = snap.t.measure.context?.percent
  const cost = snap.t.measure.cost
  const parts =
    n.state === 'idle'
      ? ['Status', cost ? `$${cost.usd.toFixed(2)}` : null]
      : [n.phrase, v.total > 0 ? `${v.done}/${v.total}` : null, typeof pct === 'number' ? `${pct}%` : null]
  const [dot, color] = n.state === 'working' ? ['● ', 'planMode'] : n.state === 'waiting' ? ['● ', 'warning'] : ['○ ', 'inactive']
  return Box({
    key: 'status-hint',
    flexDirection: 'row',
    children: [
      Text({ color, children: [dot] }),
      Button({ key: 'status-open', label: fit(parts.filter(Boolean).join(' · '), HINT_MAX - 2), plain: true, dimColor: n.state === 'idle', onPress: () => open() }),
    ],
  })
}

function footer(el, snap, actions) {
  const { Box, Text, Button } = el
  return line(el, 'status-footer', [
    Box({ flexGrow: 1 }),
    Text({ backgroundColor: hex(snap.pal.line), color: 'inactive', children: [' Esc '] }),
    Text({ children: [' '] }),
    Button({ key: 'status-close', label: 'Close', plain: true, onPress: () => actions.close() }),
  ])
}
