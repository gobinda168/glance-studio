// glance-replies: Claude's replies and the prompts sent to it, in Glance Studio's terminal.
//
// - Replies: GitHub alerts become coloured callouts, task lists get checkboxes, ```mermaid fences become diagrams,
//   `---` becomes a rule. Everything else (prose, lists, tables, code) stays Claude Code's own drawing.
// - File links: the files a reply names become `file://` links Studio opens in Razor on ⌘-click (links.js).
// - Images: a picture pasted into the prompt shows above it while it's written, and under the message once sent
//   (images.js). A thumbnail's caption opens the picture itself in Preview.
// - Branch: the branch Claude is working on (and its worktree), as a coral chip at the start of the line under the
//   prompt (branch.js).
// - Ask: select text in a reply and ask about it in a pane beside the transcript (`/ask`, or the band's button); the
//   answer stays out of the conversation unless you send it there.
//
// Glance Studio loads this mod for the shells it starts (CLAUDE_CODE_PLUGIN_DIRS); no other terminal sees it.

import { hasOwnParts, parseReply } from './blocks.js'
import { commandOf, needsConfirm, tail } from './commands.js'
import { BRANCH_SCRIPT, drawBranch, parseBranch, sameBranch } from './branch.js'
import {
  CLIPBOARD_SCRIPT,
  THUMBNAIL_FROM_STDIN_SCRIPT,
  THUMBNAIL_SCRIPT,
  cellSize,
  imageTokens,
  imagesOfMessage,
  parseClipboard,
  parseSize,
  recentDrops,
} from './images.js'
import { absolutePath, fileURL, linkTargets, rewriteLinks, splitTarget } from './links.js'
import { renderMermaidASCII } from './vendor/mermaid-ascii.js'

// Theme keys, so the colours follow the person's Claude Code theme (light or dark). In the default themes they land
// on Glance's palette: teal for a note, green for a tip, coral for what's important, amber and red for the warnings.
const ALERTS = {
  NOTE: { label: 'Note', icon: 'ℹ', color: 'planMode' },
  TIP: { label: 'Tip', icon: '✦', color: 'success' },
  IMPORTANT: { label: 'Important', icon: '◆', color: 'claude' },
  WARNING: { label: 'Warning', icon: '▲', color: 'warning' },
  CAUTION: { label: 'Caution', icon: '■', color: 'error' },
}

// Laying a diagram out is the costly part, and a reply redraws on every scroll and resize.
const diagrams = new Map()
const DIAGRAMS_KEPT = 64

// The session's folder (what a relative link is relative to) and the home folder (for `~`).
let cwd = ''
let home = ''
// Link target → file URL, or null when it names no file; looked up once per target.
const files = new Map()
const FILES_KEPT = 2048

// Images: thumbnails by `draft:N` (from the paste's source, while the prompt is written) and `sent:N` (from the sent
// message's own bytes), each { file, columns, rows }, or 'pending' / null (none to be had).
const thumbnails = new Map()
// Image bytes of sent messages, by number; filled as messages are stored, or from the history on a resumed session.
const sentImages = new Map()
let historyRead = false
// The numbers the draft names now, and those the transcript asked for and the worker hasn't made yet.
let draftImages = []
const wanted = new Set()
let folder = ''
let working = false
// Drops already matched to an image, so two pastes in a row don't take the same file.
const dropsUsed = new Set()

// Ask: what is selected now (polled, since nothing says), the replies' text by row (the context an answer reads), the
// thread in the pane, and this conversation's earlier threads (its history, kept in the store by session).
const ASK_PANE = 'glance-ask'
let selection = null
const replies = new Map()
const REPLIES_KEPT = 256
let ask = null
let askOpen = false
let askView = 'thread'
let asks = []

// Run: a command block's Run button runs it in the session's folder and shows the output in a pane. `runs` holds each
// command's state by its text: { status: 'confirm' | 'running' | 'done' | 'failed', output, code }; `shown` is the
// one the pane draws.
const RUN_PANE = 'glance-run'
const runs = new Map()
let shown = null
let runOpen = false
const RUN_TIMEOUT_MS = 120000
let asksOf = null
const ASKS_KEPT = 30
const ASK_SESSIONS_KEPT = 10
const REPLY_STORED = 6000

// The branch of the session's current folder ({ name, worktree }), or null outside a repository.
let branch = null
let readingBranch = false
const BRANCH_EVERY_MS = 3000

const DRAFT_SIZE = { columns: 28, rows: 6 }
const SENT_SIZE = { columns: 40, rows: 10 }

export function register(on) {
  on('session.start', async ($, e, next) => {
    cwd = e.cwd
    home = (await $.env.get('HOME')) ?? ''
    const tmp = ((await $.env.get('TMPDIR')) ?? '/tmp').replace(/\/$/, '')
    folder = `${tmp}/glance-replies-${await $.session.id()}`
    await $.process.run(['mkdir', '-p', folder])
    await $.command.register({
      name: 'ask',
      description: 'Ask Claude about the text selected in a reply, beside the conversation (nothing selected: earlier asks)',
      argumentHint: '[question]',
      immediate: true,
    })
    // Claude Code says nothing when an image is pasted, so the draft is looked at twice a second.
    $.clock.every(500, () => work($))
    // A checkout, `cd` or worktree move by Claude, in another terminal or by hand shows up within a few seconds.
    readBranch($)
    $.clock.every(BRANCH_EVERY_MS, () => readBranch($))
    return next(e)
  })

  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || !branch) return next(e)
    return drawBranch($.ui.resolve(e), branch, await next(e))
  })

  on('session.end', async ($, e, next) => {
    // /clear, /resume and /branch start another conversation, whose images are numbered afresh.
    thumbnails.clear()
    sentImages.clear()
    historyRead = false
    draftImages = []
    wanted.clear()
    return next(e)
  })

  // A sent prompt carries its pictures: keep them for the transcript.
  on('session.append', { door: 'prompt' }, async ($, e, next) => {
    if (e.message.type === 'user') {
      for (const image of imagesOfMessage(e.message.content)) {
        sentImages.set(image.n, image)
        thumbnails.delete(`sent:${image.n}`)
      }
    }
    return next(e)
  }).catch(($, e, next) => next(e)) // a preview never keeps a message from being stored

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    // A summary row is Claude Code's own wording, not the reply's markdown.
    if (e.surface !== 'terminal' || e.props.isSummary) return next(e)
    if (replies.size >= REPLIES_KEPT && !replies.has(e.requestId)) replies.delete(replies.keys().next().value)
    replies.set(e.requestId, e.props.text)
    const text = await linkFiles($, e.props.text)
    const parts = parseReply(text)
    if (!hasOwnParts(parts)) return text === e.props.text ? next(e) : next({ ...e, props: { ...e.props, text } })
    return drawReply($.ui.resolve(e), parts, e.props.isFirstOfReply, e.viewport?.columns ?? 100, {
      copy: (copied, press) => copyText($, copied, press?.surface),
      run: (command) => pressRun($, command),
      runState: (command) => runs.get(command.text)?.status ?? null,
    })
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== RUN_PANE) return next(e)
    if (shown === null) return next(e)
    return drawRun($.ui.resolve(e), shown, runs.get(shown.text) ?? { status: 'running', output: '' }, e.props.bodyColumns ?? 60, {
      copy: (text, press) => copyText($, text, press?.surface),
      send: () => sendRunToChat($),
      close: () => $.ui.close({ id: RUN_PANE }),
    })
  })

  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    const numbers = imageTokens(e.props.text)
    if (numbers.length === 0) return next(e)
    const ready = numbers.filter((n) => typeof thumbnails.get(`sent:${n}`) === 'object' && thumbnails.get(`sent:${n}`))
    for (const n of numbers) if (!thumbnails.has(`sent:${n}`)) wanted.add(n)
    if (ready.length === 0) return next(e)
    const { Box } = $.ui.resolve(e)
    const theirs = await next(e)
    return Box({
      flexDirection: 'column',
      children: [
        theirs,
        drawImages($.ui.resolve(e), ready.map((n) => ({ n, thumbnail: thumbnails.get(`sent:${n}`) })), 2, (path) =>
          previewFile($, path),
        ),
      ],
    })
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    const ready = draftImages.filter((n) => typeof thumbnails.get(`draft:${n}`) === 'object' && thumbnails.get(`draft:${n}`))
    const offerAsk = selection !== null && !askOpen
    if (ready.length === 0 && !offerAsk) return next(e)
    const elements = $.ui.resolve(e)
    const { Box, Button, Text } = elements
    const mine = []
    if (offerAsk) {
      const picked = selection
      mine.push(
        Box({
          key: 'ask-offer',
          flexDirection: 'row',
          children: [
            Text({ color: 'claude', children: ['✦ '] }),
            Button({ key: 'ask-selection', label: 'Ask about selection', plain: true, onPress: () => openAsk($, picked) }),
            Text({ dimColor: true, wrap: 'truncate-end', children: [`  “${oneLine(picked.text, 60)}”  · /ask`] }),
          ],
        }),
      )
    }
    if (ready.length > 0) {
      mine.push(
        drawImages(elements, ready.map((n) => ({ n, thumbnail: thumbnails.get(`draft:${n}`) })), 0, (path) =>
          previewFile($, path),
        ),
      )
    }
    const theirs = await next(e)
    return Box({ flexDirection: 'column', children: theirs ? [...mine, theirs] : mine })
  })

  on('command.run', { command: 'ask' }, async ($, e) => {
    const picked = await $.ui.selection()
    if (!picked || picked.text.trim() === '') {
      await loadAsks($)
      if (asks.length > 0) {
        await openAskHistory($)
        return {}
      }
      return { text: 'Select some text in a reply first (fullscreen mode), then /ask.' }
    }
    await openAsk($, picked)
    if (e.args.trim() !== '') await askQuestion($, e.args.trim())
    return {}
  })

  on('ui.close', async ($, e, next) => {
    if (e.id === ASK_PANE) {
      askOpen = false
      $.ui.invalidate('ui.render')
    }
    if (e.id === RUN_PANE) {
      runOpen = false
      $.ui.invalidate('ui.render')
    }
    return next(e)
  }).catch(($, e, next) => next(e)) // never keeps a pane open

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== ASK_PANE) return next(e)
    const elements = $.ui.resolve(e)
    const columns = e.props.bodyColumns ?? 60
    if (askView === 'history') {
      return drawAskHistory(elements, asks, ask, await $.clock.now(), columns, {
        open: (thread) => showAsk($, thread),
        back: () => showAsk($, ask),
        close: () => $.ui.close({ id: ASK_PANE }),
      })
    }
    if (ask === null) return next(e)
    return drawAsk(elements, ask, columns, {
      submit: (question) => askQuestion($, question),
      send: () => sendAskToChat($),
      copy: (text, press) => copyText($, text, press?.surface),
      history: asks.some((thread) => thread !== ask) ? () => openAskHistory($) : null,
      close: () => $.ui.close({ id: ASK_PANE }),
    })
  })
}

// Every half second: what the draft names, then any thumbnail still to make. One run at a time.
async function readBranch($) {
  if (readingBranch) return
  readingBranch = true
  try {
    const cwd = await $.session.cwd()
    const result = await $.process.run(['sh', '-c', BRANCH_SCRIPT, 'sh', cwd], { timeoutMs: 5000 })
    const read = parseBranch(result.exitCode, result.stdout)
    if (!sameBranch(read, branch)) {
      branch = read
      $.ui.invalidate('ui.render')
    }
  } catch {
    // No git, or the folder went away: keep what's shown.
  } finally {
    readingBranch = false
  }
}

async function work($) {
  if (working || folder === '') return
  working = true
  try {
    const draft = await $.prompt.read()
    const numbers = imageTokens(draft.text)
    let changed = numbers.join() !== draftImages.join()
    draftImages = numbers
    const picked = await $.ui.selection().catch(() => undefined)
    // Only what's selected in a reply (or across several of its rows) is offered: not a tool's row or the prompt.
    const next = picked && picked.text.trim() !== '' && (picked.requestId === undefined || replies.has(picked.requestId))
      ? { text: picked.text, requestId: picked.requestId }
      : null
    if ((next?.text ?? null) !== (selection?.text ?? null)) {
      selection = next
      changed = true
    }
    for (const n of numbers) {
      if (thumbnails.has(`draft:${n}`)) continue
      thumbnails.set(`draft:${n}`, 'pending')
      thumbnails.set(`draft:${n}`, await draftThumbnail($, n))
      changed = true
    }
    if (wanted.size > 0 && !historyRead && [...wanted].some((n) => !sentImages.has(n))) {
      // A resumed session: its earlier messages' images are in the history.
      historyRead = true
      const messages = await $.session.messages({ as: 'api' })
      for (const message of messages) {
        if (message.role !== 'user') continue
        for (const image of imagesOfMessage(message.content)) if (!sentImages.has(image.n)) sentImages.set(image.n, image)
      }
    }
    for (const n of [...wanted]) {
      wanted.delete(n)
      const image = sentImages.get(n)
      if (!image) {
        thumbnails.set(`sent:${n}`, null)
        continue
      }
      const out = `${folder}/sent-${n}.png`
      const original = `${folder}/sent-${n}-full.${extensionOf(image.mediaType)}`
      const result = await $.process.run(['sh', '-c', THUMBNAIL_FROM_STDIN_SCRIPT, 'sh', original, out], {
        stdin: image.data,
        timeoutMs: 15000,
      })
      thumbnails.set(`sent:${n}`, thumbnailFrom(result, out, SENT_SIZE, original))
      changed = true
    }
    if (changed) $.ui.invalidate('ui.render')
  } catch {
    // A failed look is retried on the next tick; a failed thumbnail stays null (the text alone shows).
  } finally {
    working = false
  }
}

// Where a pasted image came from: a file just dropped on Studio's terminal, else the clipboard (a copied file, a
// pasted path, or image data, which is what Ctrl+V gives Claude Code).
async function draftThumbnail($, n) {
  let source = null
  const dropsFile = `${home}/Library/Caches/Glance Studio/image-drops.json`
  if (await $.fs.exists(dropsFile)) {
    const drop = recentDrops(await $.fs.read(dropsFile), await $.clock.now(), 15000).find(
      (d) => !dropsUsed.has(`${d.at}:${d.path}`),
    )
    if (drop) {
      dropsUsed.add(`${drop.at}:${drop.path}`)
      source = drop.path
    }
  }
  if (source === null) {
    const result = await $.process.run(['osascript', '-', `${folder}/clipboard-${n}.png`], {
      stdin: CLIPBOARD_SCRIPT,
      timeoutMs: 5000,
    })
    const found = result.exitCode === 0 ? parseClipboard(result.stdout) : null
    source = found?.file ?? found?.png ?? null
  }
  if (source === null) return null
  const out = `${folder}/draft-${n}.png`
  const result = await $.process.run(['sh', '-c', THUMBNAIL_SCRIPT, 'sh', source, out], { timeoutMs: 15000 })
  return thumbnailFrom(result, out, DRAFT_SIZE, source)
}

// A thumbnail: the PNG drawn, its cells, and the picture it was made from (what its caption opens).
function thumbnailFrom(result, file, size, original) {
  const pixels = result.exitCode === 0 ? parseSize(result.stdout) : null
  return pixels ? { file, original, ...cellSize(pixels.width, pixels.height, size.columns, size.rows) } : null
}

function extensionOf(mediaType) {
  return { 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp' }[mediaType] ?? 'png'
}

// The first press of a risky or multi-line command asks; the next one (and a plain one-liner at once) runs it.
async function pressRun($, command) {
  const state = runs.get(command.text)
  if (state?.status === 'running') return
  if (needsConfirm(command.text) && state?.status !== 'confirm') {
    runs.set(command.text, { status: 'confirm', output: '' })
    $.ui.invalidate('ui.render')
    return
  }
  const run = { status: 'running', output: '' }
  runs.set(command.text, run)
  shown = command
  if (!runOpen) {
    runOpen = true
    await $.ui.open({ id: RUN_PANE, title: 'Run', closeOnEscape: true })
  }
  $.ui.invalidate('ui.render')
  try {
    const shell = (await $.env.get('SHELL').catch(() => null)) || '/bin/zsh'
    const done = await $.process.run([shell, '-lc', command.text], { cwd: cwd || undefined, timeoutMs: RUN_TIMEOUT_MS })
    run.output = [done.stdout, done.stderr].filter((part) => part.trim() !== '').join('\n')
    run.code = done.exitCode
    run.status = done.exitCode === 0 ? 'done' : 'failed'
  } catch (error) {
    run.output = String(error?.message ?? error)
    run.code = null
    run.status = 'failed'
  }
  await $.ui.toast(run.status === 'done' ? 'Ran the command' : `Command failed${run.code == null ? '' : ` (exit ${run.code})`}`)
  $.ui.invalidate('ui.render')
}

// The command and its output into the prompt, for the conversation to take up.
async function sendRunToChat($) {
  if (shown === null) return
  const run = runs.get(shown.text)
  await $.prompt.fill({ text: `I ran \`${shown.text}\`:\n\n\`\`\`\n${(run?.output ?? '').trimEnd()}\n\`\`\`\n`, mode: 'replace' })
  await $.ui.close({ id: RUN_PANE })
}

// Copies through Claude Code (its clipboard tool, pbcopy here) and says so.
async function copyText($, text, surface) {
  const copied = await $.ui.copy(surface ? { text, surface } : { text })
  const lines = text.split('\n').length
  await $.ui.toast(copied.isCopied ? `Copied ${lines} line${lines === 1 ? '' : 's'}` : `Couldn't copy: ${copied.reason}`)
}

// Shows a file in Quick Look over Studio's window (its local /preview), else in Quick Look's own panel.
async function previewFile($, path) {
  const port = (await $.env.get('GLANCE_PORT')) || '47823'
  const shown = await $.http
    .fetch(`http://127.0.0.1:${port}/preview`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path }),
    })
    .then((response) => response.status === 202)
    .catch(() => false)
  if (!shown) await $.process.run(['sh', '-c', 'qlmanage -p "$1" >/dev/null 2>&1 &', 'sh', path])
}

// Ask: open the pane on what was selected, the reply it lies in as the answer's context. A passage asked about before
// opens its thread again, to follow up.
async function openAsk($, picked) {
  await loadAsks($)
  const reply = picked.requestId !== undefined ? replies.get(picked.requestId) : undefined
  ask = asks.find((thread) => thread.selection === picked.text) ?? { selection: picked.text, reply: reply ?? '', turns: [], at: 0 }
  askView = 'thread'
  await openAskPane($)
}

// The pane on this conversation's earlier asks.
async function openAskHistory($) {
  await loadAsks($)
  askView = 'history'
  await openAskPane($)
}

// A thread from the history, back in the pane with its field for a follow-up.
function showAsk($, thread) {
  if (thread !== null) {
    ask = thread
    askView = 'thread'
  }
  $.ui.invalidate('ui.render')
}

async function openAskPane($) {
  if (!askOpen) {
    askOpen = true
    await $.ui.open({ id: ASK_PANE, title: 'Ask', focus: true, closeOnEscape: true })
  }
  $.ui.invalidate('ui.render')
}

async function askQuestion($, question) {
  if (ask === null) return
  const thread = ask
  const turn = { question, answer: null, failure: null }
  thread.turns.push(turn)
  thread.at = await $.clock.now()
  // The newest thread asked in leads the history.
  asks = [thread, ...asks.filter((other) => other !== thread)]
  $.ui.invalidate('ui.render')
  const reply = await $.model.complete({
    model: await $.session.model(),
    system: ASK_SYSTEM,
    prompt: askPrompt(thread),
    maxTokens: 2048,
  })
  if (reply.isAnswered) turn.answer = reply.text
  else turn.failure = reply.reason ?? 'no answer'
  $.ui.invalidate('ui.render')
  await saveAsks($)
}

// The history is the conversation's: /clear and /resume change the session, so it's read again when that changed.
async function loadAsks($) {
  const id = await $.session.id()
  if (asksOf === id) return
  asksOf = id
  ask = null
  const stored = await $.store.get(`asks:${id}`).catch(() => undefined)
  asks = Array.isArray(stored) ? stored.map(reviveAsk) : []
}

async function saveAsks($) {
  if (asksOf === null) return
  const id = asksOf
  try {
    await $.store.set(`asks:${id}`, storedAsks(asks))
    // Only the latest conversations keep theirs.
    const stored = await $.store.get('ask-sessions')
    const order = [id, ...(Array.isArray(stored) ? stored : []).filter((other) => other !== id)]
    for (const old of order.splice(ASK_SESSIONS_KEPT)) await $.store.delete(`asks:${old}`)
    await $.store.set('ask-sessions', order)
  } catch {
    // The history is a convenience: the pane works without it.
  }
}

// What the store keeps: the newest threads, answered turns, the reply cut to a size.
export function storedAsks(threads) {
  return threads.slice(0, ASKS_KEPT).map((thread) => ({
    selection: thread.selection,
    reply: thread.reply.slice(0, REPLY_STORED),
    at: thread.at,
    turns: thread.turns.filter((turn) => turn.answer !== null || turn.failure !== null),
  }))
}

// A stored thread whose answer never came (the session ended first) reads as such.
function reviveAsk(thread) {
  return {
    selection: String(thread.selection ?? ''),
    reply: String(thread.reply ?? ''),
    at: Number(thread.at ?? 0),
    turns: (Array.isArray(thread.turns) ? thread.turns : []).map((turn) => ({
      question: String(turn.question ?? ''),
      answer: turn.answer ?? null,
      failure: turn.answer == null && turn.failure == null ? 'interrupted' : (turn.failure ?? null),
    })),
  }
}

// Puts the selection (quoted) and the last question in the prompt, for the conversation itself to take up.
async function sendAskToChat($) {
  if (ask === null) return
  const quote = ask.selection
    .split('\n')
    .map((line) => `> ${line}`)
    .join('\n')
  const last = ask.turns[ask.turns.length - 1]?.question ?? ''
  await $.prompt.fill({ text: `${quote}\n\n${last}`, mode: 'replace' })
  await $.ui.close({ id: ASK_PANE })
}

// The reply's file links and path-like code spans, pointed at the files they name (when they exist).
async function linkFiles($, text) {
  if (cwd === '') return text
  const found = new Map()
  for (const target of linkTargets(text)) {
    const key = `${cwd}\u0000${target}`
    if (!files.has(key)) {
      const { path, line, column } = splitTarget(target)
      const absolute = absolutePath(path, cwd, home)
      const stat = await $.fs.stat(absolute).catch(() => undefined)
      if (files.size >= FILES_KEPT) files.delete(files.keys().next().value)
      files.set(key, stat?.kind === 'file' ? fileURL(absolute, line, column) : null)
    }
    if (files.get(key)) found.set(target, files.get(key))
  }
  return rewriteLinks(text, found)
}

// Thumbnails in a row, each over a caption that opens the picture itself.
export function drawImages(elements, images, indent, open) {
  const { Box, Button, Image } = elements
  return Box({
    flexDirection: 'row',
    flexWrap: 'wrap',
    columnGap: 2,
    paddingLeft: indent,
    children: images.map(({ n, thumbnail }) =>
      Box({
        key: `image-${n}`,
        flexDirection: 'column',
        children: [
          Image({
            key: `image-${n}-picture`,
            source: { file: thumbnail.file, format: 'png' },
            columns: thumbnail.columns,
            rows: thumbnail.rows,
            alt: `[Image #${n}]`,
          }),
          Button({
            key: `image-${n}-open`,
            label: `[Image #${n}] ↗`,
            plain: true,
            dimColor: true,
            onPress: () => open(thumbnail.original ?? thumbnail.file),
          }),
        ],
      }),
    ),
  })
}

const ASK_SYSTEM =
  'You answer a question about a passage the person selected in one of your earlier replies, in a coding session in ' +
  "their terminal. Answer briefly and directly, in markdown. Don't restate the passage."

export function askPrompt(thread) {
  const parts = []
  if (thread.reply) parts.push(`The reply the passage is from:\n<reply>\n${thread.reply}\n</reply>`)
  parts.push(`The selected passage:\n<selection>\n${thread.selection}\n</selection>`)
  for (const turn of thread.turns.slice(0, -1)) {
    if (turn.answer) parts.push(`Earlier question: ${turn.question}\nYour answer: ${turn.answer}`)
  }
  parts.push(`Question: ${thread.turns[thread.turns.length - 1].question}`)
  return parts.join('\n\n')
}

// The Ask pane: the selection (a few lines), each question with its answer, a field for the next, and the actions.
export function drawAsk(elements, thread, columns, actions) {
  const { Box, Button, Input, Markdown, Text } = elements
  const lines = thread.selection.split('\n')
  const preview = lines.slice(0, 4).map((line) => `▎ ${line}`)
  if (lines.length > 4) preview.push(`▎ … ${lines.length - 4} more lines`)
  const children = [
    Text({ key: 'ask-label', dimColor: true, children: ['SELECTED'] }),
    Text({ key: 'ask-selection', color: 'inactive', wrap: 'truncate-end', children: [preview.join('\n')] }),
  ]
  thread.turns.forEach((turn, i) => {
    children.push(Text({ key: `ask-q-${i}`, bold: true, children: [`› ${turn.question}`] }))
    if (turn.answer !== null) children.push(Markdown({ key: `ask-a-${i}`, text: turn.answer }))
    else if (turn.failure !== null) children.push(Text({ key: `ask-a-${i}`, color: 'error', children: [`No answer: ${turn.failure}`] }))
    else children.push(Text({ key: `ask-a-${i}`, color: 'claude', children: ['✦ Thinking…'] }))
  })
  const busy = thread.turns.some((turn) => turn.answer === null && turn.failure === null)
  const lastAnswer = [...thread.turns].reverse().find((turn) => turn.answer !== null)?.answer ?? null
  children.push(
    Input({
      key: 'ask-input',
      label: thread.turns.length === 0 ? 'Ask' : 'Follow up',
      placeholder: busy ? 'Claude is answering…' : 'Type a question and press Enter',
      value: '',
      submitLabel: 'ask',
      autoFocus: true,
      onSubmit: (value) => {
        if (value.trim() !== '' && !busy) actions.submit(value.trim())
      },
    }),
  )
  children.push(
    Box({
      key: 'ask-actions',
      flexDirection: 'row',
      columnGap: 2,
      children: [
        ...(lastAnswer ? [Button({ key: 'ask-copy', label: 'Copy answer', onPress: (press) => actions.copy(lastAnswer, press) })] : []),
        Button({ key: 'ask-send', label: 'Send to chat', onPress: () => actions.send() }),
        ...(actions.history ? [Button({ key: 'ask-history', label: 'History', onPress: () => actions.history() })] : []),
        Button({ key: 'ask-close', label: 'Close (Esc)', onPress: () => actions.close() }),
      ],
    }),
  )
  return Box({ flexDirection: 'column', rowGap: 1, width: Math.max(20, columns), children })
}

// The Ask pane's history: this conversation's threads, newest first, each its first question, the passage and how many
// questions; pressing one (or its digit) opens it to follow up.
// The Run pane: the command, how it went, the end of its output, and what to do with it.
export function drawRun(elements, command, run, columns, actions) {
  const { Box, Button, Text } = elements
  const status = {
    confirm: ['Waiting for confirmation', 'warning'],
    running: ['✦ Running…', 'claude'],
    done: ['✓ Done', 'success'],
    failed: [`✗ Failed${run.code == null ? '' : ` (exit ${run.code})`}`, 'error'],
  }[run.status]
  const { text, hidden } = tail(run.output ?? '', 40)
  const finished = run.status === 'done' || run.status === 'failed'
  const children = [
    Text({ key: 'run-label', dimColor: true, children: ['COMMAND'] }),
    Text({ key: 'run-command', bold: true, children: [command.text] }),
    Text({ key: 'run-status', color: status[1], children: [status[0]] }),
  ]
  if (finished) {
    children.push(
      Text({ key: 'run-output', children: [text === '' ? '(no output)' : `${hidden > 0 ? `… ${hidden} earlier lines\n` : ''}${text}`] }),
    )
  }
  children.push(
    Box({
      key: 'run-actions',
      flexDirection: 'row',
      columnGap: 2,
      children: [
        ...(finished && text !== '' ? [Button({ key: 'run-copy', label: 'Copy output', onPress: (press) => actions.copy(run.output, press) })] : []),
        ...(finished ? [Button({ key: 'run-send', label: 'Send to chat', onPress: () => actions.send() })] : []),
        Button({ key: 'run-close', label: 'Close (Esc)', onPress: () => actions.close() }),
      ],
    }),
  )
  return Box({ flexDirection: 'column', rowGap: 1, width: Math.max(20, columns), children })
}

export function drawAskHistory(elements, threads, current, now, columns, actions) {
  const { Box, Button, Text } = elements
  const children = [Text({ key: 'ask-history-label', dimColor: true, children: [`HISTORY · ${countOf(threads.length, 'ask')}`] })]
  if (threads.length === 0) {
    children.push(Text({ key: 'ask-history-empty', dimColor: true, children: ['Nothing asked yet in this conversation.'] }))
  }
  threads.forEach((thread, i) => {
    const asked = thread.turns.length
    children.push(
      Box({
        key: `ask-thread-${i}`,
        flexDirection: 'column',
        children: [
          Button({
            key: `ask-thread-${i}-open`,
            label: `› ${oneLine(thread.turns[0]?.question ?? '', Math.max(12, columns - 6))}`,
            plain: true,
            ...(i < 9 ? { hotkey: String(i + 1) } : {}),
            ...(i === 0 ? { autoFocus: true } : {}),
            onPress: () => actions.open(thread),
          }),
          Text({
            key: `ask-thread-${i}-passage`,
            color: 'inactive',
            wrap: 'truncate-end',
            children: [`▎ ${oneLine(thread.selection, Math.max(12, columns - 2))}`],
          }),
          Text({
            key: `ask-thread-${i}-meta`,
            dimColor: true,
            children: [`  ${countOf(asked, 'question')}${thread === current ? ' · open' : ''} · ${ago(now - thread.at)}`],
          }),
        ],
      }),
    )
  })
  children.push(
    Box({
      key: 'ask-actions',
      flexDirection: 'row',
      columnGap: 2,
      children: [
        ...(current !== null ? [Button({ key: 'ask-back', label: 'Back', onPress: () => actions.back() })] : []),
        Button({ key: 'ask-close', label: 'Close (Esc)', onPress: () => actions.close() }),
      ],
    }),
  )
  return Box({ flexDirection: 'column', rowGap: 1, width: Math.max(20, columns), children })
}

function countOf(n, noun) {
  return `${n} ${noun}${n === 1 ? '' : 's'}`
}

export function ago(ms) {
  const minutes = Math.floor(Math.max(0, ms) / 60000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  return hours < 24 ? `${hours}h ago` : `${Math.floor(hours / 24)}d ago`
}

function oneLine(text, max) {
  const flat = text.replace(/\s+/g, ' ').trim()
  return flat.length > max ? flat.slice(0, max - 1) + '…' : flat
}

// Laid out as Claude Code lays out a reply: a blank line above, and the ⏺ bullet (on a reply's first block) in a
// two-column gutter.
export function drawReply(elements, parts, isFirstOfReply, columns, actions) {
  const { Box, Text } = elements
  return Box({
    flexDirection: 'row',
    marginTop: 1,
    children: [
      Box({ width: 2, flexShrink: 0, children: [Text({ children: [isFirstOfReply ? '⏺' : ' '] })] }),
      Box({
        flexDirection: 'column',
        flexGrow: 1,
        rowGap: 1,
        children: parts.map((part, index) => drawPart(elements, part, index, columns, actions)),
      }),
    ],
  })
}

function drawPart(elements, part, index, columns, actions) {
  const { Box, Button, Code, Text, Markdown } = elements
  const copyButton = (text) =>
    Button({ key: `${key}-copy`, label: '⧉ Copy', plain: true, dimColor: true, onPress: (press) => actions.copy(text, press) })
  const key = `part-${index}`
  // A command block also gets Run: one press for a one-liner, two for a multi-line or destructive one.
  const runButton = (code) => {
    const command = actions.run ? commandOf(code.lang, code.source) : null
    if (command === null) return []
    const status = actions.runState?.(command) ?? null
    const label = { confirm: '▶ Run? press again', running: '… Running', done: '✓ Ran, run again', failed: '✗ Failed, run again' }[status] ?? '▶ Run'
    const color = { confirm: 'warning', running: 'claude', done: 'success', failed: 'error' }[status]
    return [
      Button({ key: `${key}-run`, label, plain: true, ...(color ? { color } : { dimColor: true }), onPress: () => actions.run(command) }),
    ]
  }
  switch (part.kind) {
    case 'markdown':
      return Markdown({ key, text: part.text })

    case 'alert': {
      const alert = ALERTS[part.type]
      return Box({
        key,
        flexDirection: 'column',
        borderStyle: 'quote',
        borderColor: alert.color,
        // The quote border keeps a blank row above and below; the gap between parts is already there.
        marginY: -1,
        paddingLeft: 1,
        children: [
          Text({ bold: true, color: alert.color, children: [`${alert.icon} ${alert.label}`] }),
          ...(part.body ? [Markdown({ key: `${key}-body`, text: part.body })] : []),
        ],
      })
    }

    case 'code':
      // A label row (the language, and Copy) over the code, unframed so a selection copies clean lines too.
      return Box({
        key,
        flexDirection: 'column',
        children: [
          Box({
            key: `${key}-head`,
            flexDirection: 'row',
            columnGap: 2,
            children: [Text({ dimColor: true, children: [part.lang || 'code'] }), copyButton(part.source), ...runButton(part)],
          }),
          Code({ key: `${key}-code`, source: part.source, ...(part.lang ? { language: part.lang } : {}) }),
        ],
      })

    case 'quote':
      // Often a message Claude drafted for you: its markdown as written is what Copy takes.
      return Box({
        key,
        flexDirection: 'column',
        children: [
          Box({
            key: `${key}-body`,
            flexDirection: 'column',
            borderStyle: 'quote',
            borderColor: 'subtle',
            marginY: -1,
            paddingLeft: 1,
            children: [Markdown({ key: `${key}-text`, text: part.body })],
          }),
          copyButton(part.body),
        ],
      })

    case 'heading': {
      // Coral marks a reply's own structure, as Glance's pane does; a top-level heading gets a rule under it.
      const title = Text({ key, bold: true, color: part.level <= 2 ? 'claude' : undefined, children: [plainInline(part.text)] })
      if (part.level > 1) return title
      return Box({
        key,
        flexDirection: 'column',
        children: [title, Text({ color: 'subtle', children: ['─'.repeat(Math.max(8, Math.min(columns - 6, 120)))] })],
      })
    }

    case 'list':
      return Box({
        key,
        flexDirection: 'column',
        children: part.items.map((item, row) =>
          Box({
            key: `${key}-${row}`,
            flexDirection: 'row',
            paddingLeft: item.depth * 2,
            children: [
              item.task === undefined
                ? Text({ color: 'claude', children: [`${item.marker === '•' ? BULLETS[item.depth % BULLETS.length] : item.marker} `] })
                : Text({ color: item.task ? 'success' : 'inactive', children: [item.task ? '✓ ' : '○ '] }),
              Markdown({ key: `${key}-${row}-text`, text: item.text, dimColor: item.task === true }),
            ],
          }),
        ),
      })

    case 'mermaid': {
      const diagram = layOut(part.source)
      // A diagram the renderer can't read is drawn as the code it is.
      if (diagram === null) return Markdown({ key, text: '```mermaid\n' + part.source + '\n```' })
      return Box({
        key,
        flexDirection: 'column',
        children: [
          Text({ wrap: 'truncate-end', children: [diagram] }),
          Text({ dimColor: true, children: [`mermaid · ${diagramKind(part.source)}`] }),
        ],
      })
    }

    case 'rule':
      // The gutter takes two columns; leave a little room on the right too.
      return Text({ color: 'subtle', children: ['─'.repeat(Math.max(8, Math.min(columns - 6, 120)))] })
  }
}

const BULLETS = ['•', '◦', '▪']

// A heading's text without its inline markup, since a coloured Text draws it and not Markdown.
function plainInline(text) {
  return text
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/(\*\*|__)(.+?)\1/g, '$2')
    .replace(/(\*|_)(.+?)\1/g, '$2')
    .replace(/`([^`]*)`/g, '$1')
}

function layOut(source) {
  if (diagrams.has(source)) return diagrams.get(source)
  let diagram
  try {
    diagram = renderMermaidASCII(source, { colorMode: 'none', paddingX: 3, paddingY: 1 })
      .split('\n')
      .map((line) => line.trimEnd())
      .join('\n')
      .replace(/^\n+|\n+$/g, '')
    if (diagram === '') diagram = null
  } catch {
    diagram = null
  }
  if (diagrams.size >= DIAGRAMS_KEPT) diagrams.delete(diagrams.keys().next().value)
  diagrams.set(source, diagram)
  return diagram
}

function diagramKind(source) {
  const first = source.split('\n').find((line) => line.trim() !== '' && !line.trim().startsWith('%%'))
  return first ? first.trim().split(/\s+/)[0] : 'diagram'
}
