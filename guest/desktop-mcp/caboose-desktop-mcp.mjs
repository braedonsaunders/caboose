#!/usr/bin/env node
// caboose-desktop-mcp — lets an agent see and drive GUI apps on the agent seat, its own
// Caboose Display, so it never touches the owner's display. An MCP server over stdio
// (newline-delimited JSON-RPC 2.0), with no dependencies beyond node: and two helpers beside
// this file: a11y.py (the accessibility tree, through python3 and AT-SPI) and seat.py (the
// seat's windows, pointer, keyboard and pictures, through its control socket). Wayland and
// X11 applications are driven alike. caboose-agentd gives it to every ACP agent in
// session/new, and answers the agent's permission requests itself.
import { spawn } from 'node:child_process'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { appendFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createInterface } from 'node:readline'
import { Worker } from './worker.mjs'
import { Observer } from './observation.mjs'
import { controlAlive, ensureAgentSeat } from './ensure-agent-seat.mjs'

const DISPLAY = process.env.CABOOSE_AGENT_DISPLAY ?? ':101'
const env = { ...process.env, DISPLAY }
const PROTOCOL = '2025-06-18'
// CABOOSE_DESKTOP_TRACE: a file that gets one line per tool call (tool, milliseconds, reply size).
const TRACE = process.env.CABOOSE_DESKTOP_TRACE
// Installed side by side: /opt/caboose/desktop-mcp.mjs, a11y.py and seat.py.
const A11Y = fileURLToPath(new URL('./a11y.py', import.meta.url))
const SEAT = fileURLToPath(new URL('./seat.py', import.meta.url))
const LAUNCHER = fileURLToPath(new URL('./launcher.py', import.meta.url))
// What a launched app needs to build its accessibility tree: GTK's bridge must not be
// switched off (NO_AT_BRIDGE, GTK_A11Y=none), Chromium and Electron read
// ACCESSIBILITY_ENABLED, Firefox GNOME_ACCESSIBILITY, Qt QT_LINUX_ACCESSIBILITY_ALWAYS_ON.
// The seat is a Wayland session; saying so makes Chromium and Electron run as Wayland
// clients, whose fields take the seat's text and whose windows place their controls exactly.
const launchEnv = { ...env, ACCESSIBILITY_ENABLED: '1', GNOME_ACCESSIBILITY: '1', QT_LINUX_ACCESSIBILITY_ALWAYS_ON: '1', XDG_SESSION_TYPE: 'wayland' }
delete launchEnv.NO_AT_BRIDGE
if (launchEnv.GTK_A11Y === 'none') delete launchEnv.GTK_A11Y

// Three tools, kept short: their definitions go to the model on every turn.
const tools = [
  {
    name: 'look',
    description: 'The focused window\'s controls from its accessibility tree, one per line: id role "name" = value [states]. '
      + 'find: only controls whose name contains it. text: also the window\'s readable text (documents, pages, terminals). '
      + 'windows: every window, with its id and position.',
    inputSchema: { type: 'object', properties: { find: { type: 'string' }, text: { type: 'boolean' }, windows: { type: 'boolean' } } },
  },
  {
    name: 'act',
    description: 'Run steps in order, stopping at the first failure; then reply with what changed (+ added, ~ changed, - removed '
      + 'controls; windows opened or closed). Put every step you already know in one call. A step is one of: {"press":id} '
      + '{"set":id,"text":t} replaces a field\'s text, {"key":"ctrl+s"}, {"type":t}, {"click":[x,y],"button":1-3,"count":1-3}, '
      + '{"scroll":[x,y],"dy":n}, {"drag":[x1,y1,x2,y2]}, {"focus":window}, {"wait":ms}, {"launch":"command"}.',
    inputSchema: { type: 'object', properties: { steps: { type: 'array', items: { type: 'object' } } }, required: ['steps'] },
  },
  {
    name: 'screenshot',
    description: 'A picture of the seat, or of one window. Only for what the controls do not tell; coordinates are its pixels. '
      + 'marks: number the controls on it.',
    inputSchema: { type: 'object', properties: { window: { type: 'integer' }, marks: { type: 'boolean' } } },
  },
]

function int(value, name) {
  if (!Number.isInteger(value) || value < -100000 || value > 100000) throw new Error(`${name} must be an integer`)
  return String(value)
}

function text(value, name, max) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${name} must be a non-empty string`)
  if (value.length > max) throw new Error(`${name} must be at most ${max} characters`)
  return value
}

const observer = new Observer()
const a11yWorker = new Worker(A11Y, [`--display=${DISPLAY}`], 30_000)
const seatWorker = new Worker(SEAT)
let seatEnvironment
// These tools are the seat's assistive technology, and say so on its accessibility bus as a
// screen reader does: Chromium, Electron and other toolkits that build their full tree only
// for one then expose it to applications started afterwards.
function announceAssistiveTechnology(seatEnv) {
  const child = spawn('gdbus', ['call', '--session', '--dest', 'org.a11y.Bus', '--object-path', '/org/a11y/bus', '--method',
    'org.freedesktop.DBus.Properties.Set', 'org.a11y.Status', 'ScreenReaderEnabled', '<true>'], { env: { ...env, ...seatEnv }, stdio: 'ignore' })
  child.on('error', () => {})
  return new Promise(resolve => { child.on('exit', resolve); child.on('error', resolve) })
}
async function workerRequest(worker, request) {
  const ready = await ensureAgentSeat()
  if (ready !== seatEnvironment) {
    a11yWorker.close()
    seatWorker.close()
    seatEnvironment = ready
    await announceAssistiveTechnology(ready)
  }
  Object.assign(env, ready, { DISPLAY })
  try {
    const answer = await worker.request(request, env)
    if (answer.error) throw new Error(answer.error)
    return answer
  } catch (error) {
    if (!await controlAlive(env)) ensureAgentSeat.invalidate()
    throw error
  }
}
async function a11y(command, options) {
  if (command === 'act') { actedAt = Number(process.hrtime.bigint() / 1000n); typed = options?.action === 'set-text' }
  const answer = await workerRequest(a11yWorker, { op: command, ...options })
  return [{ type: 'text', text: JSON.stringify(answer) }]
}
async function seat(...args) { return workerRequest(seatWorker, { args }) }

const BUTTONS = { 1: 'left', 2: 'middle', 3: 'right' }

// The display as the observer renders it: everything (`full`), or what changed since the last time.
async function view(full) {
  const state = JSON.parse((await a11y('elements', {}))[0].text)
  const listing = await seat('windows')
  return observer.render(listing, state, { full })
}
const element = id => observer.resolve(text(id, 'id', 500))

function windowLines(windows) {
  return windows.length ? windows.map(w => `${w.kind} ${w.id} ${JSON.stringify(w.title ?? '')} (${w.app_id ?? 'unknown app'})`
    + `${w.parent != null ? ` of ${w.parent}` : ''} at ${w.rect.join(',')}${w.focused ? ', focused' : ''}`).join('\n') : 'No windows are open on the agent seat.'
}

// When the last action went in, on the compositor's clock (CLOCK_MONOTONIC): the next
// settled observation waits for the seat to react to it.
let actedAt, typed = false
async function changes() {
  // A text edit is processed asynchronously (completion, validation): wait for the window to
  // go quiet. After a press, the first reaction is enough for an accessibility read.
  await seat('settle', typed ? 'quiet' : 'react', ...(actedAt === undefined ? [] : [String(actedAt)]))
  actedAt = undefined; typed = false
  return view(false)
}

// The window an element id names must still have the keyboard (or own the open menu that does).
async function inFocusedWindow(id) {
  const listing = await seat('windows')
  let focused = listing.focused
  const seen = new Set()
  while (!seen.has(focused)) {
    seen.add(focused)
    const window = listing.windows.find(w => w.id === focused)
    if (window?.kind !== 'popup' || window.parent == null) break
    focused = window.parent
  }
  if (parseInt(id.split('-')[0], 16) !== focused) throw new Error('element not found: the focused window changed; look again')
}

const point = (value, name, size) => {
  if (!Array.isArray(value) || value.length !== size) throw new Error(`${name} must be [${size === 2 ? 'x,y' : 'x1,y1,x2,y2'}]`)
  return value.map((v, i) => int(v, `${name}[${i}]`))
}

// One act step; returns a note for the reply, if any.
async function step(s) {
  if (!s || typeof s !== 'object') throw new Error('a step is an object such as {"press":"e3"}')
  if ('press' in s || 'set' in s) {
    const id = element('press' in s ? s.press : s.set)
    await inFocusedWindow(id)
    if ('press' in s) { await a11y('act', { element: id, action: 'press' }); return }
    if (typeof s.text !== 'string' || s.text.length > 100_000) throw new Error('set needs text, a string of at most 100000 characters')
    const { note } = JSON.parse((await a11y('act', { element: id, action: 'set-text', text: s.text }))[0].text)
    return note
  }
  actedAt = Number(process.hrtime.bigint() / 1000n)
  if ('key' in s) {
    if (typeof s.key !== 'string' || !/^[A-Za-z0-9_+]+$/.test(s.key)) throw new Error('key must look like "ctrl+s" or "Return"')
    await seat('key', '--', s.key)
  } else if ('type' in s) {
    if (typeof s.type !== 'string') throw new Error('type must be a string')
    typed = true
    await seat('type', '--', s.type)
  } else if ('click' in s) {
    const [x, y] = point(s.click, 'click', 2), button = s.button ?? 1, count = s.count ?? 1
    if (!BUTTONS[button]) throw new Error('button must be 1 (left), 2 (middle) or 3 (right)')
    if (![1, 2, 3].includes(count)) throw new Error('count must be 1, 2 or 3')
    await seat('click', x, y, '--button', BUTTONS[button], '--count', String(count))
  } else if ('scroll' in s) {
    const [x, y] = point(s.scroll, 'scroll', 2)
    const clamp = (value, name) => String(Math.max(-50, Math.min(50, Number(int(value ?? 0, name)))))
    await seat('scroll', x, y, clamp(s.dx, 'dx'), clamp(s.dy, 'dy'))
  } else if ('drag' in s) {
    await seat('drag', ...point(s.drag, 'drag', 4))
  } else if ('focus' in s) {
    if (!Number.isInteger(s.focus)) throw new Error('focus must be a window id')
    await seat('focus', String(s.focus))
  } else if ('wait' in s) {
    if (!Number.isInteger(s.wait) || s.wait < 10 || s.wait > 5000) throw new Error('wait must be 10–5000 ms')
    await new Promise(resolve => setTimeout(resolve, s.wait))
  } else if ('launch' in s) {
    const command = text(s.launch, 'launch', 2000)
    const ready = await ensureAgentSeat()
    Object.assign(launchEnv, ready, { DISPLAY })
    await announceAssistiveTechnology(ready)
    spawn('python3', [LAUNCHER, command], { env: launchEnv, detached: true, stdio: 'ignore' }).unref()
  } else throw new Error('unknown step; use press, set, key, type, click, scroll, drag, focus, wait or launch')
}

const handlers = {
  async look({ find, text: withText = false, windows = false } = {}) {
    const parts = []
    if (windows) parts.push(windowLines((await seat('windows')).windows))
    if (find !== undefined) {
      const { elements, note } = JSON.parse((await a11y('find', { query: text(find, 'find', 500) }))[0].text)
      const lines = (elements ?? []).map(e => observer.line(observer.short(e.id), e))
      parts.push(lines.length ? lines.join('\n') : (note ?? 'No control matches.'))
    } else parts.push(await view(true))
    if (withText) {
      const { text: readable } = JSON.parse((await a11y('text', {}))[0].text)
      parts.push(`Text:\n${readable ?? ''}`)
    }
    return [{ type: 'text', text: parts.join('\n') }]
  },
  async act({ steps, observe = true }) {
    if (!Array.isArray(steps) || steps.length < 1 || steps.length > 30) throw new Error('steps must hold 1–30 steps')
    let done = 0, error
    const notes = []
    for (const s of steps) {
      try { const note = await step(s); if (note) notes.push(note); done++ } catch (e) { error = e.message; break }
    }
    const head = done === steps.length ? (steps.length > 1 ? `Done ${done} steps.` : 'Done.') : `Did ${done} of ${steps.length}; stopped: ${error}`
    const content = [head + (notes.length ? ` (${notes.join('; ')})` : '')]
    if (observe) {
      try { content.push(await changes()) } catch (e) { content.push(`Could not read the window: ${e.message}`) }
    }
    return [{ type: 'text', text: content.join('\n') }]
  },
  async screenshot({ window, marks = false }) {
    if (window !== undefined && !Number.isInteger(window)) throw new Error('window must be a window id')
    if (typeof marks !== 'boolean') throw new Error('marks must be a boolean')
    const dir = await mkdtemp(join(tmpdir(), 'caboose-shot-'))
    try {
      const file = join(dir, 'seat.png')
      const shot = await seat('screenshot', '--out', file, ...(window === undefined ? [] : ['--window', String(window)]))
      let legend
      if (marks) {
        const state = JSON.parse((await a11y('elements', {}))[0].text)
        ;({ legend } = await seat('annotate', file, shot.rect, state.elements, window ?? null))
        legend = legend?.map(entry => `${entry.mark} ${observer.short(entry.id)} ${entry.role} ${JSON.stringify(entry.name ?? '')} at ${entry.center.join(',')}`)
      }
      return [{ type: 'image', data: (await readFile(file)).toString('base64'), mimeType: 'image/png' },
        ...(legend ? [{ type: 'text', text: legend.join('\n') }] : [])]
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  },
}

// How to use the tools, sent once to the agent when it connects.
const INSTRUCTIONS = 'Read the agent seat with look, act on controls by id, and batch known steps in one act; each act replies with what changed.'

function reply(id, result) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n') }
function fail(id, code, message) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }) + '\n') }

async function handle(message) {
  const { id, method, params } = message
  if (method === 'initialize') {
    return reply(id, { protocolVersion: params?.protocolVersion ?? PROTOCOL, capabilities: { tools: {} },
      serverInfo: { name: 'caboose-desktop', version: '1.0.0' }, instructions: INSTRUCTIONS })
  }
  if (method === 'notifications/initialized' || id === undefined) return
  if (method === 'ping') return reply(id, {})
  if (method === 'tools/list') return reply(id, { tools })
  if (method === 'tools/call') {
    const handler = handlers[params?.name]
    if (!handler) return fail(id, -32602, `unknown tool ${params?.name}`)
    const started = performance.now()
    try {
      const content = await handler(params.arguments ?? {})
      reply(id, { content })
      if (TRACE) appendFileSync(TRACE, JSON.stringify({ tool: params.name, ms: Math.round(performance.now() - started),
        chars: content.reduce((n, part) => n + (part.text?.length ?? 0), 0), images: content.filter(part => part.type === 'image').length }) + '\n')
    } catch (error) {
      reply(id, { content: [{ type: 'text', text: String(error?.stderr || error?.message || error).trim() }], isError: true })
    }
    return
  }
  fail(id, -32601, `method not found: ${method}`)
}

let queue = Promise.resolve()
const lines = createInterface({ input: process.stdin })
lines.on('line', line => {
  if (!line.trim()) return
  let message
  try { message = JSON.parse(line) } catch { return fail(null, -32700, 'parse error') }
  queue = queue.then(() => handle(message))
})

const close = () => { a11yWorker.close(); seatWorker.close() }
lines.on('close', () => { void queue.finally(close) })
process.on('SIGTERM', () => { close(); process.exit(0) })
process.on('SIGINT', () => { close(); process.exit(0) })
process.on('exit', close)
