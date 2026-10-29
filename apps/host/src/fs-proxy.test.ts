import { once } from 'node:events'
import { createServer, request as httpRequest } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterEach, expect, it, vi } from 'vitest'
import { WebSocket } from 'ws'
import { createCabooseServer, type Controller } from './server.js'
import { ComputerLifecycle } from './lifecycle.js'
import { proxyFiles } from './fs-proxy.js'
import { SettingsStore, settingsLimits } from './settings.js'

const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const close of cleanup.splice(0)) await close() })

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
  cleanup.push(() => new Promise(resolve => upstream.close(() => resolve())))
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
  cleanup.push(() => new Promise(resolve => upstream.close(() => resolve())))
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
})

it('wakes, authenticates and streams a range through the guest relay', async () => {
  const upstream = createServer((req, res) => {
    expect(req.headers.authorization).toBe('Bearer wake-token')
    expect(req.url).toBe('/content?path=Documents%2Ftest')
    expect(req.headers.range).toBe('bytes=2-3')
    res.writeHead(206, { 'content-range': 'bytes 2-3/5', 'content-length': '2', etag: '"version"' })
    res.end('cd')
  })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => upstream.close(() => resolve())))
  let wakes = 0
  const controller: Controller = {
    wake: async () => { wakes++; return { state: 'running', display: { path: '/v1/display', token: '', protocol: 'caboose-display' }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } } },
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
  expect(wakes).toBe(1)
})

it('signals control clients when the guest change anchor advances', async () => {
  let polls = 0
  const upstream = createServer((_req, res) => {
    polls++
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ anchor: polls === 1 ? 'epoch:1' : 'epoch:2', changed: polls > 1, reset: false, events: [] }))
  })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => upstream.close(() => resolve())))
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
  await vi.waitFor(() => expect(events).toContainEqual({ type: 'fs.changed', anchor: 'epoch:2' }), { timeout: 3000 })
  socket.terminate()
})


it('wakes files headlessly then promotes a session without another boot or token change', async () => {
  const upstream = createServer((req, res) => {
    expect(req.headers.authorization).toBe('Bearer wake-token')
    res.end('{"items":[]}')
  })
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening')
  cleanup.push(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(() => resolve()) }))
  const wake = vi.fn(async () => ({ state: 'running', display: { path: '/v1/display', token: 'wake-token', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 512, vcpus: 1 } }))
  const ensureOwnerDisplay = vi.fn(async () => {})
  const controller: Controller = {
    wake, ensureOwnerDisplay, park: async () => {}, stats: () => ({}), apps: async () => [], launch: async () => {},
    displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => undefined,
    activeResources: () => null, hasSavedState: () => false,
    fileService: () => ({ url: `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`, token: 'wake-token' }),
  }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 512, vcpus: 1, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  cleanup.unshift(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const headers = { authorization: 'Bearer owner' }
  const files = await fetch(`${base}/v1/fs/list`, { headers })
  expect(files.status).toBe(200); await files.text()
  expect(wake).toHaveBeenCalledWith({ display: 'headless' })
  expect(ensureOwnerDisplay).not.toHaveBeenCalled()
  const session = await fetch(`${base}/v1/session`, { method: 'POST', headers })
  expect(session.status).toBe(200)
  expect((await session.json()).display.token).toBe('wake-token')
  expect(ensureOwnerDisplay).toHaveBeenCalledOnce()
  expect(wake).toHaveBeenCalledOnce()
})
