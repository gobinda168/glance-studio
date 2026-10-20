// Turns the files a reply names into links Glance Studio opens in its editor on ⌘-click.
//
// Claude writes `[App.swift:12](Sources/App.swift#L12)` and `` `Sources/App.swift:12` ``. Claude Code draws a relative
// link as a hyperlink to the bare path (no folder to resolve it from), an absolute one as plain text, and a code span
// as text. Here each one that names an existing file becomes a `file://` URL with its line (`file:///…/App.swift:12`),
// which Studio's hyperlink handler opens in Razor at that line.
//
// Two steps, because whether a file exists is only known through `$`: `linkTargets` lists what to look up,
// `rewriteLinks` swaps in what was found. Nothing inside a code fence is touched.

const FENCE = /^ {0,3}(`{3,}|~{3,})/
const LINK = /\[([^\]\n]*)\]\((<[^>\n]+>|[^)\s]+)(\s+"[^"\n]*")?\)/g
const CODE_SPAN = /`([^`\n]+)`/g
// A path in a code span: no spaces, and a slash or a file extension (so `npm test` and `true` stay code).
const CODE_PATH = /^(?:~|\.{1,2})?\/?[\w@.+-]+(?:\/[\w@.+-]+)*(?::\d+(?::\d+)?)?$/
const SCHEME = /^[a-z][a-z0-9+.-]*:/i

/** The targets in `text` worth looking up: link hrefs that may name a file, and code spans that look like paths. */
export function linkTargets(text) {
  const targets = new Set()
  eachProseLine(text, (line) => {
    for (const match of line.matchAll(LINK)) {
      const href = unwrap(match[2])
      if (mayBeFile(href)) targets.add(href)
    }
    for (const span of codeSpansOutsideLinks(line)) targets.add(span)
  })
  return [...targets]
}

/** `text` with every target `files` resolved (target → file URL) pointing at its file. */
export function rewriteLinks(text, files) {
  if (files.size === 0) return text
  const lines = text.split('\n')
  let fence = null
  return lines
    .map((line) => {
      const open = FENCE.exec(line)
      if (fence !== null) {
        if (open && open[1][0] === fence[0] && open[1].length >= fence.length && line.trim() === open[1]) fence = null
        return line
      }
      if (open) {
        fence = open[1]
        return line
      }
      return rewriteLine(line, files)
    })
    .join('\n')
}

/** What a target names: the path and the line (and column) it points at, from `:12`, `:12:5` or `#L12`. */
export function splitTarget(target) {
  let path = target
  if (/^file:\/\//i.test(path)) {
    path = path.replace(/^file:\/\/(localhost)?/i, '')
    try {
      path = decodeURI(path)
    } catch {}
  }
  const anchor = /^(.+?)#L(\d+)(?:C(\d+))?(?:-L?\d+(?:C\d+)?)?$/.exec(path)
  if (anchor) return { path: anchor[1], line: Number(anchor[2]), column: anchor[3] ? Number(anchor[3]) : undefined }
  const position = /^(.+?):(\d+)(?::(\d+))?$/.exec(path)
  if (position) return { path: position[1], line: Number(position[2]), column: position[3] ? Number(position[3]) : undefined }
  return { path, line: undefined, column: undefined }
}

/** The absolute path `path` names: itself, under `home` for `~`, else inside `cwd`. */
export function absolutePath(path, cwd, home) {
  if (path.startsWith('/')) return normalize(path)
  if (path === '~' || path.startsWith('~/')) return normalize(home + path.slice(1))
  return normalize(cwd.replace(/\/$/, '') + '/' + path)
}

/** The `file://` URL Studio opens at a line: percent-encoded, the position after a colon. */
export function fileURL(absolute, line, column) {
  const encoded = encodeURI(absolute).replace(/#/g, '%23').replace(/\?/g, '%3F')
  const position = line ? `:${line}` + (column ? `:${column}` : '') : ''
  return `file://${encoded}${position}`
}

function rewriteLine(line, files) {
  // Links first, then the code spans between them, so a code span inside a link label stays the label.
  let out = ''
  let last = 0
  for (const match of line.matchAll(LINK)) {
    out += rewriteSpans(line.slice(last, match.index), files)
    const href = unwrap(match[2])
    const url = files.get(href)
    out += url ? `[${match[1]}](${url}${match[3] ?? ''})` : match[0]
    last = match.index + match[0].length
  }
  return out + rewriteSpans(line.slice(last), files)
}

function rewriteSpans(text, files) {
  return text.replace(CODE_SPAN, (span, inner) => {
    const url = files.get(inner)
    return url ? `[${span}](${url})` : span
  })
}

function codeSpansOutsideLinks(line) {
  const spans = []
  let last = 0
  const outside = []
  for (const match of line.matchAll(LINK)) {
    outside.push(line.slice(last, match.index))
    last = match.index + match[0].length
  }
  outside.push(line.slice(last))
  for (const part of outside) {
    for (const match of part.matchAll(CODE_SPAN)) {
      const inner = match[1]
      if (CODE_PATH.test(inner) && (inner.includes('/') || /\.[A-Za-z0-9]+(?::\d+(?::\d+)?)?$/.test(inner))) spans.push(inner)
    }
  }
  return spans
}

function eachProseLine(text, visit) {
  let fence = null
  for (const line of text.split('\n')) {
    const open = FENCE.exec(line)
    if (fence !== null) {
      if (open && open[1][0] === fence[0] && open[1].length >= fence.length && line.trim() === open[1]) fence = null
      continue
    }
    if (open) {
      fence = open[1]
      continue
    }
    visit(line)
  }
}

function mayBeFile(href) {
  if (href.startsWith('#')) return false
  if (/^file:\/\//i.test(href)) return true
  // `README.md:12` reads as a scheme (`readme.md:`) but is a path with a line.
  return !SCHEME.test(href) || /^[^/:]+\.[A-Za-z0-9]+:\d+/.test(href)
}

function unwrap(href) {
  return href.startsWith('<') && href.endsWith('>') ? href.slice(1, -1) : href
}

function normalize(path) {
  const parts = []
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') parts.pop()
    else parts.push(part)
  }
  return '/' + parts.join('/')
}
