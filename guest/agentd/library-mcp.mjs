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
  const expires = typeof value.expiresAt === 'string' ? Date.parse(value.expiresAt) : NaN
  if (!Number.isFinite(expires) || expires <= now) return null
  if (typeof value.account !== 'string' || !/^[0-9a-f-]{36}$/.test(value.account)) return null
  return { url: url.href, token: value.token, identity: `${value.account} ${url.href}` }
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

/** Messages in an event stream so far, and what is left of a partial event. */
export function events(buffer) {
  const parts = buffer.split(/\r?\n\r?\n/)
  const rest = parts.pop()
  return { found: messages('text/event-stream', parts.join('\n\n') + (parts.length ? '\n\n' : '')), rest }
}

export function createProxy({ read = descriptor, fetcher = fetch, write = line => process.stdout.write(line + '\n'), timeoutMs = TIMEOUT_MS } = {}) {
  // The session belongs to one account's endpoint. A request answered after the account
  // changed is never let back in: neither its session nor its reply.
  let state = null
  const fail = (id, text) => { if (id !== undefined && id !== null) write(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32000, message: text } })) }
  async function exchange(message, target) {
    const id = message.id
    if (!state || state.identity !== target.identity) state = { identity: target.identity, session: null, protocol: null }
    const current = state
    const changed = () => state !== current
    const response = await fetcher(target.url, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(timeoutMs), body: JSON.stringify(message),
      headers: { authorization: `Bearer ${target.token}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream',
        ...(current.session ? { 'mcp-session-id': current.session } : {}), ...(current.protocol ? { 'mcp-protocol-version': current.protocol } : {}) },
    })
    if (changed()) { await response.body?.cancel().catch(() => {}); return fail(id, 'The MCP Library changed while answering; ask again.') }
    if (response.status === 404 && current.session) { current.session = null; current.protocol = null; return fail(id, 'The MCP Library session ended; ask again.') }
    if (response.status === 401 || response.status === 403) return fail(id, "The MCP Library's access has expired. Caboose renews it within the hour.")
    if (response.status === 202 || response.status === 204) return
    if (!response.ok) return fail(id, `The MCP Library answered ${response.status}.`)
    const sessionHeader = response.headers.get('mcp-session-id')
    if (sessionHeader && /^[\x21-\x7e]{1,200}$/.test(sessionHeader)) current.session = sessionHeader
    const stream = String(response.headers.get('content-type') ?? '').includes('text/event-stream')
    let answered = false
    const deliver = reply => {
      if (changed()) throw new Error('changed')
      if (message.method === 'initialize' && reply.id === id && typeof reply.result?.protocolVersion === 'string') current.protocol = reply.result.protocolVersion.slice(0, 40)
      if (reply.id === id && ('result' in reply || 'error' in reply)) answered = true
      write(JSON.stringify(reply))
    }
    const reader = response.body?.getReader()
    const decoder = new TextDecoder()
    let buffer = '', size = 0
    if (reader) {
      try {
        // An event stream may stay open: each event is passed on as it arrives, and the stream
        // is let go once the request's answer has come.
        while (!(stream && answered)) {
          const { done, value } = await reader.read()
          if (done) break
          size += value.length
          if (size > MAX_BODY) throw new Error('too large')
          buffer += decoder.decode(value, { stream: true })
          if (stream) { const { found, rest } = events(buffer); buffer = rest; found.forEach(deliver) }
        }
      } finally { await reader.cancel().catch(() => {}) }
    }
    if (changed()) return fail(id, 'The MCP Library changed while answering; ask again.')
    if (stream) events(buffer + '\n\n').found.forEach(deliver)
    else messages(response.headers.get('content-type'), buffer).forEach(deliver)
    if (id !== undefined && id !== null && !answered) fail(id, 'The MCP Library did not answer.')
  }
  return async function forward(message) {
    try {
      const target = await read()
      if (!target) return fail(message.id, "This computer's MCP Library is not available. Check it in Caboose's Agents tab.")
      await exchange(message, target)
    } catch {
      // Nothing from the failure itself is passed on: it could name the endpoint or worse.
      fail(message.id, 'The MCP Library could not be reached.')
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const forward = createProxy()
  const lines = createInterface({ input: process.stdin })
  lines.on('line', line => {
    if (line.length > MAX_BODY) return
    let message
    try { message = JSON.parse(line) } catch { return }
    if (message && typeof message === 'object') forward(message).catch(() => {})
  })
  lines.on('close', () => process.exit(0))
}
