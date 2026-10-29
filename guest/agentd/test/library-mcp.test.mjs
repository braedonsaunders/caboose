// The MCP Library proxy against a stand-in for Smithery Connect: no network.
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { createProxy, descriptor, messages } from '../library-mcp.mjs'

const dirs = []
afterEach(async () => { for (const dir of dirs.splice(0)) await rm(dir, { recursive: true, force: true }) })
async function file(value) {
  const dir = await mkdtemp(join(tmpdir(), 'caboose-library-')); dirs.push(dir)
  const path = join(dir, 'mcp-library.json')
  await writeFile(path, typeof value === 'string' ? value : JSON.stringify(value))
  return path
}
const TOKEN = 'svc-scoped-token-123'
const ACCOUNT = '11111111-2222-4333-8444-555555555555'
const LATER = '2999-01-01T00:00:00Z'

describe('the Library descriptor', () => {
  it('is used only for Smithery Connect over https, with a token that has not run out', async () => {
    const good = { url: 'https://mcp.smithery.run/space', token: TOKEN, account: ACCOUNT, expiresAt: LATER }
    expect(await descriptor(await file(good))).toEqual({ url: 'https://mcp.smithery.run/space', token: TOKEN, identity: `${ACCOUNT} https://mcp.smithery.run/space` })
    for (const bad of [{ url: 'https://evil.example/space' }, { url: 'http://mcp.smithery.run/space' }, { token: 'x' }, { expiresAt: '2000-01-01T00:00:00Z' }, { expiresAt: undefined }, { expiresAt: 'soon' }, { account: undefined }]) {
      expect(await descriptor(await file({ ...good, ...bad }))).toBeNull()
    }
    expect(await descriptor(await file('not json'))).toBeNull()
    expect(await descriptor('/nonexistent/mcp-library.json')).toBeNull()
  })
  it('reads messages from JSON and from an event stream', () => {
    expect(messages('application/json', '{"jsonrpc":"2.0","id":1,"result":{}}')).toEqual([{ jsonrpc: '2.0', id: 1, result: {} }])
    expect(messages('text/event-stream', 'event: message\ndata: {"id":1}\n\ndata: {"id":2}\n\n')).toEqual([{ id: 1 }, { id: 2 }])
    expect(messages('application/json', '')).toEqual([])
  })
})

describe('the Library proxy', () => {
  function stand(responses) {
    const sent = [], written = []
    const fetcher = async (url, init) => {
      sent.push({ url, headers: init.headers, body: JSON.parse(init.body), redirect: init.redirect })
      const next = responses.shift()
      return new Response(next.body ?? null, { status: next.status ?? 200, headers: next.headers ?? { 'content-type': 'application/json' } })
    }
    let target = { url: 'https://mcp.smithery.run/space', token: TOKEN, identity: 'a' }
    const forward = createProxy({ read: async () => target, fetcher, write: line => written.push(JSON.parse(line)), timeoutMs: 2000 })
    return { forward, sent, written, switchAccount: () => { target = { ...target, identity: 'b' } } }
  }
  it('forwards each message with the token and the session the endpoint gave it', async () => {
    const s = stand([
      { body: '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}', headers: { 'content-type': 'application/json', 'mcp-session-id': 'session-1' } },
      { status: 202 },
      { body: 'data: {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"brave.search"}]}}\n\n', headers: { 'content-type': 'text/event-stream' } },
    ])
    await s.forward({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })
    await s.forward({ jsonrpc: '2.0', method: 'notifications/initialized' })
    await s.forward({ jsonrpc: '2.0', id: 2, method: 'tools/list' })
    expect(s.sent.map(call => call.headers.authorization)).toEqual(Array(3).fill(`Bearer ${TOKEN}`))
    expect(s.sent.every(call => call.redirect === 'error')).toBe(true)
    expect(s.sent[2].headers['mcp-session-id']).toBe('session-1')
    expect(s.sent[2].headers['mcp-protocol-version']).toBe('2025-06-18')
    expect(s.written).toEqual([{ jsonrpc: '2.0', id: 1, result: { protocolVersion: '2025-06-18' } }, { jsonrpc: '2.0', id: 2, result: { tools: [{ name: 'brave.search' }] } }])
  })
  it('passes on an open event stream\'s answer without waiting for the stream to end', async () => {
    const written = []
    let cancelled = false
    const fetcher = async () => new Response(new ReadableStream({
      start(controller) { controller.enqueue(new TextEncoder().encode('data: {"jsonrpc":"2.0","method":"notifications/progress"}\n\ndata: {"jsonrpc":"2.0","id":3,"result":{"ok":true}}\n\n')) },
      cancel() { cancelled = true },
    }), { headers: { 'content-type': 'text/event-stream' } })
    const forward = createProxy({ read: async () => ({ url: 'https://mcp.smithery.run/space', token: TOKEN, identity: 'a' }), fetcher, write: line => written.push(JSON.parse(line)), timeoutMs: 2000 })
    await forward({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: {} })
    expect(written).toEqual([{ jsonrpc: '2.0', method: 'notifications/progress' }, { jsonrpc: '2.0', id: 3, result: { ok: true } }])
    expect(cancelled).toBe(true)
  })
  it('turns a failing stream into an error answer instead of failing the process', async () => {
    const written = []
    const fetcher = async () => new Response(new ReadableStream({ pull() { throw new Error(`stream broke ${TOKEN}`) } }), { headers: { 'content-type': 'text/event-stream' } })
    const forward = createProxy({ read: async () => ({ url: 'https://mcp.smithery.run/space', token: TOKEN, identity: 'a' }), fetcher, write: line => written.push(line), timeoutMs: 2000 })
    await forward({ jsonrpc: '2.0', id: 4, method: 'tools/list' })
    expect(written.map(line => JSON.parse(line).error.message)).toEqual(['The MCP Library could not be reached.'])
    expect(written.join()).not.toContain(TOKEN)
  })
  it('starts a new session when the account behind the Library changes', async () => {
    const s = stand([
      { body: '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}', headers: { 'content-type': 'application/json', 'mcp-session-id': 'old-session' } },
      { body: '{"jsonrpc":"2.0","id":2,"result":{}}' },
    ])
    await s.forward({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })
    s.switchAccount()
    await s.forward({ jsonrpc: '2.0', id: 2, method: 'tools/list' })
    expect(s.sent[1].headers['mcp-session-id']).toBeUndefined()
    expect(s.sent[1].headers['mcp-protocol-version']).toBeUndefined()
  })
  it('answers with an error, never the token, when the Library is unavailable or refuses', async () => {
    const written = []
    const missing = createProxy({ read: async () => null, fetcher: async () => { throw new Error('must not be called') }, write: line => written.push(line) })
    await missing({ jsonrpc: '2.0', id: 7, method: 'tools/list' })
    const refused = stand([{ status: 401, body: `{"error":"bad token ${TOKEN}"}` }])
    await refused.forward({ jsonrpc: '2.0', id: 8, method: 'tools/call', params: {} })
    const all = [...written, ...refused.written.map(value => JSON.stringify(value))]
    expect(all.map(line => JSON.parse(line).error.message)).toEqual([
      "This computer's MCP Library is not available. Check it in Caboose's Agents tab.",
      "The MCP Library's access has expired. Caboose renews it within the hour.",
    ])
    expect(all.join('\n')).not.toContain(TOKEN)
  })
})
