// Direct tools (helpers/direct.py): what the focused window's application, or the system, does
// without its GUI, as typed tools. Their names start with a group; page tools have none. A
// terminal in the focused window adds terminal.read and terminal.run, served here.
import { a11y, direct, focusedWindow } from './seat.mjs'

export const DIRECT_GROUPS = /^(files|app|win|kde|desktop|media|folder|settings|doc|browser|chooser|terminal)\./

const TERMINAL_TOOLS = [
  { name: 'terminal.read', params: { 'tail?': 'integer' }, description: "The terminal's text (its last tail characters, default 4000)" },
  { name: 'terminal.run', params: { command: 'string', 'timeout?': 'seconds' },
    description: 'Type a command and Return in this terminal; returns its output once the terminal stops changing (or timeout, default 30)' },
]

async function hasTerminal() {
  const { elements } = await a11y('elements')
  return (elements ?? []).some(e => e.role === 'terminal')
}
const terminalText = async () => (await a11y('text')).text ?? ''

/** The focused application's direct tools: {name, params, description}. */
export async function directTools() {
  const window = await focusedWindow()
  if (!window) return []
  const tools = (await direct({ op: 'list', window })).tools ?? []
  return [...tools, ...(await hasTerminal() ? TERMINAL_TOOLS : [])]
}

/** The files and folders the focused window works on. */
export async function windowPaths() {
  const window = await focusedWindow()
  return window ? (await direct({ op: 'where', window })).paths ?? [] : []
}

/** Calls a direct tool; `type` types text into the focused window (terminal.run uses it). */
export async function callDirectTool(name, args, type) {
  if (name.startsWith('terminal.')) return `${name}: ${await terminalTool(name, args, type)}`
  const { result } = await direct({ op: 'call', window: await focusedWindow(), name, args })
  return `${name}: ${String(result).slice(0, 20000)}`
}

async function terminalTool(name, args, type) {
  if (!await hasTerminal()) throw new Error('the focused window has no terminal')
  if (name === 'terminal.read') {
    const tail = Number.isInteger(args.tail) && args.tail > 0 ? Math.min(args.tail, 20000) : 4000
    return (await terminalText()).trimEnd().slice(-tail)
  }
  if (name !== 'terminal.run') throw new Error(`no direct tool ${name}`)
  if (typeof args.command !== 'string' || !args.command.trim() || args.command.length > 10000) throw new Error('command must be a non-empty string of at most 10000 characters')
  const command = args.command
  if (command.includes('\n')) throw new Error('command must be one line')
  const timeout = Math.min(Math.max(Number(args.timeout) || 30, 1), 600) * 1000
  const before = await terminalText()
  await type(command + '\n')
  const deadline = performance.now() + timeout
  let last = before, stableSince = performance.now(), changed = false
  while (performance.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 250))
    const now = await terminalText()
    if (now !== last) { last = now; stableSince = performance.now(); changed = true }
    else if (changed && performance.now() - stableSince > 1000) break
  }
  const at = last.lastIndexOf(command)
  const output = (at >= 0 ? last.slice(at + command.length) : last.slice(before.length)).replace(/^\s*\n/, '').trimEnd()
  const finished = performance.now() < deadline
  return (finished ? '' : `(still running after ${timeout / 1000} s) `) + (output.slice(-8000) || '(no output)')
}

export const toolLine = t => `${t.name}(${Object.entries(t.params ?? {}).map(([k, v]) => `${k}: ${v}`).join(', ')}) — ${t.description}`

// The focused application's direct tools, in full the first time `look` shows them.
const shown = new Map()
/** The direct tools as `look` lists them: in full once per application, then by count. */
export async function directLines() {
  const tools = await directTools()
  if (!tools.length) return ''
  const window = await focusedWindow()
  const key = `${window?.pid}:${window?.app_id}`
  const names = tools.map(t => t.name).join(' ')
  if (shown.get(key) === names) return `Direct tools of ${window?.app_id ?? 'this app'}: the ${tools.length} listed before.`
  shown.set(key, names)
  const actions = tools.filter(t => /^(app|win|kde)\./.test(t.name))
  const others = tools.filter(t => !/^(app|win|kde)\./.test(t.name))
  const lines = [`Direct tools of ${window?.app_id ?? 'this app'} (no GUI needed; act {"tool":name,"args":{…}}):`, ...others.map(toolLine)]
  if (actions.length) lines.push(actionLine(actions))
  return lines.join('\n')
}

/**
 * D-Bus actions grouped by their name up to the last dot, each with its argument: (state) for a
 * toggle, (type) for one taking a value; within about 1500 characters, a group too long for the
 * room left showing its first names.
 */
export function actionLine(actions) {
  const groups = new Map()
  for (const t of actions) {
    const at = t.name.lastIndexOf('.')
    const arg = t.params?.value ? `(${t.params.value})` : t.params?.['state?'] ? '(state)' : ''
    const key = t.name.slice(0, at)
    groups.set(key, [...(groups.get(key) ?? []), t.name.slice(at + 1) + arg])
  }
  let shownText = '', left = 0
  for (const [prefix, names] of groups) {
    const room = 1500 - shownText.length
    if (room < 80) { left += names.length; continue }
    let kept = names
    const render = list => list.length > 1 ? `${prefix}.{${list.join(',')}${list.length < names.length ? ',…' : ''}}` : `${prefix}.${list[0]}`
    while (kept.length > 1 && render(kept).length > room) kept = kept.slice(0, Math.max(1, Math.floor(kept.length * 0.8)))
    shownText += (shownText ? ' ' : '') + render(kept)
    left += names.length - kept.length
  }
  return `D-Bus actions (GApplication, KDE; no args; (state) takes {"state":true|false}, (type) {"value":…}): ${shownText}`
    + (left ? ` and ${left} more (look find lists them)` : '')
}
