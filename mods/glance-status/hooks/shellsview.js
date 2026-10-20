// The Shells pane: every background shell in plain words. A list (status dot, title, time), and for the one picked its
// short command (the full one behind a button, with Copy), the last lines of its output, and Stop.

import { clock, fit } from './format.js'
import { elapsedOf, ordered, running, selectedShell, shortCommand, statusColor, statusWord, titleOf } from './shells.js'

const LABEL = 9
const LIST_MAX = 6
export const TAIL_ROWS = 8

export function tailWidth(columns) {
  return Math.max(10, columns - LABEL)
}

// snap: { shells, at, output: { lines, state }, columns }; actions: select(callId), toggleCommand, copy, stop, close.
export function drawShells(el, snap, columns, actions) {
  const { Box, Text } = el
  const { shells, at } = snap
  const gap = (key) => Text({ key, children: [' '] })
  const sh = selectedShell(shells)
  const all = ordered(shells)
  if (!sh) {
    return Box({
      flexDirection: 'column',
      children: [header(el, snap), gap('g0'), Text({ key: 'empty', color: 'inactive', children: ['No background shells yet. When Claude runs a command in the background, it shows up here.'] }), gap('g1'), footer(el, null, actions)],
    })
  }
  const w = Math.max(10, columns - LABEL)
  return Box({
    flexDirection: 'column',
    children: [
      header(el, snap),
      gap('g-list'),
      ...list(el, all, sh, at, columns, actions),
      gap('g-detail'),
      Box({ key: 'detail-title', flexDirection: 'row', children: [Text({ bold: true, wrap: 'truncate-end', children: [fit(titleOf(sh), columns)] })] }),
      gap('g-facts'),
      ...facts(el, sh, shells, at, w, actions),
      gap('g-output'),
      output(el, sh, snap, w),
      gap('g-footer'),
      footer(el, sh, actions),
    ],
  })
}

function header(el, snap) {
  const { Box, Text } = el
  const n = running(snap.shells).length
  return Box({
    key: 'shells-header',
    flexDirection: 'row',
    children: [
      Text({ color: 'claude', children: ['● '] }),
      Text({ bold: true, children: ['Shells'] }),
      Text({ color: 'inactive', children: [`   ${n === 0 ? 'none running' : `${n} running`}`] }),
    ],
  })
}

function list(el, all, sel, at, columns, actions) {
  const { Box, Text, Button } = el
  const shown = all.slice(0, LIST_MAX)
  const rows = shown.map((sh) => {
    const time = clock(elapsedOf(sh, at))
    const on = sh.callId === sel.callId
    return Box({
      key: `shell-${sh.callId}`,
      flexDirection: 'row',
      children: [
        Text({ color: statusColor(sh), children: [sh.endedAt === null ? '● ' : '○ '] }),
        Button({ key: `pick-${sh.callId}`, label: `${on ? '▸ ' : '  '}${fit(titleOf(sh), Math.max(8, columns - time.length - 8))}`, plain: true, dimColor: !on, onPress: () => actions.select(sh.callId) }),
        Box({ flexGrow: 1 }),
        Text({ color: 'inactive', children: [time] }),
      ],
    })
  })
  if (all.length > shown.length) rows.push(Text({ key: 'shell-more', color: 'inactive', children: [`  …and ${all.length - shown.length} older`] }))
  return rows
}

function facts(el, sh, shells, at, w, actions) {
  const { Box, Text, Button } = el
  const rows = [
    row(el, 'status', 'STATUS', [
      Text({ bold: true, color: statusColor(sh), children: [`${statusWord(sh)}  `] }),
      Text({ color: 'inactive', children: [`${sh.endedAt === null ? 'for ' : 'ran '}${clock(elapsedOf(sh, at))}`] }),
    ]),
  ]
  const full = sh.command.trim()
  const short = shortCommand(full)
  const same = short === full
  const body = shells.expanded ? full : short
  rows.push(
    row(el, 'command', 'COMMAND', [
      Box({
        flexDirection: 'column',
        flexGrow: 1,
        children: [
          Text({ key: 'cmd-text', wrap: shells.expanded ? 'wrap' : 'truncate-end', children: [shells.expanded ? body : fit(body.split('\n')[0], w)] }),
          Box({
            key: 'cmd-actions',
            flexDirection: 'row',
            children: [
              ...(same ? [] : [Button({ key: 'cmd-expand', label: shells.expanded ? '▾ Show less' : '▸ Show full command', plain: true, dimColor: true, onPress: () => actions.toggleCommand() })]),
              ...(same ? [] : [Text({ children: ['   '] })]),
              Button({ key: 'cmd-copy', label: shells.copied ? '✓ Copied' : 'Copy', plain: true, dimColor: !shells.copied, onPress: () => actions.copy() }),
            ],
          }),
        ],
      }),
    ]),
  )
  return rows
}

function output(el, sh, snap, w) {
  const { Box, Text } = el
  const o = snap.output
  const rows = []
  if (o.state === 'lines') {
    o.lines.forEach((l, i) => rows.push(Text({ key: `out-${i}`, wrap: 'truncate-end', children: [l] })))
    if (sh.endedAt === null) rows.push(Text({ key: 'out-live', color: 'inactive', children: ['live · updates every second'] }))
  } else if (o.state === 'empty') {
    rows.push(Text({ key: 'out-none', color: 'inactive', wrap: 'wrap', children: [sh.endedAt === null ? 'Nothing printed yet. The command is still running, and many commands stay quiet until they finish.' : 'It finished without printing anything.'] }))
  } else {
    rows.push(Text({ key: 'out-unavailable', color: 'inactive', wrap: 'wrap', children: ["Can't read this shell's output from here. Ask Claude what it prints, or open Claude Code's own Shell details."] }))
  }
  return row(el, 'output', 'OUTPUT', [Box({ flexDirection: 'column', flexGrow: 1, children: rows })])
}

function row(el, key, label, children) {
  const { Box, Text } = el
  return Box({ key: `row-${key}`, flexDirection: 'row', children: [Text({ bold: true, color: 'inactive', children: [label.padEnd(LABEL)] }), ...children] })
}

function footer(el, sh, actions) {
  const { Box, Text, Button } = el
  const stopping = sh && actions.isStopping?.(sh.callId)
  return Box({
    key: 'shells-footer',
    flexDirection: 'row',
    children: [
      ...(sh && sh.endedAt === null ? [Button({ key: 'shell-stop', label: stopping ? 'Stopping…' : '■ Stop this shell', plain: true, onPress: () => actions.stop(sh.callId) })] : []),
      Box({ flexGrow: 1 }),
      Text({ color: 'inactive', children: [' Esc '] }),
      Text({ children: [' '] }),
      Button({ key: 'shells-close', label: 'Close', plain: true, onPress: () => actions.close() }),
    ],
  })
}
