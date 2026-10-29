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

describe('the Library descriptor', () => {
  it('is used only for Smithery Connect over https, with a token that has not run out', async () => {
    expect(await descriptor(await file({ url: 'https://mcp.smithery.run/space', token: TOKEN, expiresAt: '2999-01-01T00:00:00Z' }))).toEqual({ url: 'https://mcp.smithery.run/space', token: TOKEN })
    for (const bad of [{ url: 'https://evil.example/space', token: TOKEN }, { url: 'http://mcp.smithery.run/space', token: TOKEN }, { url: 'https://mcp.smithery.run/space', token: 'x' },
      { url: 'https://mcp.smithery.run/space', token: TOKEN, expiresAt: '2000-01-01T00:00:00Z' }]) expect(await descriptor(await file(bad))).toBeNull()
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
    const forward = createProxy({ read: async () => ({ url: 'https://mcp.smithery.run/space', token: TOKEN }), fetcher, write: line => written.push(JSON.parse(line)) })
    return { forward, sent, written }
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
