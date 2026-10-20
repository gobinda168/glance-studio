// glance-status: `/progress` opens the Status pane: what Claude is doing now, where it is in its plan, and what the
// session has cost (spec docs/superpowers/specs/2026-10-11-claude-status-design.md).
//
// The mod keeps track all session (tracker.js). The hint chip under the prompt shows the running step and opens the
// pane; the pane draws while open: on each event, once a second while a turn runs, and the scan line (a Raster
// repainted by $.ui.blit) about 12 times a second. It only observes:
// every hook returns what the hooks beneath returned, and its own bookkeeping never throws into Claude Code.
//
// Glance Studio loads this mod for the shells it starts (CLAUDE_CODE_PLUGIN_DIRS); no other terminal sees it.

import { encode, palette, scanLine } from './raster.js'
import { completeTurn, endStep, newTracker, planFromMessages, setMeasure, startStep, startTurn, waitFor } from './tracker.js'
import { drawHint, drawStatus, scanWidth } from './view.js'
import { guessOutputPath, newShells, running, selectedShell, shellNotified, shellResult, shellStarted, shellsInFlight, tail } from './shells.js'
import { TAIL_ROWS, drawShells, tailWidth } from './shellsview.js'

export const PANE = 'glance-status'
export const SHELLS_PANE = 'glance-shells'
const TICK_MS = 1000
const SCAN_MS = 80

let t = newTracker()
let cwd = ''
let model = ''
let isLight = false
let isOpen = false
let details = false
let planRead = false
let scanColumns = 0
let scanPhase = 0
let stopTick = null
let stopScan = null
let lastAt = 0
let shells = newShells()
let shellsOpen = false
let shellsColumns = 80
let shellOut = { lines: [], state: 'unavailable' }
let stopShellsTick = null

export function register(on) {
  on('session.start', async ($, e, next) => {
    cwd = e.cwd ?? ''
    quietly(reset)
    await attempt(() =>
      $.command.register({
        name: 'progress',
        description: 'What Claude is doing, its plan and what the session has cost, in a pane',
        immediate: true,
      }),
    )
    await attempt(() =>
      $.command.register({
        name: 'shells',
        description: 'Background shells in plain words: what each does, how long, its output, and a Stop button',
        immediate: true,
      }),
    )
    return next(e)
  })

  // /clear, /resume and /branch start another conversation.
  on('session.end', async ($, e, next) => {
    quietly(reset)
    redraw($)
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    const at = await now($)
    quietly(() => startTurn(t, e.turnId, at))
    startTimers($)
    redraw($)
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const at = await now($)
    quietly(() => startStep(t, e, at, cwd))
    quietly(() => shellStarted(shells, e, at))
    redraw($)
    let result = { isError: true }
    try {
      result = await next(e)
      return result
    } finally {
      const end = await now($)
      quietly(() => endStep(t, e, result, end))
      quietly(() => shellResult(shells, e, result, end))
      redraw($)
    }
  })

  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (verdict?.decision === 'ask') {
      quietly(() => waitFor(t, e.tool_use_id))
      redraw($)
    }
    return verdict
  })

  on('turn.complete', async ($, e, next) => {
    const at = await now($)
    quietly(() => completeTurn(t, e, at))
    quietly(() => shellsInFlight(shells, e.background_tasks, at))
    if (!t.turn) stopTimers()
    redraw($)
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    quietly(() => setMeasure(t, e))
    redraw($)
    return next(e)
  })

  on('command.run', { command: 'progress' }, async ($) => {
    await openPane($)
    return {}
  })

  on('command.run', { command: 'shells' }, async ($) => {
    await openShells($)
    return {}
  })

  // A finished shell announces itself with a task notification row: that is how this mod learns it ended.
  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    const task = e.props?.task
    if (task?.id && e.props?.origin?.kind === 'task-notification') {
      const before = running(shells).length
      quietly(() => shellNotified(shells, task, lastAt))
      if (running(shells).length !== before) queueMicrotask(() => redraw($))
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  // The hint chip, before Claude Code's own hint (and after glance-replies' branch chip when that mod draws first).
  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    const theirs = await next(e)
    const elements = $.ui.resolve(e)
    const snap = { t, at: await now($), cwd, model, pal: palette(isLight), scanPhase }
    const chip = drawHint(elements, snap, () => openPane($))
    const n = running(shells).length
    const shellChip =
      n > 0
        ? elements.Box({
            key: 'shells-hint',
            flexDirection: 'row',
            children: [elements.Text({ children: ['   '] }), elements.Text({ color: 'planMode', children: ['● '] }), elements.Button({ key: 'shells-open', label: `${n} shell${n === 1 ? '' : 's'}`, plain: true, onPress: () => openShells($) })],
          })
        : null
    return elements.Box({ flexDirection: 'row', children: [chip, ...(shellChip ? [shellChip] : []), ...(theirs ? [elements.Text({ children: ['   '] }), theirs] : [])] })
  })

  on('ui.close', async ($, e, next) => {
    if (e.id === PANE) paneClosed()
    if (e.id === SHELLS_PANE) shellsClosed()
    return next(e)
  }).catch(($, e, next) => next(e)) // never keeps a pane open

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId === SHELLS_PANE) return drawShellsPane($, e)
    if (e.requestId !== PANE) return next(e)
    const columns = e.props.bodyColumns ?? 80
    scanColumns = scanWidth(columns)
    const snap = { t, at: await now($), cwd, model, pal: palette(isLight), scanPhase, details, shells }
    return drawStatus($.ui.resolve(e), snap, columns, {
      openShells: () => openShells($),
      toggleDetails: () => {
        details = !details
        redraw($)
      },
      // A plugin's own $ calls start beneath its hooks, so the ui.close hook never sees this one: stop here too.
      close: () => {
        paneClosed()
        return $.ui.close({ id: PANE })
      },
    })
  })
}

function drawShellsPane($, e) {
  shellsColumns = e.props.bodyColumns ?? 80
  const snap = { shells, at: lastAt, output: shellOut }
  return drawShells($.ui.resolve(e), snap, shellsColumns, {
    select: (callId) => {
      shells.selected = callId
      shells.expanded = false
      shells.copied = false
      refreshOutput($)
    },
    toggleCommand: () => {
      shells.expanded = !shells.expanded
      redraw($)
    },
    copy: async () => {
      const sh = selectedShell(shells)
      if (!sh) return
      const r = await $.ui.copy({ text: sh.command }).catch(() => null)
      shells.copied = r?.isCopied === true
      redraw($)
    },
    isStopping: (callId) => shells.stopping.has(callId),
    stop: async (callId) => {
      const sh = shells.list.find((x) => x.callId === callId)
      if (!sh?.id || shells.stopping.has(callId)) return
      shells.stopping.add(callId)
      redraw($)
      await attempt(() => $.tool.call({ tool: 'TaskStop', task_id: sh.id }))
      shells.stopping.delete(callId)
      if (sh.endedAt === null) {
        sh.status = 'stopped'
        sh.endedAt = lastAt
      }
      redraw($)
    },
    close: () => {
      shellsClosed()
      return $.ui.close({ id: SHELLS_PANE })
    },
  })
}

async function openShells($) {
  await now($)
  shellsOpen = false
  try {
    shellsOpen = (await $.ui.open({ id: SHELLS_PANE, title: 'Shells', focus: true, closeOnEscape: true }))?.isPlaced === true
  } catch {
    // Not opened: the chip stays, the pane does not.
  }
  if (shellsOpen) {
    stopShellsTick ??= $.clock.every(TICK_MS, async () => {
      await now($)
      await refreshOutput($)
    })
    await refreshOutput($)
  } else shellsClosed()
}

function shellsClosed() {
  shellsOpen = false
  shells.expanded = false
  try {
    stopShellsTick?.cancel()
  } catch {
    // Already gone.
  }
  stopShellsTick = null
}

// The picked shell's output file, read again each second while the pane is open: the last lines, or why there are none.
async function refreshOutput($) {
  const sh = selectedShell(shells)
  const path = sh ? guessOutputPath(sh) : null
  let next = { lines: [], state: 'unavailable' }
  if (path) {
    try {
      const text = await $.fs.read(path)
      const lines = tail(text, TAIL_ROWS, tailWidth(shellsColumns))
      next = lines.length > 0 ? { lines, state: 'lines' } : { lines: [], state: 'empty' }
    } catch {
      // No file yet or none readable: a running shell that has not printed shows as empty, else unavailable.
      next = sh && sh.endedAt === null ? { lines: [], state: 'empty' } : { lines: [], state: 'unavailable' }
    }
  }
  const changed = JSON.stringify(next) !== JSON.stringify(shellOut)
  shellOut = next
  if (changed || (sh && sh.endedAt === null) || shells.copied) redraw($)
}

async function openPane($) {
  await refresh($)
  // Only a pane the engine placed draws; one it could not place (too narrow) takes no timers.
  isOpen = false
  try {
    isOpen = (await $.ui.open({ id: PANE, title: 'Status', focus: true, closeOnEscape: true }))?.isPlaced === true
  } catch {
    // Not opened: the hint chip stays, the pane does not.
  }
  if (isOpen) startTimers($)
  else stopTimers()
  redraw($)
}

function paneClosed() {
  isOpen = false
  details = false
  stopTimers()
}

function reset() {
  t = newTracker()
  shells = newShells()
  shellsClosed()
  planRead = false
  stopTimers()
}

// What only an op tells: the usage so far, the model, the theme, and (once) a resumed session's plan.
async function refresh($) {
  await attempt(async () => setMeasure(t, await $.session.usage()))
  await attempt(async () => {
    model = (await $.session.model()) ?? ''
  })
  await attempt(async () => {
    const theme = (await $.config.list()).find((row) => row.key === 'theme')?.value
    isLight = typeof theme === 'string' && theme.includes('light')
  })
  if (!planRead && t.plan.length === 0) {
    planRead = true
    await attempt(async () => {
      t.plan = planFromMessages(await $.session.messages({ as: 'api' }))
    })
  }
}

function startTimers($) {
  if (!isOpen || !t.turn) return
  stopTick ??= $.clock.every(TICK_MS, () => redraw($))
  stopScan ??= $.clock.every(SCAN_MS, () => scan($))
}

// $.clock.every hands back a Timer; a cancel that throws must not keep the other one running or skip the hook.
function stopTimers() {
  const timers = [stopTick, stopScan]
  stopTick = null
  stopScan = null
  for (const timer of timers) {
    try {
      timer?.cancel()
    } catch {
      // Already gone.
    }
  }
}

// The time, or the last one read when the clock fails: a step must still start and end.
async function now($) {
  try {
    lastAt = await $.clock.now()
  } catch {
    // Keep the last reading.
  }
  return lastAt
}

function scan($) {
  if (!isOpen || !t.turn || t.waiting !== null || scanColumns === 0) return
  scanPhase += 1
  $.ui.blit({ requestId: PANE, key: 'status-scan', cells: encode(scanLine(scanColumns, scanPhase, palette(isLight))) }).catch(() => {})
}

// The hint chip follows every event, the pane too while open; the timers only run while the pane is open.
function redraw($) {
  $.ui.invalidate('ui.render')
}

function quietly(fn) {
  try {
    fn()
  } catch {
    // The pane is a view: a bookkeeping slip never reaches the tool or the turn.
  }
}

async function attempt(fn) {
  try {
    await fn()
  } catch {
    // An op this engine doesn't answer leaves that part of the pane as it was.
  }
}
