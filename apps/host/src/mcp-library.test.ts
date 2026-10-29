import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { connectionId, MAX_CONNECTIONS, McpLibrary, readStatus, rpcResult } from './mcp-library.js'
import { SmitheryCatalog, type Requester } from './smithery.js'
import { listing } from './smithery.test.js'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })
const root = () => { const dir = mkdtempSync(join(tmpdir(), 'caboose-mcp-')); roots.push(dir); return dir }
const KEY = 'sk-owner-secret-key'
const answer = (body: unknown, status = 200, type = 'application/json') => ({ status, headers: { 'content-type': type }, body: Buffer.from(JSON.stringify(body)) })

/** Smithery as far as the Library uses it: namespaces, connections, tokens and the per-connection MCP endpoint. */
function smithery(options: { needsKey?: boolean; oauth?: boolean } = {}) {
  const connections = new Map<string, { server: string; metadata: Record<string, unknown>; headers: Record<string, string>; mcpUrl: string }>()
  const calls: Array<{ method: string; path: string; auth: string; body: any }> = []
  let tokens = 0
  const request = vi.fn(async (url: string, _max: number, init: { method?: string; headers?: Record<string, string>; body?: string } = {}) => {
    const parsed = new URL(url)
    const method = init.method ?? 'GET', auth = init.headers?.authorization ?? '', body = init.body ? JSON.parse(init.body) : undefined
    calls.push({ method, path: parsed.pathname, auth, body })
    if (parsed.hostname === 'registry.smithery.ai') return answer({ ...listing(parsed.pathname.split('/').slice(2).join('/'), 10), tools: [{ name: 'search', description: 'Search' }] })
    const connect = /^\/connect\/([^/]+)\/([^/]+)(\/mcp)?$/.exec(parsed.pathname)
    if (parsed.pathname === '/namespaces') return auth === `Bearer ${KEY}` ? answer({ namespaces: [{ name: 'owner-space' }], pagination: {} }) : answer({ error: 'unauthorized' }, 401)
    if (parsed.pathname === '/tokens') return answer({ token: `svc-token-${++tokens}`, expiresAt: new Date(Date.now() + 86400_000).toISOString() })
    if (connect && connect[3]) {
      if (!auth.startsWith('Bearer svc-')) return answer({}, 401)
      return body.method === 'initialize' ? answer({ jsonrpc: '2.0', id: body.id, result: { protocolVersion: '2025-06-18' } })
        : answer({ jsonrpc: '2.0', id: body.id, result: { tools: [{ name: 'search' }, { name: 'news' }] } })
    }
    if (connect) {
      const [, , id] = connect
      const existing = connections.get(id!)
      const status = () => {
        const c = connections.get(id!)!
        if (options.oauth) return { state: 'auth_required', setupUrl: 'https://auth.smithery.ai/setup/abc' }
        if (options.needsKey && !c.headers.apiKey) return { state: 'input_required', setupUrl: 'https://smithery.ai/setup/x', http: { headers: { apiKey: { label: 'API key', description: 'Your key', required: true } }, query: {} }, missing: { headers: ['apiKey'], query: [] } }
        return { state: 'connected' }
      }
      if (method === 'GET') return existing ? answer({ connectionId: id, name: 'x', mcpUrl: existing.mcpUrl, metadata: existing.metadata, status: status() }) : answer({ error: 'not found' }, 404)
      if (method === 'DELETE') { connections.delete(id!); return answer({ success: true }) }
      if (method === 'PUT') {
        const next = existing ?? { server: body.server, metadata: body.metadata, headers: {}, mcpUrl: 'https://server.run.tools/mcp' }
        Object.assign(next.headers, body.headers ?? {})
        if (body.mcpUrl) next.mcpUrl = body.mcpUrl
        connections.set(id!, next)
        return answer({ connectionId: id, name: body.name ?? 'x', mcpUrl: next.mcpUrl, metadata: next.metadata, status: status() }, existing ? 200 : 201)
      }
    }
    return answer({ error: 'unexpected' }, 500)
  })
  return { request: request as unknown as Requester, calls, connections }
}
function guest() {
  const runs: string[][] = []
  return { runs, run: vi.fn(async (command: string, args: string[]) => { runs.push([command, ...args]); return '' }) }
}
function library(s: ReturnType<typeof smithery>, options: { tag?: string; dir?: string; guest?: ReturnType<typeof guest> | null } = {}) {
  const dir = options.dir ?? root()
  const events: unknown[] = []
  const g = options.guest === undefined ? guest() : options.guest
  const files: Array<{ path: string; data: string }> = []
  const lib = new McpLibrary({ file: join(dir, 'mcp-library.json'), tag: options.tag ?? 'abcdef0123456789/owner', catalog: new SmitheryCatalog(join(dir, 'catalog'), s.request), guest: () => g ?? undefined, emit: event => events.push(event), request: s.request,
    writeFile: async (path, data) => { files.push({ path, data: data.toString('utf8') }) } })
  return { lib, events, guest: g, dir, files }
}

describe('the MCP Library', () => {
  it('connects an account, keeps its key private, and adds a server that lists its tools', async () => {
    const s = smithery()
    const { lib, guest: g, dir, files } = library(s)
    expect(() => lib.connect('short')).toThrow('Paste a Smithery API key')
    await expect(lib.connect('wrong-key-12345')).rejects.toThrow('did not accept the API key')
    expect(await lib.connect(KEY)).toEqual({ connected: true, namespace: 'owner-space' })
    expect(statSync(join(dir, 'mcp-library.json')).mode & 0o777).toBe(0o600)
    const added = await lib.add('brave')
    expect(added).toMatchObject({ id: connectionId('abcdef0123456789/owner', 'brave'), server: 'brave', status: { state: 'connected', tools: 2 } })
    expect(s.connections.get(added.id)?.metadata).toEqual({ caboose: 'abcdef0123456789/owner' })
    const listed = JSON.stringify(await lib.connections())
    expect(listed).not.toContain(KEY)
    expect(listed).not.toContain('svc-')
    // The computer gets the namespace endpoint and a scoped token, never the account's key, and
    // never on a command line.
    expect(files.at(-1)!.path).toBe('.local/state/caboose/mcp-library.json')
    expect(JSON.parse(files.at(-1)!.data)).toMatchObject({ url: 'https://mcp.smithery.run/owner-space', token: 'svc-token-1' })
    expect(JSON.stringify(files)).not.toContain(KEY)
    expect(JSON.stringify(g!.runs)).not.toMatch(/svc-token|sk-owner/)
    const minted = s.calls.find(call => call.path === '/tokens')!
    expect(minted.body.policy).toEqual([{ namespaces: 'owner-space', resources: 'connections', operations: ['read', 'execute'], metadata: { caboose: 'abcdef0123456789/owner' }, ttl: 86400 }])
    expect(minted.auth).toBe(`Bearer ${KEY}`)
  })
  it('asks for the settings a server needs, accepting only those', async () => {
    const s = smithery({ needsKey: true })
    const { lib, dir } = library(s)
    await lib.connect(KEY)
    const added = await lib.add('exa')
    expect(added.status).toMatchObject({ state: 'needs-setup', fields: [{ key: 'apiKey', where: 'header', label: 'API key', required: true }] })
    await expect(lib.configure(added.id, { apiKey: 'k', extra: 'x' })).rejects.toThrow('not a setting this server asked for')
    await expect(lib.configure(added.id, {})).rejects.toThrow('API key is required')
    const done = await lib.configure(added.id, { apiKey: 'server-secret' })
    expect(done.status).toEqual({ state: 'connected', tools: 2 })
    expect(s.connections.get(added.id)?.headers).toEqual({ apiKey: 'server-secret' })
    // Smithery keeps the server's key; the host keeps no copy.
    expect(readFileSync(join(dir, 'mcp-library.json'), 'utf8')).not.toContain('server-secret')
  })
  it('reports sign-in with its hosted page only', async () => {
    const s = smithery({ oauth: true })
    const { lib } = library(s)
    await lib.connect(KEY)
    expect((await lib.add('gmail')).status).toEqual({ state: 'needs-sign-in', setupUrl: 'https://auth.smithery.ai/setup/abc' })
    expect(readStatus({ state: 'auth_required', setupUrl: 'https://evil.example/phish' })).toMatchObject({ state: 'failed' })
    expect(readStatus({ state: 'error', message: 'token sk-leak in body' })).toEqual({ state: 'failed', message: "The server didn't accept the connection. Check its settings, or remove it." })
  })
  it('never changes another computer\'s connection, and holds at most 20 servers', async () => {
    const s = smithery()
    const shared = library(s, { tag: 'abcdef0123456789/owner' })
    await shared.lib.connect(KEY)
    const mine = await shared.lib.add('brave')
    // The same account on another computer: its own ids, and no reach into the first's.
    const other = library(s, { tag: 'abcdef0123456789/c-other' })
    await other.lib.connect(KEY)
    const theirs = await other.lib.add('brave')
    expect(theirs.id).not.toBe(mine.id)
    s.connections.get(mine.id)!.metadata = { caboose: 'someone-else' }
    await expect(shared.lib.remove(mine.id)).rejects.toThrow('belongs to another computer')
    expect(s.connections.has(mine.id)).toBe(true)
    const full = library(smithery())
    await full.lib.connect(KEY)
    for (let n = 0; n < MAX_CONNECTIONS; n++) await full.lib.add(`server-${n}`)
    await expect(full.lib.add('one-more')).rejects.toThrow(`up to ${MAX_CONNECTIONS} MCP servers`)
  })
  it('removes servers, and clears the computer\'s access with the last one or the account', async () => {
    const s = smithery()
    const { lib, guest: g, events } = library(s)
    await lib.connect(KEY)
    const added = await lib.add('brave')
    expect(await lib.remove(added.id)).toEqual({ removed: true })
    expect(s.connections.size).toBe(0)
    expect(g!.runs.at(-1)).toEqual(['/bin/rm', '-f', '--', '/home/caboose/.local/state/caboose/mcp-library.json'])
    expect(events).toContainEqual({ type: 'mcp.changed', id: added.id })
    await lib.add('exa')
    expect(await lib.disconnect()).toEqual({ connected: false, namespace: null })
    expect(s.connections.size).toBe(0)
    expect(await lib.active()).toBe(false)
    await expect(lib.add('brave')).rejects.toThrow('Connect a Smithery account first')
  })
  it('runs changes one at a time: a removal waits for a check, concurrent adds respect the limit, and an account change waits for both', async () => {
    const s = smithery()
    const { lib, files } = library(s)
    await lib.connect(KEY)
    await expect(lib.connect(KEY)).rejects.toThrow('Disconnect it first')
    const original = s.request
    let release!: () => void
    const gate = new Promise<void>(resolve => { release = resolve })
    ;(lib as unknown as { options: { request: Requester } }).options.request = (async (url: string, max: number, init?: never) => {
      if (url.endsWith('/mcp')) await gate
      return original(url, max, init)
    }) as Requester
    const adding = lib.add('brave')
    const removing = lib.add('exa').then(() => lib.disconnect())
    await new Promise(resolve => setTimeout(resolve, 10))
    expect(s.connections.size).toBe(1)
    release()
    expect((await adding).status).toEqual({ state: 'connected', tools: 2 })
    expect(await removing).toEqual({ connected: false, namespace: null })
    expect(s.connections.size).toBe(0)
    // The last thing the computer was told: nothing.
    expect(files.length).toBeGreaterThan(0)
  })
  it('keeps the account when Smithery cannot remove a server, so removal can be retried', async () => {
    const s = smithery()
    const { lib, guest: g } = library(s)
    await lib.connect(KEY)
    await lib.add('brave')
    const original = s.request
    ;(lib as unknown as { options: { request: Requester } }).options.request = (async (url: string, max: number, init?: { method?: string }) => init?.method === 'DELETE' ? { status: 500, headers: {}, body: Buffer.from('boom') } : original(url, max, init as never)) as Requester
    await expect(lib.disconnect()).rejects.toThrow('could not remove Brave yet')
    expect(await lib.account()).toEqual({ connected: true, namespace: 'owner-space' })
    expect(g!.runs.at(-1)).toEqual(['/bin/rm', '-f', '--', '/home/caboose/.local/state/caboose/mcp-library.json'])
    ;(lib as unknown as { options: { request: Requester } }).options.request = original
    expect(await lib.disconnect()).toEqual({ connected: false, namespace: null })
  })
  it('uses the expiry Smithery gives a token, and gives the computer nothing when minting fails', async () => {
    const s = smithery()
    const { lib, guest: g, files } = library(s)
    await lib.connect(KEY)
    await lib.add('brave')
    expect(Date.parse(JSON.parse(files.at(-1)!.data).expiresAt)).toBeGreaterThan(Date.now())
    const original = s.request
    ;(lib as unknown as { options: { request: Requester } }).options.request = (async (url: string, max: number, init?: never) => url.endsWith('/tokens') ? { status: 200, headers: {}, body: Buffer.from(JSON.stringify({ token: 'svc-token-expired', expiresAt: '2000-01-01T00:00:00Z' })) } : original(url, max, init)) as Requester
    ;(lib as unknown as { token: null }).token = null
    await expect(lib.sync(true)).rejects.toThrow('no usable access token')
    expect(g!.runs.at(-1)?.[0]).toBe('/bin/rm')
  })
  it('finds a JSON-RPC result in JSON or an event stream', () => {
    const response = (body: string, type: string) => ({ status: 200, headers: { 'content-type': type }, body: Buffer.from(body) })
    expect(rpcResult(response('{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}', 'application/json'), 2)).toEqual({ tools: [] })
    expect(rpcResult(response('event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n\n', 'text/event-stream'), 1)).toEqual({ ok: true })
    expect(rpcResult(response('{"id":3,"error":{}}', 'application/json'), 3)).toBeNull()
  })
})
