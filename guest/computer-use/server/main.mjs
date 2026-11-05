#!/usr/bin/node
// caboose-computer-use: the MCP server that lets an agent see and drive GUI applications on the
// agent seat, its own Caboose Display, so it never touches the owner's display. MCP over stdio
// (newline-delimited JSON-RPC 2.0), with no dependencies beyond node:. Its client starts it for
// one agent session; caboose-agentd gives it to every ACP agent as `caboose-desktop`.
//
// CABOOSE_AGENT_DISPLAY names the seat's X display (default :101). CABOOSE_DESKTOP_TRACE names a
// file that gets one JSON line per tool call (tool, milliseconds, reply size, act step timing).
import { appendFileSync } from 'node:fs'
import { createInterface } from 'node:readline'
import { INSTRUCTIONS, TOOLS, handlers, lastTiming } from './tools.mjs'
import { close } from './seat.mjs'

const PROTOCOL = '2025-06-18'
const VERSION = '1.0.0'
const TRACE = process.env.CABOOSE_DESKTOP_TRACE

const write = message => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n')
const reply = (id, result) => write({ id, result })
const fail = (id, code, message) => write({ id, error: { code, message } })

async function call(id, name, args) {
  const handler = handlers[name]
  if (!handler) return fail(id, -32602, `unknown tool ${name}`)
  const started = performance.now()
  try {
    const content = await handler(args ?? {})
    reply(id, { content })
    if (TRACE) appendFileSync(TRACE, JSON.stringify({ tool: name, ms: Math.round(performance.now() - started), ...(name === 'act' ? { steps: lastTiming } : {}),
      chars: content.reduce((n, part) => n + (part.text?.length ?? 0), 0), images: content.filter(part => part.type === 'image').length }) + '\n')
  } catch (error) {
    reply(id, { content: [{ type: 'text', text: String(error?.stderr || error?.message || error).trim() }], isError: true })
  }
}

async function handle({ id, method, params }) {
  if (method === 'initialize') {
    return reply(id, { protocolVersion: params?.protocolVersion ?? PROTOCOL, capabilities: { tools: {} },
      serverInfo: { name: 'caboose-desktop', version: VERSION }, instructions: INSTRUCTIONS })
  }
  if (id === undefined) return // notifications
  if (method === 'ping') return reply(id, {})
  if (method === 'tools/list') return reply(id, { tools: TOOLS })
  if (method === 'tools/call') return call(id, params?.name, params?.arguments)
  fail(id, -32601, `method not found: ${method}`)
}

// One request at a time, in order: every tool drives the same seat.
let queue = Promise.resolve()
const lines = createInterface({ input: process.stdin })
lines.on('line', line => {
  if (!line.trim()) return
  let message
  try { message = JSON.parse(line) } catch { return fail(null, -32700, 'parse error') }
  queue = queue.then(() => handle(message))
})
lines.on('close', () => { void queue.finally(close) })
process.on('SIGTERM', () => { close(); process.exit(0) })
process.on('SIGINT', () => { close(); process.exit(0) })
process.on('exit', close)
