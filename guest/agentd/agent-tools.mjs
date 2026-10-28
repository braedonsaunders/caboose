#!/usr/bin/env node
// MCP stdio endpoint. The host is the authority for task and profile scope.
import { randomUUID } from 'node:crypto'
import { mkdir, open, readFile, rename, unlink } from 'node:fs/promises'
import { join } from 'node:path'
import { constants } from 'node:fs'
import { setTimeout as delay } from 'node:timers/promises'

const dir = process.argv[2]
if (!dir) throw new Error('Task directory required')
const box = join(dir, 'tool-mailbox')
const weekdays = { type: 'array', description: 'ISO weekdays: Monday = 1 through Sunday = 7.', items: { type: 'integer', minimum: 1, maximum: 7 }, minItems: 1, uniqueItems: true }
const time = { type: 'string', pattern: '^([01][0-9]|2[0-3]):[0-5][0-9]$' }
const active = { type: 'object', description: 'Optional filters do not shift cadence or interval anchor. A window opens at its inclusive start and closes at its exclusive end; if end is earlier it crosses midnight and belongs to the opening weekday.', additionalProperties: false, properties: { weekdays, window: { type: 'object', additionalProperties: false, properties: { start: time, end: time }, required: ['start', 'end'] } } }
const base = { timeZone: { type: 'string', description: 'Named IANA timezone, e.g. America/Toronto; obtain from owner or current context, never guess.' }, active }
const schedule = { description: 'Calendar times are local HH:mm in timeZone. Instant strings require Z or an offset. For an interval provide its explicit anchor. Calendar DST gaps are skipped; folds use the earlier instant.', oneOf: [
  ['interval', { everyMs: { type: 'integer', minimum: 60000, maximum: 9007199254740991 }, anchor: { type: 'string', format: 'date-time' } }, ['everyMs', 'anchor']],
  ['once', { at: { type: 'string', format: 'date-time' } }, ['at']],
  ['daily', { time }, ['time']],
  ['weekly', { time, weekdays }, ['time', 'weekdays']],
  ['monthly', { time, dayOfMonth: { oneOf: [{ type: 'integer', minimum: 1, maximum: 31 }, { const: 'last' }] } }, ['time', 'dayOfMonth']],
].map(([kind, properties, required]) => ({ type: 'object', additionalProperties: false, properties: { kind: { const: kind }, ...base, ...properties }, required: ['kind', 'timeZone', ...required] })) }
const id = { type: 'string', description: 'ID returned by a list or create tool' }
const editable = { name: { type: 'string', minLength: 1, maxLength: 80 }, prompt: { type: 'string', minLength: 1, maxLength: 16000 }, schedule, paused: { type: 'boolean' }, missed: { enum: ['skip', 'coalesce'] }, overlap: { enum: ['skip'] }, deliveryGraceMs: { type: 'integer', minimum: 0, maximum: 300000 } }
const object = (properties = {}, required = []) => ({ type: 'object', additionalProperties: false, properties, required })
const definitions = [
 ['profile_read', 'Read your own persistent profile.', object()],
 ['memory_list', 'List your saved memories.', object({ offset: { type: 'integer', minimum: 0 }, limit: { type: 'integer', minimum: 1, maximum: 20 } })],
 ['memory_remember', 'Save a memory for future conversations.', object({ title: { type: 'string' }, content: { type: 'string' } }, ['title', 'content'])],
 ['memory_update', 'Update your saved memory.', object({ id, title: { type: 'string' }, content: { type: 'string' } }, ['id'])],
 ['memory_forget', 'Delete your saved memory.', object({ id }, ['id'])],
 ['routine_list', 'List your routines.', object()],
 ['routine_get', 'Read a routine definition.', object({ id }, ['id'])],
 ['routine_create', 'Create a durable routine for this agent. Translate the owner’s request into the schedule JSON; ask for a timezone if unknown. Never infer an unspecified timezone.', object(editable, ['name', 'prompt', 'schedule'])],
 ['routine_update', 'Change a routine; unspecified fields remain unchanged.', object({ id, patch: object(editable) }, ['id', 'patch'])],
 ['routine_pause', 'Pause or resume a routine.', object({ id, paused: { type: 'boolean' } }, ['id', 'paused'])],
 ['routine_delete', 'Delete a routine.', object({ id }, ['id'])],
 ['routine_run', 'Request a routine run now.', object({ id }, ['id'])],
 ['routine_history', 'Read routine execution history.', object({ id, limit: { type: 'integer', minimum: 1, maximum: 20 } })],
].map(([name, description, inputSchema]) => ({ name, description, inputSchema }))
const known = new Set(definitions.map(x => x.name))
const controller = new AbortController()
const pending = new Set()
const timeout = Math.max(100, Math.min(120000, Number(process.env.CABOOSE_TOOL_TIMEOUT_MS) || 30000))
async function syncDir(path) { const h = await open(path, 'r'); try { await h.sync() } finally { await h.close() } }
async function atomic(path, data) {
 const temp = `${path}.${randomUUID()}.tmp`, f = await open(temp, 'wx', 0o600)
 try { await f.writeFile(data); await f.sync() } finally { await f.close() }
 try { await rename(temp, path); await syncDir(box) } finally { await unlink(temp).catch(() => {}) }
}
async function call(name, args) {
 if (!known.has(name) || !args || typeof args !== 'object' || Array.isArray(args)) throw new Error('Invalid tool or arguments')
 if (pending.size >= 8) throw new Error('Too many pending tool calls')
 const turn = Number(await readFile(join(dir, 'tool-turn'), 'utf8'))
 if (!Number.isSafeInteger(turn) || turn < 1 || turn > 999999) throw new Error('No active agent turn')
 const id = randomUUID(), request = join(box, `${id}.request`), response = join(box, `${id}.response`)
 const body = JSON.stringify({ id, turn, tool: name, arguments: args })
 if (Buffer.byteLength(body) > 65536) throw new Error('Tool request too large')
 pending.add(id)
 try {
  await mkdir(box, { recursive: true, mode: 0o700 })
  await atomic(request, body)
  const deadline = Date.now() + timeout
  while (!controller.signal.aborted && Date.now() < deadline) {
   try {
    const f = await open(response, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK)
    let data
    try { const s = await f.stat(); if (!s.isFile() || s.size > 140000) throw new Error('Invalid host response'); data = await f.readFile('utf8') } finally { await f.close() }
    const result = JSON.parse(data)
    if (result?.id !== id || typeof result.ok !== 'boolean') throw new Error('Invalid host response')
    return result
   } catch (error) { if (error.code !== 'ENOENT') throw error }
   await delay(100, undefined, { signal: controller.signal }).catch(() => {})
  }
  throw new Error('Timed out or disconnected waiting for the host. The operation may have completed; inspect current state before retrying.')
 } finally { pending.delete(id); await unlink(request).catch(() => {}); await unlink(response).catch(() => {}) }
}
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n')
function handleLine(line) {
 if (Buffer.byteLength(line) > 100000) return
 let msg; try { msg = JSON.parse(line) } catch { return }
 if (msg.id === undefined) return
 if (msg.method === 'initialize') return reply(msg.id, { protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'caboose-agent-tools', version: '1.0.0' } })
 if (msg.method === 'tools/list') return reply(msg.id, { tools: definitions })
 if (msg.method === 'tools/call') {
  void call(msg.params?.name, msg.params?.arguments ?? {}).then(result => reply(msg.id, { content: [{ type: 'text', text: JSON.stringify(result.ok ? result.value : { error: result.error }) }], ...(result.ok ? {} : { isError: true }) }), error => reply(msg.id, { content: [{ type: 'text', text: String(error.message).slice(0, 2000) }], isError: true }))
  return
 }
 process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'Method not found' } }) + '\n')
}
let buffer = '', discarding = false
process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
 for (const part of chunk.split(/(?<=\n)/)) {
  const ended = part.endsWith('\n')
  if (!discarding) {
   buffer += part
   if (Buffer.byteLength(buffer) > 100000) { buffer = ''; discarding = true }
  }
  if (ended) { if (!discarding) handleLine(buffer.trimEnd()); buffer = ''; discarding = false }
 }
})
process.stdin.on('end', () => controller.abort())
process.stdin.on('close', () => controller.abort())
