import { once } from 'node:events'
import { createServer, request as httpRequest, type IncomingMessage, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterEach, expect, it, vi } from 'vitest'
import { WebSocket } from 'ws'
import { createCabooseServer, type Controller } from './server.js'
import { ComputerLifecycle } from './lifecycle.js'
import { proxyFiles, proxyWebview, publicFileUrl } from './fs-proxy.js'
import { SettingsStore, settingsLimits } from './settings.js'

const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const close of cleanup.splice(0)) await close() })

// Hold event requests until the test supplies authoritative state, like a long poll.
// Keep transport traffic separate from public file/bridge operations.
function eventFixture(token: string) {
  const polls: Array<{ body: { cursor: string; generation: number; channels: string[] }; res: ServerResponse }> = []
  function handle(req: IncomingMessage, res: ServerResponse): boolean {
    if (req.url !== '/events' && req.url !== '/events/presence') return false
    expect(req.method).toBe('POST')
    expect(req.headers.authorization).toBe(`Bearer ${token}`)
    let body = ''
    req.on('data', chunk => { body += chunk })
    req.on('end', () => {
      const value = JSON.parse(body)
      expect(value.session).toMatch(/^[0-9a-f]{32}$/)
      expect(Number.isSafeInteger(value.generation)).toBe(true)
      if (req.url === '/events/presence') { res.writeHead(204); res.end(); return }
      expect(value.channels).toBeInstanceOf(Array)
      expect(typeof value.cursor).toBe('string')
      polls.push({ body: value, res })
    })
    return true
  }
  async function next(cursor?: string) {
    let poll: typeof polls[number] | undefined
    await vi.waitFor(() => {
      poll = polls.find(p => !p.res.destroyed && !p.res.writableEnded && p.body.channels.includes('fs')
        && (cursor === undefined || p.body.cursor === cursor))
      expect(poll).toBeDefined()
    })
    return poll!
  }
  function reply(poll: typeof polls[number], cursor: string, anchor: string) {
    poll.res.writeHead(200, { 'content-type': 'application/json' })
    poll.res.end(JSON.stringify({ cursor, records: [{ channel: 'fs', record: { anchor } }] }))
  }
  return { handle, next, reply }
}

it('wakes for parked reads and writes, and authenticates before waking', async () => {
  const transport = eventFixture('private')
  const requests: Array<{ method?: string; range?: string; match?: string; body: string }> = []
  const upstream = createServer((req, res) => {
    if (transport.handle(req, res)) return
    expect(req.url).toBe('/content?path=a')
    expect(req.headers.authorization).toBe('Bearer private')
    let body = ''
    req.on('data', chunk => { body += chunk })
    req.on('end', () => { requests.push({ method: req.method, range: req.headers.range, match: req.headers['if-match'], body }); res.writeHead(req.method === 'GET' ? 206 : 200, { etag: '"v1"', 'content-range': 'bytes 0-0/1' }); res.end(req.method === 'GET' ? 'x' : '') })
  })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  const wake = vi.fn(async () => ({ state: 'running', display: { path: '/v1/display', token: '', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }))
  const controller: Controller = { wake, park: async () => {}, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => undefined, activeResources: () => null, hasSavedState: () => false,
    fileService: () => ({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'private' }) }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  cleanup.unshift(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  expect((await fetch(base + '/v1/fs/content?path=a')).status).toBe(401)
  expect(wake).not.toHaveBeenCalled()
  const headers = { authorization: 'Bearer owner' }
  const read = await fetch(base + '/v1/fs/content?path=a', { headers: { ...headers, range: 'bytes=0-0', 'if-match': '"v1"' } })
  expect(read.status).toBe(206)
  expect(read.headers.get('etag')).toBe('"v1"')
  expect(read.headers.get('content-range')).toBe('bytes 0-0/1')
  expect(await read.text()).toBe('x')
  expect((await fetch(base + '/v1/session/park', { method: 'POST', headers })).status).toBe(200)
  expect((await fetch(base + '/v1/fs/content?path=a', { method: 'PUT', headers: { ...headers, 'if-match': '"v1"' }, body: 'y' })).status).toBe(200)
  expect(wake).toHaveBeenCalledTimes(2)
  expect(requests).toEqual([{ method: 'GET', range: 'bytes=0-0', match: '"v1"', body: '' }, { method: 'PUT', range: undefined, match: '"v1"', body: 'y' }])
})

it('releases the lifecycle queue when a file client disconnects during wake', async () => {
  const upstream = createServer(() => {})
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  let finishWake!: () => void
  let startedWake!: () => void
  const wakeStarted = new Promise<void>(resolve => { startedWake = resolve })
  const wakeGate = new Promise<void>(resolve => { finishWake = resolve })
  const controller: Controller = {
    wake: async () => { startedWake(); await wakeGate; return { state: 'running', display: { path: '/v1/display', token: '', protocol: 'caboose-display' }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } } },
    park: async () => {}, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => undefined,
    activeResources: () => null, hasSavedState: () => false,
    fileService: () => ({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'wake-token' }),
  }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  cleanup.unshift(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  let closed!: () => void
  const serverClosed = new Promise<void>(resolve => { closed = resolve })
  app.server.prependListener('request', (_req, res) => res.once('close', closed))
  const client = httpRequest(base + '/v1/fs/content?path=test', { headers: { authorization: 'Bearer owner' } })
  client.on('error', () => {})
  client.end()
  await wakeStarted
  client.destroy()
  await serverClosed
  finishWake()
  const response = await fetch(base + '/v1/session', { method: 'POST', headers: { authorization: 'Bearer owner' }, signal: AbortSignal.timeout(1000) })
  expect(response.status).toBe(200)
})

it.each(['disconnect', 'timeout'] as const)('releases the queue after an active file transfer stalls: %s', async mode => {
  let received!: () => void
  const receivedRequest = new Promise<void>(resolve => { received = resolve })
  const upstream = createServer(req => { req.resume(); received() })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  const computer = new ComputerLifecycle({ wake: async () => 'running', park: async () => {} }, 60_000)
  const app = createServer((req, res) => {
    if (req.url === '/session') {
      void computer.wakeAndRun(async () => { res.end('ready') })
    } else {
      void computer.wakeAndRun(() => proxyFiles({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'test' }, req, res, 100))
    }
  })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  cleanup.unshift(() => new Promise(resolve => { app.closeAllConnections(); app.close(() => resolve()) }))
  const base = `http://127.0.0.1:${(app.address() as AddressInfo).port}`
  const client = httpRequest(base + '/v1/fs/content')
  client.on('error', () => {})
  client.end()
  await receivedRequest
  const result = mode === 'timeout' ? once(client, 'response') : undefined
  if (mode === 'disconnect') client.destroy()
  else {
    const [response] = await result!
    expect(response.statusCode).toBe(504)
    response.resume()
  }
  expect(await (await fetch(base + '/session', { signal: AbortSignal.timeout(1000) })).text()).toBe('ready')
})

it('keeps a transfer alive while bytes continue to flow', async () => {
  const upstream = createServer(async (_req, res) => {
    res.writeHead(200)
    for (const chunk of ['a', 'b', 'c', 'd']) {
      res.write(chunk)
      await new Promise(resolve => setTimeout(resolve, 40))
    }
    res.end()
  })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  const app = createServer((req, res) => { void proxyFiles({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'test' }, req, res, 100) })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  cleanup.unshift(() => new Promise(resolve => { app.closeAllConnections(); app.close(() => resolve()) }))
  const response = await fetch(`http://127.0.0.1:${(app.address() as AddressInfo).port}/v1/fs/content`)
  expect(response.status).toBe(200)
  expect(await response.text()).toBe('abcd')
})

it('closes an incomplete response when the guest stops sending', async () => {
  const upstream = createServer((_req, res) => { res.writeHead(200, { 'content-length': '10' }); res.write('abc') })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  const app = createServer((req, res) => { void proxyFiles({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'test' }, req, res, 100) })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  cleanup.unshift(() => new Promise(resolve => { app.closeAllConnections(); app.close(() => resolve()) }))
  const response = await fetch(`http://127.0.0.1:${(app.address() as AddressInfo).port}/v1/fs/content`)
  expect(response.status).toBe(200)
  await expect(response.text()).rejects.toThrow()
})

it('streams a chunked upload and a large response intact', async () => {
  const chunk = Buffer.alloc(256 * 1024, 42)
  const upstream = createServer((req, res) => {
    let size = 0
    req.on('data', data => { size += data.length })
    req.on('end', () => {
      expect(size).toBe(chunk.length * 8)
      res.writeHead(200)
      for (let i = 0; i < 8; i++) res.write(chunk)
      res.end()
    })
  })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  const app = createServer((req, res) => { void proxyFiles({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'test' }, req, res) })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  cleanup.unshift(() => new Promise(resolve => { app.closeAllConnections(); app.close(() => resolve()) }))
  const client = httpRequest(`http://127.0.0.1:${(app.address() as AddressInfo).port}/v1/fs/content`, { method: 'PUT' })
  const response = once(client, 'response')
  for (let i = 0; i < 8; i++) if (!client.write(chunk)) await once(client, 'drain')
  client.end()
  const [incoming] = await response
  const chunks: Buffer[] = []
  for await (const data of incoming) chunks.push(data as Buffer)
  expect(Buffer.concat(chunks)).toEqual(Buffer.alloc(chunk.length * 8, 42))
}, 15_000) // Exercise backpressure without treating shared-runner throughput as a deadline.

it('wakes, authenticates and streams a range through the guest relay', async () => {
  const transport = eventFixture('wake-token')
  const upstream = createServer((req, res) => {
    if (transport.handle(req, res)) return
    expect(req.headers.authorization).toBe('Bearer wake-token')
    expect(req.url).toBe('/content?path=Documents%2Ftest')
    expect(req.headers.range).toBe('bytes=2-3')
    res.writeHead(206, { 'content-range': 'bytes 2-3/5', 'content-length': '2', etag: '"version"' })
    res.end('cd')
  })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  const modes: string[] = []
  const session = { state: 'running', display: { path: '/v1/display', token: 'wake-token', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }
  const promote = vi.fn(async () => session)
  const controller: Controller = {
    wake: async mode => { modes.push(mode ?? 'interactive'); return session }, promote,
    park: async () => {}, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => undefined,
    activeResources: () => null, hasSavedState: () => false,
    fileService: () => ({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'wake-token' }),
  }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  cleanup.unshift(() => app.shutdown())
  const url = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}/v1/fs/content?path=Documents%2Ftest`
  expect((await fetch(url)).status).toBe(401)
  const response = await fetch(url, { headers: { authorization: 'Bearer owner', range: 'bytes=2-3' } })
  expect(response.status).toBe(206)
  expect(response.headers.get('content-range')).toBe('bytes 2-3/5')
  expect(response.headers.get('etag')).toBe('"version"')
  expect(await response.text()).toBe('cd')
  expect(modes).toEqual(['headless'])
  expect(promote).not.toHaveBeenCalled()
  const opened = await fetch(url.split('/v1/fs/')[0] + '/v1/session', { method: 'POST', headers: { authorization: 'Bearer owner' } })
  expect(opened.status).toBe(200)
  expect((await opened.json()).display.token).toBe('wake-token')
  expect(promote).toHaveBeenCalledOnce()
  expect(modes).toEqual(['headless'])
})

it('signals control clients when the guest change anchor advances', async () => {
  const transport = eventFixture('wake-token')
  const upstream = createServer((req, res) => { expect(transport.handle(req, res)).toBe(true) })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  const controller: Controller = {
    wake: async () => ({ state: 'running', display: { path: '/v1/display', token: '', protocol: 'caboose-display' }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }),
    park: async () => {}, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => undefined,
    activeResources: () => null, hasSavedState: () => false,
    fileService: () => ({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'wake-token' }),
  }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  cleanup.unshift(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  await fetch(base + '/v1/session', { method: 'POST', headers: { authorization: 'Bearer owner' } })
  const socket = new WebSocket(base.replace('http:', 'ws:') + '/v1/control', { headers: { authorization: 'Bearer owner' } })
  const events: Array<{ type: string; anchor?: string }> = []
  socket.on('message', data => events.push(JSON.parse(data.toString())))
  await once(socket, 'open')
  cleanup.unshift(async () => { socket.terminate() })
  transport.reply(await transport.next(''), 'cursor-1', 'epoch:1')
  const changed = await transport.next('cursor-1')
  expect(events.filter(event => event.type === 'fs.changed')).toEqual([])
  transport.reply(changed, 'cursor-2', 'epoch:2')
  await vi.waitFor(() => expect(events).toContainEqual({ type: 'fs.changed', anchor: 'epoch:2' }), { timeout: 3000 })
  socket.terminate()
})

it('keeps a background control anchor across freeze and resets it on park', async () => {
  const transport = eventFixture('test')
  const upstream = createServer((req, res) => {
    if (transport.handle(req, res)) return
    expect(req.url).toBe('/sessions')
    expect(req.headers.authorization).toBe('Bearer test')
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ sessions: [] }))
  })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  const guest = { run: async () => '' }
  const service = () => ({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'test' })
  const controller: Controller = {
    wake: async () => ({ state: 'running', display: { path: '/v1/display', token: '', protocol: 'caboose-display' }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }),
    canFreeze: () => true, freeze: async () => {}, thaw: async () => {}, park: async () => {},
    stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => guest,
    activeResources: () => null, hasSavedState: () => false, fileService: service, terminalService: service,
  }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  cleanup.unshift(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const headers = { authorization: 'Bearer owner' }
  await fetch(base + '/v1/session', { method: 'POST', headers })
  const socket = new WebSocket(base.replace('http:', 'ws:') + '/v1/control?foreground=0', { headers })
  const events: Array<{ type: string; anchor?: string; state?: string }> = []
  socket.on('message', data => events.push(JSON.parse(data.toString())))
  await once(socket, 'open')
  cleanup.unshift(async () => { socket.terminate() })
  transport.reply(await transport.next(''), 'cursor-1', 'epoch:1')
  const held = await transport.next('cursor-1')
  expect(events.filter(event => event.type === 'fs.changed')).toEqual([])
  await vi.waitFor(() => expect(events).toContainEqual({ type: 'computer.state', state: 'frozen' }), { timeout: 6000 })
  await fetch(base + '/v1/session', { method: 'POST', headers })
  const thawed = await transport.next('')
  expect(thawed.body.generation).toBeGreaterThan(held.body.generation)
  transport.reply(thawed, 'cursor-2', 'epoch:2')
  await vi.waitFor(() => expect(events).toContainEqual({ type: 'fs.changed', anchor: 'epoch:2' }))
  const current = await transport.next('cursor-2')
  // A response from the canceled pre-freeze receiver must not roll back the baseline.
  transport.reply(held, 'stale-cursor', 'epoch:1')
  transport.reply(current, 'cursor-3', 'epoch:2')
  const latest = await transport.next('cursor-3')
  transport.reply(latest, 'cursor-4', 'epoch:3')
  await vi.waitFor(() => expect(events.filter(event => event.type === 'fs.changed')).toEqual([
    { type: 'fs.changed', anchor: 'epoch:2' }, { type: 'fs.changed', anchor: 'epoch:3' },
  ]))
  const closed = once(socket, 'close')
  await fetch(base + '/v1/session/park', { method: 'POST', headers, body: '{}' })
  await closed
  await fetch(base + '/v1/session', { method: 'POST', headers })
  const next = new WebSocket(base.replace('http:', 'ws:') + '/v1/control?foreground=0', { headers })
  cleanup.unshift(async () => { next.terminate() })
  const nextEvents: Array<{ type: string; anchor?: string }> = []
  next.on('message', data => nextEvents.push(JSON.parse(data.toString())))
  await once(next, 'open')
  transport.reply(await transport.next(''), 'new-cursor-1', 'new-epoch:1')
  const newBaseline = await transport.next('new-cursor-1')
  expect(nextEvents.filter(event => event.type === 'fs.changed')).toEqual([])
  transport.reply(newBaseline, 'new-cursor-2', 'new-epoch:2')
  await vi.waitFor(() => expect(nextEvents.filter(event => event.type === 'fs.changed')).toEqual([
    { type: 'fs.changed', anchor: 'new-epoch:2' },
  ]))
  next.terminate()
}, 10_000)


it('allows only public operations after URL normalization', () => {
  const base = 'http://127.0.0.1:14700'
  for (const path of ['/v1/fs/keyring', '/v1/fs/content/../keyring', '/v1/fs/%2e/keyring',
    '/v1/fs/%2e%2e/keyring', '/v1/fs/%6beyring', '/v1/fs/%2fkeyring', '/keyring',
    'http://evil.test/v1/fs/content', '//evil.test/v1/fs/content']) {
    expect(publicFileUrl(path, base), path).toBeUndefined()
  }
  expect(publicFileUrl('/v1/fs/content?path=keyring', base)?.href).toBe(base + '/content?path=keyring')
})


it('relays only a bounded bridge POST with the guest credential', async () => {
  const seen: Array<{ url?: string; auth?: string; cookie?: string }> = []
  const upstream = createServer((req, res) => {
    seen.push({ url: req.url, auth: req.headers.authorization, cookie: req.headers.cookie })
    req.resume(); req.on('end', () => { res.writeHead(200, { 'content-type': 'application/json' }); res.end('{}') })
  })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  const service = { url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'guest' }
  const app = createServer((req, res) => { void proxyWebview(service, req.url!.slice(1), req, res) })
  app.listen(0, '127.0.0.1'); await once(app, 'listening')
  cleanup.unshift(() => new Promise(resolve => app.close(() => resolve())))
  const base = `http://127.0.0.1:${(app.address() as AddressInfo).port}`
  const instance = 'a'.repeat(32)
  const ok = await fetch(`${base}/${instance}`, { method: 'POST', headers: { authorization: 'Bearer owner', cookie: 'secret' }, body: '{}' })
  expect(ok.status).toBe(200)
  expect(seen).toEqual([{ url: `/webview/${instance}`, auth: 'Bearer guest', cookie: undefined }])
  expect((await fetch(`${base}/../bad`, { method: 'POST', body: '{}' })).status).toBe(400)
  expect((await fetch(`${base}/${instance}`)).status).toBe(400)
  expect(seen).toHaveLength(1)
})

it('authorizes the app bridge through the selected computer', async () => {
  const transport = eventFixture('guest')
  const upstream = createServer((req, res) => {
    if (transport.handle(req, res)) return
    expect(req.url).toBe(`/webview/${'a'.repeat(32)}`)
    expect(req.headers.authorization).toBe('Bearer guest')
    req.resume(); req.on('end', () => { res.writeHead(200, { 'content-type': 'application/json' }); res.end('{"ok":true}') })
  })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  const controller: Controller = {
    wake: async () => ({ state: 'running', display: { path: '/v1/display', token: '', protocol: 'caboose-display' }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }),
    park: async () => {}, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => undefined,
    activeResources: () => null, hasSavedState: () => false,
    fileService: () => ({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'guest' }),
  }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  cleanup.unshift(() => app.shutdown())
  const url = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}/v1/webview/${'a'.repeat(32)}/bridge`
  expect((await fetch(url, { method: 'POST', body: '{}' })).status).toBe(401)
  const response = await fetch(url, { method: 'POST', headers: { authorization: 'Bearer owner' }, body: '{}' })
  expect(response.status).toBe(200)
  expect(await response.json()).toEqual({ ok: true })
})
