// Previews of the images pasted into a prompt: while it's being written (above the prompt) and once it's sent (under
// the message in the transcript). Claude Code shows only `[Image #N]` and tells a mod nothing when an image is pasted,
// so the pixels come from what the message carries once sent, and before that from where the paste came from.

const TOKEN = /\[Image #(\d+)\]/g

/** The image numbers `[Image #N]` names in `text`, in order, each once. */
export function imageTokens(text) {
  return [...new Set([...text.matchAll(TOKEN)].map((match) => Number(match[1])))]
}

/**
 * The images of one user message, by number: its text names them (`[Image #2] and [Image #3]`) in the order its
 * image blocks hold them. Blocks are Messages API content blocks.
 */
export function imagesOfMessage(content) {
  if (!Array.isArray(content)) return []
  const text = content
    .filter((block) => block.type === 'text')
    .map((block) => block.text)
    .join('\n')
  const blocks = content.filter((block) => block.type === 'image' && block.source?.type === 'base64')
  return imageTokens(text)
    .slice(0, blocks.length)
    .map((n, i) => ({ n, mediaType: blocks[i].source.media_type, data: blocks[i].source.data }))
}

/**
 * The cells a `width` × `height` picture fills: at most `maxColumns` × `maxRows`, its shape kept. A terminal cell is
 * about twice as tall as it is wide.
 */
export function cellSize(width, height, maxColumns, maxRows) {
  const shape = (width / height) * 2
  let rows = maxRows
  let columns = Math.round(rows * shape)
  if (columns > maxColumns) {
    columns = maxColumns
    rows = Math.max(1, Math.round(columns / shape))
  }
  return { columns: Math.max(1, columns), rows }
}

/** `sips -g pixelWidth -g pixelHeight` output → `{ width, height }`, or null. */
export function parseSize(stdout) {
  const width = /pixelWidth:\s*(\d+)/.exec(stdout)
  const height = /pixelHeight:\s*(\d+)/.exec(stdout)
  return width && height ? { width: Number(width[1]), height: Number(height[1]) } : null
}

/** The image paths Glance Studio says were dropped within `withinMs` of `nowMs`, from its image-drops.json. */
export function recentDrops(json, nowMs, withinMs) {
  try {
    const record = JSON.parse(json)
    if (typeof record.at !== 'number' || !Array.isArray(record.paths)) return []
    const atMs = record.at * 1000
    return nowMs - atMs <= withinMs && atMs <= nowMs + 1000 ? record.paths.map((path) => ({ path, at: record.at })) : []
  } catch {
    return []
  }
}

const IMAGE_FILE = /\.(png|jpe?g|gif|webp|heic|tiff?|bmp)$/i

/**
 * What the clipboard script found: `{ file }` for a copied file or a pasted path that names an image, `{ png }` for
 * image data it wrote, or null.
 */
export function parseClipboard(stdout) {
  const out = stdout.trim()
  if (out.startsWith('png:')) return { png: out.slice(4) }
  if (out.startsWith('file:') || out.startsWith('text:')) {
    const path = out.slice(out.indexOf(':') + 1).trim()
    return IMAGE_FILE.test(path) ? { file: path } : null
  }
  return null
}

// osascript reads the script from stdin; argv[1] is where to write image data. A copied file wins over its icon
// (which Finder also puts on the clipboard as an image), and a path copied as text over nothing.
export const CLIPBOARD_SCRIPT = `on run argv
  try
    set f to the clipboard as «class furl»
    return "file:" & POSIX path of f
  end try
  try
    set t to the clipboard as text
    if t starts with "/" then return "text:" & t
  end try
  try
    set d to the clipboard as «class PNGf»
    set fh to open for access (POSIX file (item 1 of argv)) with write permission
    set eof fh to 0
    write d to fh
    close access fh
    return "png:" & (item 1 of argv)
  end try
  return "none"
end run
`

// sh -c: $1 a picture (any format sips reads), $2 the PNG thumbnail to write; prints the thumbnail's size.
export const THUMBNAIL_SCRIPT = 'sips -s format png -Z 640 "$1" --out "$2" >/dev/null && sips -g pixelWidth -g pixelHeight "$2"'

// The same, from base64 on stdin, decoded into $1 first.
export const THUMBNAIL_FROM_STDIN_SCRIPT = `base64 -D > "$1" && ${THUMBNAIL_SCRIPT}`
