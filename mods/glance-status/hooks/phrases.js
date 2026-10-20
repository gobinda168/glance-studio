// What a tool call is doing, in the words the Status pane's NOW line and TURN log use, and the kind that colours it
// (spec §3): read (amber), edit (green), run (teal), agent (coral-hi), plan and other (the track colour).

const PLAN_TOOLS = new Set(['TodoWrite', 'TaskCreate', 'TaskUpdate', 'TaskGet', 'TaskList'])

export function describeCall(call, cwd = '') {
  const tool = call.tool
  const arg = (name) => (typeof call[name] === 'string' ? call[name] : '')
  switch (tool) {
    case 'Read':
      return step(tool, 'read', 'Reading', relative(arg('file_path'), cwd))
    case 'Edit':
    case 'Write':
      return step(tool, 'edit', 'Editing', relative(arg('file_path'), cwd))
    case 'NotebookEdit':
      return step(tool, 'edit', 'Editing', relative(arg('notebook_path'), cwd))
    case 'Bash':
      return step(tool, 'run', 'Running', arg('description') || firstLine(arg('command')))
    case 'Grep':
    case 'Glob':
      return step(tool, 'read', 'Searching', arg('pattern'))
    case 'Agent':
      return step(tool, 'agent', 'Agent:', arg('description'))
    case 'WebSearch':
      return step(tool, 'read', 'Searching the web:', arg('query'))
    case 'WebFetch':
      return step(tool, 'read', 'Reading', host(arg('url')))
  }
  if (PLAN_TOOLS.has(tool)) return step(tool, 'plan', 'Updating the plan', '')
  const mcp = /^mcp__(.+?)__(.+)$/.exec(tool)
  if (mcp) return step(mcp[1], 'run', `${mcp[1]}:`, mcp[2])
  return step(tool, 'other', tool, '')
}

export function phrase(d) {
  return d.target ? `${d.verb} ${d.target}` : d.verb
}

function step(tool, kind, verb, target) {
  return { tool, kind, verb, target }
}

function relative(path, cwd) {
  return cwd && path.startsWith(cwd + '/') ? path.slice(cwd.length + 1) : path
}

function firstLine(text) {
  return text.split('\n')[0].trim()
}

function host(url) {
  try {
    return new URL(url).host
  } catch {
    return url
  }
}
