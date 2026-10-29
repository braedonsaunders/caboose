#!/usr/bin/env node
// The computer's MCP Library for an agent (docs/architecture.md § MCP Library): an MCP server
// on stdio that forwards each message to Smithery Connect's endpoint for the computer's
// servers, over Streamable HTTP. Where and with which token come from a private file the host
// keeps current, read for every message, so a replaced token or a removed Library takes
// effect at once. Nothing it reads or receives is logged.
import { readFile } from 'node:fs/promises'
import { createInterface } from 'node:readline'

export const DESCRIPTOR = process.env.CABOOSE_MCP_LIBRARY ?? '/home/caboose/.local/state/caboose/mcp-library.json'
const MAX_BODY = 8 * 1024 * 1024
const TIMEOUT_MS = 120_000

/** The endpoint and token, or null when the Library is gone or its token has run out. */
export async function descriptor(path = DESCRIPTOR, now = Date.now()) {
  let value
  try { value = JSON.parse(await readFile(path, 'utf8')) } catch { return null }
  if (!value || typeof value.url !== 'string' || typeof value.token !== 'string' || !/^[\x21-\x7e]{8,4000}$/.test(value.token)) return null
  let url
  try { url = new URL(value.url) } catch { return null }
  if (url.protocol !== 'https:' || !(url.hostname === 'smithery.run' || url.hostname.endsWith('.smithery.run'))) return null
  if (typeof value.expiresAt === 'string' && Date.parse(value.expiresAt) <= now) return null
  return { url: url.href, token: value.token }
}

/** JSON-RPC messages in a Streamable HTTP answer: one JSON value, or an SSE stream's events. */
export function messages(contentType, text) {
  const found = []
  if (String(contentType).includes('text/event-stream')) {
    for (const event of text.split(/\r?\n\r?\n/)) {
      const data = event.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n')
      if (data) try { found.push(JSON.parse(data)) } catch { /* not a message */ }
    }
  } else if (text.trim()) {
    try { const value = JSON.parse(text); found.push(...(Array.isArray(value) ? value : [value])) } catch { /* not JSON */ }
  }
  return found.filter(message => message && typeof message === 'object')
}

export function createProxy({ read = descriptor, fetcher = fetch, write = line => process.stdout.write(line + '\n') } = {}) {
  let session = null
  let protocol = null
  const fail = (id, text) => { if (id !== undefined && id !== null) write(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32000, message: text } })) }
  return async function forward(message) {
    const id = message.id
    const target = await read()
    if (!target) return fail(id, "This computer's MCP Library is not available. Check it in Caboose's Agents tab.")
    let response
    try {
      response = await fetcher(target.url, {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(TIMEOUT_MS), body: JSON.stringify(message),
        headers: { authorization: `Bearer ${target.token}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream',
          ...(session ? { 'mcp-session-id': session } : {}), ...(protocol ? { 'mcp-protocol-version': protocol } : {}) },
      })
    } catch { return fail(id, 'The MCP Library could not be reached.') }
    if (response.status === 404 && session) { session = null; protocol = null; return fail(id, 'The MCP Library session ended; ask again.') }
    if (response.status === 401 || response.status === 403) return fail(id, "The MCP Library's access has expired. Caboose renews it within the hour.")
    if (response.status === 202 || response.status === 204) return
    if (!response.ok) return fail(id, `The MCP Library answered ${response.status}.`)
    const sessionHeader = response.headers.get('mcp-session-id')
    if (sessionHeader && /^[\x21-\x7e]{1,200}$/.test(sessionHeader)) session = sessionHeader
    const reader = response.body?.getReader()
    const chunks = []
    let size = 0
    if (reader) for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.length
      if (size > MAX_BODY) { await reader.cancel(); return fail(id, 'The MCP Library sent too much at once.') }
      chunks.push(value)
    }
    const replies = messages(response.headers.get('content-type'), Buffer.concat(chunks).toString('utf8'))
    for (const reply of replies) {
      if (message.method === 'initialize' && reply.id === id && typeof reply.result?.protocolVersion === 'string') protocol = reply.result.protocolVersion.slice(0, 40)
      write(JSON.stringify(reply))
    }
    if (id !== undefined && id !== null && !replies.some(reply => reply.id === id)) fail(id, 'The MCP Library did not answer.')
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const forward = createProxy()
  const lines = createInterface({ input: process.stdin })
  lines.on('line', line => {
    if (line.length > MAX_BODY) return
    let message
    try { message = JSON.parse(line) } catch { return }
    if (message && typeof message === 'object') void forward(message)
  })
  lines.on('close', () => process.exit(0))
}
