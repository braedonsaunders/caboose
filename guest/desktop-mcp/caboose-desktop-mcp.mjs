#!/usr/bin/env node
// caboose-desktop-mcp — lets a CLI agent (Claude Code, Codex) see and drive GUI apps on
// the agent seat, display :101, so it never touches the owner's display. An MCP server
// over stdio (newline-delimited JSON-RPC 2.0), with no dependencies beyond node: and the
// X tools in the image (xdotool, wmctrl, ImageMagick's import). It also carries `approve`,
// the permission-prompt tool through which a Claude task asks its owner before acting.
import { execFile, spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { setTimeout as sleep } from 'node:timers/promises'
import { promisify } from 'node:util'

const run = promisify(execFile)
const DISPLAY = process.env.CABOOSE_AGENT_DISPLAY ?? ':101'
const env = { ...process.env, DISPLAY }
const PROTOCOL = '2025-06-18'

const tools = [
  {
    name: 'screenshot',
    description: 'Capture the agent display as a PNG. Coordinates in other tools use this image\'s pixels.',
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
  {
    name: 'approve',
    description: 'Permission prompt for Claude Code (--permission-prompt-tool): asks the computer\'s owner whether a tool may run, and waits for the answer.',
    inputSchema: { type: 'object', properties: { tool_name: { type: 'string' }, input: { type: 'object' }, tool_use_id: { type: 'string' } }, required: ['tool_name', 'input'] },
  },
]

// The task directory caboose-host launched the agent in; Claude starts its MCP servers in
// its own working directory, so that is the fallback when the variable does not reach us.
const APPROVALS = join(process.env.CABOOSE_TASK_DIR || process.cwd(), 'approvals')
const DECISION_POLL_MS = Number(process.env.CABOOSE_APPROVAL_POLL_MS) || 500

/** A copy of a tool input small enough to show the owner: long strings are cut. */
function preview(value, depth = 0) {
  if (typeof value === 'string') return value.length > 2000 ? `${value.slice(0, 2000)}…` : value
  if (Array.isArray(value)) return depth > 4 ? '[…]' : value.slice(0, 50).map(item => preview(item, depth + 1))
  if (value && typeof value === 'object') {
    if (depth > 4) return '{…}'
    return Object.fromEntries(Object.entries(value).slice(0, 50).map(([key, item]) => [key, preview(item, depth + 1)]))
  }
  return value
}

function int(value, name) {
  if (!Number.isInteger(value) || value < -100000 || value > 100000) throw new Error(`${name} must be an integer`)
  return String(value)
}

async function xdotool(...args) {
  await run('xdotool', args, { env, timeout: 15_000 })
}

const handlers = {
  // Writes approvals/<id>.json { tool, input } and waits for approvals/<id>.decision
  // { allow, message? } from caboose-host, then answers in Claude Code's permission-prompt
  // format. Both files are written whole and renamed into place, so neither side reads half.
  async approve({ tool_name: tool, input }) {
    if (typeof tool !== 'string' || !tool) throw new Error('tool_name must be a string')
    const id = randomUUID()
    await mkdir(APPROVALS, { recursive: true })
    const request = join(APPROVALS, `${id}.json`)
    await writeFile(`${request}.tmp`, JSON.stringify({ tool, input: preview(input ?? {}), requestedAt: new Date().toISOString() }))
    await rename(`${request}.tmp`, request)
    for (;;) {
      const text = await readFile(join(APPROVALS, `${id}.decision`), 'utf8').catch(() => undefined)
      if (text !== undefined) {
        let decision
        try { decision = JSON.parse(text) } catch { decision = { allow: false, message: 'The answer could not be read.' } }
        const answer = decision?.allow === true
          ? { behavior: 'allow', updatedInput: input ?? {} }
          : { behavior: 'deny', message: typeof decision?.message === 'string' && decision.message ? decision.message : 'The owner declined this action.' }
        return [{ type: 'text', text: JSON.stringify(answer) }]
      }
      await sleep(DECISION_POLL_MS)
    }
  },
  async screenshot({ window }) {
    const target = window ? String(window) : 'root'
    if (window && !/^(0x[0-9a-f]+|\d+)$/i.test(target)) throw new Error('window must be an id from list_windows')
    const { stdout } = await run('import', ['-window', target, 'png:-'], { env, encoding: 'buffer', maxBuffer: 64 * 1024 * 1024, timeout: 20_000 })
    return [{ type: 'image', data: Buffer.from(stdout).toString('base64'), mimeType: 'image/png' }]
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
    const child = spawn('/bin/sh', ['-c', command], { env, detached: true, stdio: 'ignore' })
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
