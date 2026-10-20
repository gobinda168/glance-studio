// Splits a reply's markdown into the parts glance-replies draws itself and the runs Claude Code's own renderer keeps.
//
// A part is one of:
//   { kind: 'markdown', text }                     drawn by Claude Code's Markdown, as a reply always is
//   { kind: 'alert', type, body }                  a GitHub alert: > [!NOTE], [!TIP], [!IMPORTANT], [!WARNING], [!CAUTION]
//   { kind: 'heading', level, text }               an ATX heading (# to ######)
//   { kind: 'list', items: [{ depth, marker, task, text }] }
//                                                  a list: marker '•' or '3.', task true/false for - [x]/- [ ] (else
//                                                  undefined), text the item's markdown with its continuation lines
//   { kind: 'mermaid', source }                    a closed ```mermaid fence
//   { kind: 'code', lang, source }                 any other closed fence (drawn with a Copy button)
//   { kind: 'quote', body }                        a plain blockquote (often a drafted message; Copy too)
//   { kind: 'rule' }                               a thematic break (---, ***, ___) after a blank line
//
// Nothing inside a code fence is touched, a fence still open (a reply mid-stream) stays markdown, and so does a list
// holding a code fence (Claude Code lays those out better than a row of text can).

const ALERT = /^ {0,3}>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$/i
const QUOTED = /^ {0,3}>/
const ITEM = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/
const TASK = /^\[([ xX])\]\s+(.*)$/
const HEADING = /^ {0,3}(#{1,6})\s+(.+?)(?:\s+#+)?\s*$/
const RULE = /^ {0,3}([-*_])(?:\s*\1){2,}\s*$/
const FENCE = /^ {0,3}(`{3,}|~{3,})\s*([^\s`]*)/

export function parseReply(text) {
  const lines = text.split('\n')
  const parts = []
  let markdown = []

  const flush = () => {
    if (markdown.length > 0) parts.push({ kind: 'markdown', text: markdown.join('\n') })
    markdown = []
  }
  const previousIsBlank = () => markdown.length === 0 || markdown[markdown.length - 1].trim() === ''

  let i = 0
  while (i < lines.length) {
    const line = lines[i]

    const fence = FENCE.exec(line)
    if (fence) {
      const close = findClose(lines, i + 1, fence[1])
      const isMermaid = fence[2].toLowerCase() === 'mermaid'
      if (close === -1) {
        // A fence the stream hasn't closed yet: Claude Code draws it until it is.
        markdown.push(...lines.slice(i))
        i = lines.length
        continue
      }
      flush()
      const source = lines.slice(i + 1, close).join('\n')
      parts.push(isMermaid ? { kind: 'mermaid', source } : { kind: 'code', lang: fence[2], source })
      i = close + 1
      continue
    }

    const alert = ALERT.exec(line)
    if (alert) {
      let end = i + 1
      while (end < lines.length && QUOTED.test(lines[end])) end++
      flush()
      const body = lines.slice(i + 1, end).map((quoted) => quoted.replace(/^ {0,3}> ?/, ''))
      parts.push({ kind: 'alert', type: alert[1].toUpperCase(), body: body.join('\n').trim() })
      i = end
      continue
    }

    if (QUOTED.test(line)) {
      let end = i + 1
      while (end < lines.length && QUOTED.test(lines[end])) end++
      flush()
      const body = lines.slice(i, end).map((quoted) => quoted.replace(/^ {0,3}> ?/, ''))
      parts.push({ kind: 'quote', body: body.join('\n') })
      i = end
      continue
    }

    const heading = HEADING.exec(line)
    if (heading) {
      flush()
      parts.push({ kind: 'heading', level: heading[1].length, text: heading[2] })
      i++
      continue
    }

    if (ITEM.test(line) && !RULE.test(line)) {
      const end = listEnd(lines, i)
      const block = lines.slice(i, end)
      if (block.some((l) => FENCE.test(l.trimStart()))) {
        markdown.push(...block)
      } else {
        flush()
        parts.push({ kind: 'list', items: listItems(block) })
      }
      i = end
      continue
    }

    // After text, `---` makes that text a heading (setext), so only a rule after a blank line is one.
    if (RULE.test(line) && previousIsBlank()) {
      flush()
      parts.push({ kind: 'rule' })
      i++
      continue
    }

    markdown.push(line)
    i++
  }
  flush()

  // Blank lines around a part are spacing the drawing adds itself.
  return parts
    .map((part) => (part.kind === 'markdown' ? { ...part, text: part.text.replace(/^(\s*\n)+/, '').trimEnd() } : part))
    .filter((part) => part.kind !== 'markdown' || part.text !== '')
}

/** Whether a reply has anything glance-replies draws differently from Claude Code. */
export function hasOwnParts(parts) {
  return parts.some((part) => part.kind !== 'markdown')
}

// Where the list starting at `start` ends: items at its indent or deeper, lines indented under them, and blank lines
// with more of the list after them.
function listEnd(lines, start) {
  const base = indentOf(lines[start])
  let j = start + 1
  while (j < lines.length) {
    const line = lines[j]
    if (line.trim() === '') {
      let k = j + 1
      while (k < lines.length && lines[k].trim() === '') k++
      if (k < lines.length && belongsToList(lines[k], base)) {
        j = k
        continue
      }
      break
    }
    if (!belongsToList(line, base)) break
    j++
  }
  return j
}

function belongsToList(line, base) {
  const item = ITEM.exec(line)
  if (item && !RULE.test(line)) return indentOf(line) >= base
  return indentOf(line) > base
}

function listItems(block) {
  const base = indentOf(block[0])
  const items = []
  let gap = false
  for (const line of block) {
    const item = ITEM.exec(line)
    if (item && !RULE.test(line)) {
      const task = TASK.exec(item[3])
      items.push({
        depth: Math.floor((indentOf(line) - base) / 2),
        marker: /\d/.test(item[2]) ? item[2].replace(')', '.') : '•',
        task: task ? task[1] !== ' ' : undefined,
        text: task ? task[2] : item[3],
      })
      gap = false
    } else if (line.trim() === '') {
      gap = true
    } else if (items.length > 0) {
      const last = items[items.length - 1]
      last.text += (gap ? '\n\n' : '\n') + line.trim()
      gap = false
    }
  }
  return items
}

function indentOf(line) {
  return /^\s*/.exec(line.replace(/\t/g, '    '))[0].length
}

function findClose(lines, from, open) {
  for (let j = from; j < lines.length; j++) {
    const fence = /^ {0,3}(`{3,}|~{3,})\s*$/.exec(lines[j])
    if (fence && fence[1][0] === open[0] && fence[1].length >= open.length) return j
  }
  return -1
}
