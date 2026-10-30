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
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createInterface } from 'node:readline'
import { Worker } from './worker.mjs'
import { controlAlive, ensureAgentSeat } from './ensure-agent-seat.mjs'

const DISPLAY = process.env.CABOOSE_AGENT_DISPLAY ?? ':101'
const env = { ...process.env, DISPLAY }
const PROTOCOL = '2025-06-18'
// Installed side by side: /opt/caboose/desktop-mcp.mjs, a11y.py and seat.py.
const A11Y = fileURLToPath(new URL('./a11y.py', import.meta.url))
const SEAT = fileURLToPath(new URL('./seat.py', import.meta.url))
// What a launched app needs to build its accessibility tree: GTK's bridge must not be
// switched off (NO_AT_BRIDGE, GTK_A11Y=none), Chromium and Electron read
// ACCESSIBILITY_ENABLED, Firefox GNOME_ACCESSIBILITY, Qt QT_LINUX_ACCESSIBILITY_ALWAYS_ON.
const launchEnv = { ...env, ACCESSIBILITY_ENABLED: '1', GNOME_ACCESSIBILITY: '1', QT_LINUX_ACCESSIBILITY_ALWAYS_ON: '1' }
delete launchEnv.NO_AT_BRIDGE
if (launchEnv.GTK_A11Y === 'none') delete launchEnv.GTK_A11Y

const tools = [
  {
    name: 'elements',
    description: 'List the controls of the focused window on the agent display, read from its accessibility tree: '
      + 'buttons, links, fields, check boxes, menus, tabs, list items and headings, each with an id, role, name, '
      + 'states and bounds in screen pixels (at most 200, in reading order). Instant and needs no screenshot, so '
      + 'use this first to see what a window offers, then act with click_element and set_text. Ids stay valid '
      + 'until the window changes; list again after it does. If it returns a note and no elements, the window '
      + 'has no accessibility tree: use screenshot and click instead.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'find',
    description: 'Find elements of the focused window on the agent display whose name contains the query '
      + '(case-insensitive), optionally of one role such as "button", "link", "entry", "check box", "menu item" '
      + 'or "page tab". Same element shape as elements; prefer it to a screenshot for locating a control.',
    inputSchema: {
      type: 'object',
      properties: { query: { type: 'string', description: 'Text to look for in element names' }, role: { type: 'string', description: 'Optional role, e.g. "button"' } },
      required: ['query'],
    },
  },
  {
    name: 'click_element',
    description: 'Press an element by its id from elements or find: performs its accessibility action (click, press, '
      + 'activate, follow a link), or clicks its centre when it has none. Prefer this to click with coordinates.',
    inputSchema: { type: 'object', properties: { id: { type: 'string', description: 'Element id from elements or find' } }, required: ['id'] },
  },
  {
    name: 'set_text',
    description: 'Replace the text of an editable element (a field or text area) by its id from elements or find. '
      + 'Prefer this to clicking and typing.',
    inputSchema: { type: 'object', properties: { id: { type: 'string' }, text: { type: 'string' } }, required: ['id', 'text'] },
  },
  {
    name: 'read_text',
    description: 'Read the focused window\'s text on the agent display from its accessibility tree: labels, documents '
      + 'and web page text, in reading order, up to about 20000 characters. Prefer this to a screenshot for reading.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'screenshot',
    description: 'Capture the agent display as a PNG. Coordinates in other tools use this image\'s pixels. Slower and '
      + 'costlier than elements, find and read_text: use it for what the accessibility tree does not show.',
    inputSchema: { type: 'object', properties: { window: { type: 'integer', description: 'Optional window id from list_windows to capture only that window' } } },
  },
  {
    name: 'list_windows',
    description: 'List open windows on the agent display, bottom to top, with id, title, application, geometry and which has the keyboard.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'focus',
    description: 'Raise and focus a window by id.',
    inputSchema: { type: 'object', properties: { window: { type: 'integer' } }, required: ['window'] },
  },
  {
    name: 'click',
    description: 'Move the pointer to (x, y) and click. button: 1 left, 2 middle, 3 right. count: 2 for double-click.',
    inputSchema: { type: 'object', properties: { x: { type: 'integer' }, y: { type: 'integer' }, button: { type: 'integer', default: 1 }, count: { type: 'integer', default: 1 } }, required: ['x', 'y'] },
  },
  {
    name: 'drag',
    description: 'Press at (x1, y1), move to (x2, y2), release.',
    inputSchema: { type: 'object', properties: { x1: { type: 'integer' }, y1: { type: 'integer' }, x2: { type: 'integer' }, y2: { type: 'integer' } }, required: ['x1', 'y1', 'x2', 'y2'] },
  },
  {
    name: 'type',
    description: 'Type text into the focused window.',
    inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] },
  },
  {
    name: 'key',
    description: 'Press a key or combination, e.g. "Return", "ctrl+s", "ctrl+shift+t", "alt+F4".',
    inputSchema: { type: 'object', properties: { combo: { type: 'string' } }, required: ['combo'] },
  },
  {
    name: 'scroll',
    description: 'Scroll at (x, y): positive dy scrolls down, positive dx scrolls right, in wheel steps.',
    inputSchema: { type: 'object', properties: { x: { type: 'integer' }, y: { type: 'integer' }, dx: { type: 'integer', default: 0 }, dy: { type: 'integer', default: 0 } }, required: ['x', 'y'] },
  },
  {
    name: 'launch',
    description: 'Start a GUI application on the agent display, e.g. "chromium https://example.com" or "libreoffice --calc".',
    inputSchema: { type: 'object', properties: { command: { type: 'string' } }, required: ['command'] },
  },
]

tools.find(t => t.name === 'screenshot').inputSchema.properties.annotate = { type: 'boolean', default: false, description: 'Overlay numbered accessibility bounds and return an id/bounds legend.' }
const mutations = ['click_element', 'set_text', 'click', 'drag', 'type', 'key', 'scroll', 'focus']
for (const tool of tools) {
  if (mutations.includes(tool.name)) tool.inputSchema.properties.observe = { type: 'boolean', default: false, description: 'Return updated focused-window elements after the action.' }
}
const stepProperties = Object.assign({}, ...tools.filter(t => mutations.includes(t.name)).map(t => t.inputSchema.properties))
delete stepProperties.observe
stepProperties.action = { type: 'string', enum: [...mutations, 'focus_element', 'wait'] }
stepProperties.ms = { type: 'integer', minimum: 10, maximum: 5000 }
tools.splice(4, 0, {
  name: 'batch', description: 'Execute 1–20 actions sequentially, stopping at the first failure. Returns completed count and updated elements by default.',
  inputSchema: { type: 'object', properties: {
    steps: { type: 'array', minItems: 1, maxItems: 20, items: { type: 'object', properties: stepProperties, required: ['action'] } },
    observe: { type: 'boolean', default: true },
  }, required: ['steps'] },
})

function int(value, name) {
  if (!Number.isInteger(value) || value < -100000 || value > 100000) throw new Error(`${name} must be an integer`)
  return String(value)
}

function text(value, name, max) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${name} must be a non-empty string`)
  if (value.length > max) throw new Error(`${name} must be at most ${max} characters`)
  return value
}

const a11yWorker = new Worker(A11Y, [`--display=${DISPLAY}`])
const seatWorker = new Worker(SEAT)
let seatEnvironment
async function workerRequest(worker, request) {
  const ready = await ensureAgentSeat()
  if (ready !== seatEnvironment) {
    a11yWorker.close()
    seatWorker.close()
    seatEnvironment = ready
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
  const answer = await workerRequest(a11yWorker, { op: command, ...options })
  return [{ type: 'text', text: JSON.stringify(answer) }]
}
async function seat(...args) { return workerRequest(seatWorker, { args }) }

const BUTTONS = { 1: 'left', 2: 'middle', 3: 'right' }

const handlers = {
  elements: () => a11y('elements', {}),
  find: ({ query, role }) => a11y('find', { query: text(query, 'query', 500), ...(role === undefined ? {} : { role: text(role, 'role', 60) }) }),
  click_element: ({ id }) => a11y('act', { element: text(id, 'id', 500), action: 'press' }),
  set_text: ({ id, text: value }) => {
    if (typeof value !== 'string' || value.length > 100_000) throw new Error('text must be a string of at most 100000 characters')
    return a11y('act', { element: text(id, 'id', 500), action: 'set-text', text: value })
  },
  read_text: () => a11y('text', {}),
  async screenshot({ window, annotate = false }) {
    if (window !== undefined && !Number.isInteger(window)) throw new Error('window must be an id from list_windows')
    if (typeof annotate !== 'boolean') throw new Error('annotate must be a boolean')
    const dir = await mkdtemp(join(tmpdir(), 'caboose-shot-'))
    try {
      const file = join(dir, 'seat.png')
      const shot = await seat('screenshot', '--out', file, ...(window === undefined ? [] : ['--window', String(window)]))
      let legend
      if (annotate) {
        const state = JSON.parse((await a11y('elements', {}))[0].text)
        ;({ legend } = await seat('annotate', file, shot.rect, state.elements, window ?? null))
      }
      return [{ type: 'image', data: (await readFile(file)).toString('base64'), mimeType: 'image/png' },
        ...(legend ? [{ type: 'text', text: JSON.stringify(legend) }] : [])]
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  },
  async list_windows() {
    const { windows } = await seat('windows')
    const listed = windows.map(w => ({ id: w.id, kind: w.kind, title: w.title, app: w.app_id,
      x: w.rect[0], y: w.rect[1], width: w.rect[2], height: w.rect[3], focused: w.focused, ...(w.parent == null ? {} : { parent: w.parent }) }))
    return [{ type: 'text', text: listed.length ? JSON.stringify(listed, null, 2) : 'No windows are open on the agent display.' }]
  },
  async focus({ window }) {
    if (!Number.isInteger(window)) throw new Error('window must be an id from list_windows')
    await seat('focus', String(window))
    return [{ type: 'text', text: `Focused ${window}.` }]
  },
  async click({ x, y, button = 1, count = 1 }) {
    if (!BUTTONS[button]) throw new Error('button must be 1 (left), 2 (middle) or 3 (right)')
    if (![1, 2, 3].includes(count)) throw new Error('count must be 1, 2 or 3')
    await seat('click', int(x, 'x'), int(y, 'y'), '--button', BUTTONS[button], '--count', String(count))
    return [{ type: 'text', text: `Clicked button ${button} at ${x},${y}.` }]
  },
  async drag({ x1, y1, x2, y2 }) {
    await seat('drag', int(x1, 'x1'), int(y1, 'y1'), int(x2, 'x2'), int(y2, 'y2'))
    return [{ type: 'text', text: `Dragged from ${x1},${y1} to ${x2},${y2}.` }]
  },
  async type({ text }) {
    if (typeof text !== 'string') throw new Error('text must be a string')
    await seat('type', '--', text)
    return [{ type: 'text', text: `Typed ${text.length} characters.` }]
  },
  async key({ combo }) {
    if (typeof combo !== 'string' || !/^[A-Za-z0-9_+]+$/.test(combo)) throw new Error('combo must look like "ctrl+s" or "Return"')
    await seat('key', '--', combo)
    return [{ type: 'text', text: `Pressed ${combo}.` }]
  },
  async scroll({ x, y, dx = 0, dy = 0 }) {
    const clamp = (value, name) => String(Math.max(-50, Math.min(50, Number(int(value, name)))))
    await seat('scroll', int(x, 'x'), int(y, 'y'), clamp(dx, 'dx'), clamp(dy, 'dy'))
    return [{ type: 'text', text: `Scrolled ${dx},${dy} at ${x},${y}.` }]
  },
  async launch({ command }) {
    if (typeof command !== 'string' || !command.trim()) throw new Error('command must be a non-empty string')
    Object.assign(launchEnv, await ensureAgentSeat(), { DISPLAY })
    const child = spawn('/bin/sh', ['-c', command], { env: launchEnv, detached: true, stdio: 'ignore' })
    child.unref()
    return [{ type: 'text', text: `Started: ${command}` }]
  },
}

async function observe() {
  await seat('settle')
  return JSON.parse((await handlers.elements())[0].text)
}
handlers.batch = async ({ steps, observe: observing = true }) => {
  if (!Array.isArray(steps) || steps.length < 1 || steps.length > 20) throw new Error('steps must contain 1–20 actions')
  if (typeof observing !== 'boolean') throw new Error('observe must be a boolean')
  const result = { completed: 0, total: steps.length }
  for (const step of steps) {
    try {
      if (!step || !stepProperties.action.enum.includes(step.action)) throw new Error('unknown batch action')
      if (['click_element', 'set_text', 'focus_element'].includes(step.action)) {
        const id = text(step.id, 'id', 500)
        const listing = await seat('windows')
        let focused = listing.focused
        const seen = new Set()
        while (!seen.has(focused)) {
          seen.add(focused)
          const window = listing.windows.find(w => w.id === focused)
          if (window?.kind !== 'popup' || window.parent == null) break
          focused = window.parent
        }
        if (parseInt(id.split('-')[0], 16) !== focused) throw new Error('element not found: focused window changed')
      }
      if (step.action === 'wait') {
        if (!Number.isInteger(step.ms) || step.ms < 10 || step.ms > 5000) throw new Error('ms must be 10–5000')
        await new Promise(resolve => setTimeout(resolve, step.ms))
      } else if (step.action === 'focus_element') {
        await a11y('act', { element: text(step.id, 'id', 500), action: 'focus' })
      } else await handlers[step.action]({ ...step, observe: false })
      result.completed++
    } catch (error) { result.error = error.message; break }
  }
  if (observing) {
    try { result.state = await observe() } catch (error) { result.observationError = error.message }
  }
  return [{ type: 'text', text: JSON.stringify(result) }]
}
for (const name of mutations) {
  const handler = handlers[name]
  handlers[name] = async args => {
    if (args.observe !== undefined && typeof args.observe !== 'boolean') throw new Error('observe must be a boolean')
    const result = await handler(args)
    if (args.observe) {
      try { result.push({ type: 'text', text: JSON.stringify({ state: await observe() }) }) }
      catch (error) { result.push({ type: 'text', text: JSON.stringify({ observationError: error.message }) }) }
    }
    return result
  }
}

function reply(id, result) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n') }
function fail(id, code, message) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }) + '\n') }

async function handle(message) {
  const { id, method, params } = message
  if (method === 'initialize') {
    return reply(id, { protocolVersion: params?.protocolVersion ?? PROTOCOL, capabilities: { tools: {} },
      serverInfo: { name: 'caboose-desktop', version: '1.0.0' } })
  }
  if (method === 'notifications/initialized' || id === undefined) return
  if (method === 'ping') return reply(id, {})
  if (method === 'tools/list') return reply(id, { tools })
  if (method === 'tools/call') {
    const handler = handlers[params?.name]
    if (!handler) return fail(id, -32602, `unknown tool ${params?.name}`)
    try {
      reply(id, { content: await handler(params.arguments ?? {}) })
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
