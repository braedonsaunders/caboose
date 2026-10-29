#!/usr/bin/env node
// caboose-apps — an MCP server (stdio, newline-delimited JSON-RPC 2.0) that lets an agent
// make Caboose apps: web apps in ~/Apps/<id>/ that run as their own windows and appear in
// the owner's Apps screen. The agent writes the files with its own file tools; these tools
// teach the format, publish, list, open and remove apps through caboose-app beside this
// file. caboose-agentd passes it to every ACP agent with the agent seat's environment, so
// app_open shows the app on the agent's own display. No dependencies beyond node:.
import { execFile, spawn } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { ensureAgentSeat } from '../desktop-mcp/ensure-agent-seat.mjs'

const run = promisify(execFile)
const PROTOCOL = '2025-06-18'
const RUNTIME = process.env.CABOOSE_APP_RUNTIME ?? fileURLToPath(new URL('./caboose-app', import.meta.url))
const GUIDE = fileURLToPath(new URL('./guide.md', import.meta.url))
const ID = /^[a-z][a-z0-9-]{0,47}$/
const DISPLAY = process.env.CABOOSE_AGENT_DISPLAY
// The seat's display for apps the agent opens, with accessibility on so elements and
// read_text can see into the page.
const seatEnv = { ...process.env, ...(DISPLAY ? { DISPLAY } : {}), ACCESSIBILITY_ENABLED: '1' }
delete seatEnv.NO_AT_BRIDGE
if (seatEnv.GTK_A11Y === 'none') delete seatEnv.GTK_A11Y

const id = { type: 'string', pattern: ID.source, description: 'The app id: its directory name under ~/Apps' }
const tools = [
  {
    name: 'app_guide',
    description: 'Read this before making an app. Caboose apps are web apps (HTML, CSS, JavaScript) in ~/Apps/<id>/ '
      + 'that run as real applications with their own window and icon in the owner\'s Apps screen, opened from '
      + 'their phone. They can run programs, use files, notify and open links through window.caboose. Returns the '
      + 'app.json format, the window.caboose API and the design rules.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'app_publish',
    description: 'Check ~/Apps/<id>/ and list it in the owner\'s Apps screen. Returns every problem to fix if it is '
      + 'not valid. Publishing again after edits is safe; an open window reloads by itself when files change.',
    inputSchema: { type: 'object', properties: { id }, required: ['id'] },
  },
  {
    name: 'app_list',
    description: 'List the apps in ~/Apps with their name, capabilities, whether they are published and any problems.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'app_open',
    description: 'Open an app on your own display to try it, then use screenshot, elements and click_element to see '
      + 'and use it. It needs no publishing first, only a valid app.json.',
    inputSchema: { type: 'object', properties: { id }, required: ['id'] },
  },
  {
    name: 'app_remove',
    description: 'Take an app off the Apps screen. With purge, also delete its files in ~/Apps and its saved data. '
      + 'Only remove an app the owner asked you to.',
    inputSchema: { type: 'object', properties: { id, purge: { type: 'boolean', default: false } }, required: ['id'] },
  },
]

function appId(value) {
  if (typeof value !== 'string' || !ID.test(value)) throw new Error('id must be a lowercase letter followed by up to 47 lowercase letters, digits or hyphens')
  return value
}

/** Runs caboose-app; it prints one JSON object and exits non-zero when the app is invalid. */
async function runtime(...args) {
  try {
    const { stdout } = await run(RUNTIME, args, { timeout: 60_000, maxBuffer: 4 * 1024 * 1024 })
    return JSON.parse(stdout)
  } catch (error) {
    let answer
    try { answer = JSON.parse(error.stdout) } catch { throw new Error(String(error.stderr || error.message).trim()) }
    return answer
  }
}

const json = value => [{ type: 'text', text: JSON.stringify(value, null, 2) }]

const handlers = {
  app_guide: async () => [{ type: 'text', text: await readFile(GUIDE, 'utf8') }],
  async app_publish({ id: value }) {
    const result = await runtime('publish', appId(value))
    if (!result.ok) throw new Error(`${value} is not published:\n- ${(result.errors ?? []).join('\n- ')}`)
    return json({ published: true, id: value, name: result.manifest.name, capabilities: result.manifest.capabilities })
  },
  app_list: async () => json((await runtime('list')).apps),
  async app_open({ id: value }) {
    const result = await runtime('check', appId(value))
    if (!result.ok) throw new Error(`${value} cannot open:\n- ${(result.errors ?? []).join('\n- ')}`)
    Object.assign(seatEnv, await ensureAgentSeat(), { DISPLAY: DISPLAY ?? ':101' })
    const child = spawn(RUNTIME, ['run', value], { env: seatEnv, detached: true, stdio: 'ignore' })
    child.unref()
    return [{ type: 'text', text: `Opened ${result.manifest.name} on your display. Use list_windows or screenshot to see it. `
      + `Its console messages and script errors are in ~/.local/share/caboose/apps/${value}/console.log.` }]
  },
  async app_remove({ id: value, purge = false }) {
    if (typeof purge !== 'boolean') throw new Error('purge must be true or false')
    return json(await runtime('remove', appId(value), ...(purge ? ['--purge'] : [])))
  },
}

function reply(id, result) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n') }
function fail(id, code, message) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }) + '\n') }

async function handle(message) {
  const { id, method, params } = message
  if (method === 'initialize') {
    return reply(id, { protocolVersion: params?.protocolVersion ?? PROTOCOL, capabilities: { tools: {} },
      serverInfo: { name: 'caboose-apps', version: '1.0.0' } })
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
      reply(id, { content: [{ type: 'text', text: String(error?.message ?? error).trim() }], isError: true })
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
