#!/usr/bin/env node
// caboose-desktop-mcp — lets an agent see and drive GUI apps on the agent seat (its own
// Caboose Display, whose apps run on Xwayland :101), so it never touches the owner's display. An MCP server over stdio (newline-delimited
// JSON-RPC 2.0), with no dependencies beyond node: and what the image has: a11y.py beside
// this file (the accessibility tree, through python3 and AT-SPI), and the X tools xdotool,
// wmctrl and ImageMagick's import. caboose-agentd gives it to every ACP agent in session/new,
// and answers the agent's permission requests itself.
import { execFile, spawn } from 'node:child_process'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createInterface } from 'node:readline'
import { promisify } from 'node:util'

const run = promisify(execFile)
const DISPLAY = process.env.CABOOSE_AGENT_DISPLAY ?? ':101'
const env = { ...process.env, DISPLAY }
const PROTOCOL = '2025-06-18'
// Installed side by side: /opt/caboose/desktop-mcp.mjs and /opt/caboose/a11y.py.
const A11Y = fileURLToPath(new URL('./a11y.py', import.meta.url))
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
    inputSchema: { type: 'object', properties: { window: { type: 'string', description: 'Optional window id from list_windows to capture only that window' } } },
  },
  {
    name: 'list_windows',
    description: 'List open windows on the agent display with id, title, and geometry.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'focus',
    description: 'Raise and focus a window by id.',
    inputSchema: { type: 'object', properties: { window: { type: 'string' } }, required: ['window'] },
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

function int(value, name) {
  if (!Number.isInteger(value) || value < -100000 || value > 100000) throw new Error(`${name} must be an integer`)
  return String(value)
}

function text(value, name, max) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${name} must be a non-empty string`)
  if (value.length > max) throw new Error(`${name} must be at most ${max} characters`)
  return value
}

/** Runs a11y.py on the agent display; it always answers one JSON object. */
async function a11y(command, options) {
  const args = [A11Y, command, `--display=${DISPLAY}`, ...Object.entries(options).map(([key, value]) => `--${key}=${value}`)]
  let stdout
  try {
    ({ stdout } = await run('python3', args, { env, timeout: 60_000, maxBuffer: 16 * 1024 * 1024 }))
  } catch (error) {
    let answer
    try { answer = JSON.parse(error.stdout) } catch { throw error }
    const hint = error.code === 3 ? ' List the window again with elements: it has changed.' : ''
    throw new Error(`${answer.error ?? 'accessibility helper failed'}.${hint}`)
  }
  return [{ type: 'text', text: stdout.trim() }]
}

async function xdotool(...args) {
  await run('xdotool', args, { env, timeout: 15_000 })
}

async function capture(xid) {
  const { stdout } = await run('import', ['-window', xid, 'png:-'], { env, encoding: 'buffer', maxBuffer: 64 * 1024 * 1024, timeout: 20_000 })
  return Buffer.from(stdout)
}

/**
 * The agent display as one image in screen coordinates. Xwayland runs rootless, so its root
 * window has no picture of its own; instead each viewable window is captured and laid out
 * where it is, bottom to top.
 */
async function captureSeat() {
  const { stdout } = await run('xprop', ['-root', '-notype', '_NET_CLIENT_LIST_STACKING'], { env, timeout: 5_000 }).catch(() => ({ stdout: '' }))
  const windows = []
  for (const xid of stdout.match(/0x[0-9a-f]+/gi) ?? []) {
    const info = (await run('xwininfo', ['-id', xid], { env, timeout: 5_000 }).catch(() => ({ stdout: '' }))).stdout
    const field = name => Number(new RegExp(`${name}:\\s+(-?\\d+)`).exec(info)?.[1] ?? NaN)
    const [x, y, width, height] = [field('Absolute upper-left X'), field('Absolute upper-left Y'), field('Width'), field('Height')]
    if (/IsViewable/.test(info) && [x, y, width, height].every(Number.isFinite) && width > 1 && height > 1) windows.push({ xid, x, y, width, height })
  }
  if (!windows.length) return undefined
  const right = Math.min(4096, Math.max(...windows.map(w => w.x + w.width)))
  const bottom = Math.min(4096, Math.max(...windows.map(w => w.y + w.height)))
  const dir = await mkdtemp(join(tmpdir(), 'caboose-shot-'))
  try {
    const layers = []
    for (const [index, w] of windows.entries()) {
      const file = join(dir, `${index}.png`)
      await writeFile(file, await capture(w.xid))
      layers.push(file, '-geometry', `+${w.x}+${w.y}`, '-composite')
    }
    const { stdout: png } = await run('convert', ['-size', `${right}x${bottom}`, 'xc:#1e1e1e', ...layers, 'png:-'],
      { env, encoding: 'buffer', maxBuffer: 64 * 1024 * 1024, timeout: 30_000 })
    return Buffer.from(png)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

const handlers = {
  elements: () => a11y('elements', {}),
  find: ({ query, role }) => a11y('find', { query: text(query, 'query', 500), ...(role === undefined ? {} : { role: text(role, 'role', 60) }) }),
  click_element: ({ id }) => a11y('act', { element: text(id, 'id', 500), action: 'press' }),
  set_text: ({ id, text: value }) => {
    if (typeof value !== 'string' || value.length > 100_000) throw new Error('text must be a string of at most 100000 characters')
    return a11y('act', { element: text(id, 'id', 500), action: 'set-text', text: value })
  },
  read_text: () => a11y('text', {}),
  async screenshot({ window }) {
    if (window !== undefined && !/^(0x[0-9a-f]+|\d+)$/i.test(String(window))) throw new Error('window must be an id from list_windows')
    const png = window !== undefined ? await capture(String(window)) : await captureSeat()
    if (!png) return [{ type: 'text', text: 'No windows are open on the agent display.' }]
    return [{ type: 'image', data: png.toString('base64'), mimeType: 'image/png' }]
  },
  async list_windows() {
    const { stdout } = await run('wmctrl', ['-lG'], { env, timeout: 10_000 })
    const windows = stdout.trim().split('\n').filter(Boolean).map(line => {
      const [id, desktop, x, y, w, h, , ...title] = line.trim().split(/\s+/)
      return { id, desktop: Number(desktop), x: Number(x), y: Number(y), width: Number(w), height: Number(h), title: title.join(' ') }
    })
    return [{ type: 'text', text: JSON.stringify(windows, null, 2) }]
  },
  async focus({ window }) {
    if (!/^(0x[0-9a-f]+|\d+)$/i.test(String(window))) throw new Error('window must be an id from list_windows')
    await run('wmctrl', ['-ia', String(window)], { env, timeout: 10_000 })
    return [{ type: 'text', text: `Focused ${window}.` }]
  },
  async click({ x, y, button = 1, count = 1 }) {
    await xdotool('mousemove', '--sync', int(x, 'x'), int(y, 'y'), 'click', '--repeat', int(count, 'count'), int(button, 'button'))
    return [{ type: 'text', text: `Clicked button ${button} at ${x},${y}.` }]
  },
  async drag({ x1, y1, x2, y2 }) {
    await xdotool('mousemove', '--sync', int(x1, 'x1'), int(y1, 'y1'), 'mousedown', '1',
      'mousemove', '--sync', int(x2, 'x2'), int(y2, 'y2'), 'mouseup', '1')
    return [{ type: 'text', text: `Dragged from ${x1},${y1} to ${x2},${y2}.` }]
  },
  async type({ text }) {
    if (typeof text !== 'string') throw new Error('text must be a string')
    await xdotool('type', '--delay', '8', '--', text)
    return [{ type: 'text', text: `Typed ${text.length} characters.` }]
  },
  async key({ combo }) {
    if (typeof combo !== 'string' || !/^[A-Za-z0-9_+]+$/.test(combo)) throw new Error('combo must look like "ctrl+s" or "Return"')
    await xdotool('key', '--', combo)
    return [{ type: 'text', text: `Pressed ${combo}.` }]
  },
  async scroll({ x, y, dx = 0, dy = 0 }) {
    await xdotool('mousemove', '--sync', int(x, 'x'), int(y, 'y'))
    const steps = []
    if (dy) steps.push('click', '--repeat', String(Math.min(50, Math.abs(dy))), dy > 0 ? '5' : '4')
    if (dx) steps.push('click', '--repeat', String(Math.min(50, Math.abs(dx))), dx > 0 ? '7' : '6')
    if (steps.length) await xdotool(...steps)
    return [{ type: 'text', text: `Scrolled ${dx},${dy} at ${x},${y}.` }]
  },
  async launch({ command }) {
    if (typeof command !== 'string' || !command.trim()) throw new Error('command must be a non-empty string')
    const child = spawn('/bin/sh', ['-c', command], { env: launchEnv, detached: true, stdio: 'ignore' })
    child.unref()
    return [{ type: 'text', text: `Started: ${command}` }]
  },
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

const lines = createInterface({ input: process.stdin })
lines.on('line', line => {
  if (!line.trim()) return
  let message
  try { message = JSON.parse(line) } catch { return fail(null, -32700, 'parse error') }
  void handle(message)
})
