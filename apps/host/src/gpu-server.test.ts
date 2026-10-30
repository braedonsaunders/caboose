import { once } from 'node:events'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IncomingMessage } from 'node:http'
import type { AddressInfo } from 'node:net'
import { WebSocket, WebSocketServer } from 'ws'
import { afterEach, expect, it, vi } from 'vitest'
import { GPU_MAX_MESSAGE, GPU_PROTOCOL } from './gpu-relay.js'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'
import { ComputerRegistry, PhoneTokens } from './computers.js'

const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close() })

async function fixture(acceptProtocol = GPU_PROTOCOL, headless = false) {
  const upstream = new WebSocketServer({ port: 0, handleProtocols: () => acceptProtocol })
  await once(upstream, 'listening')
  const requests: IncomingMessage[] = []
  upstream.on('connection', (socket, request) => {
    requests.push(request)
    socket.on('error', () => {})
    socket.on('message', (bytes, binary) => socket.send(bytes, { binary }))
  })
  const park = vi.fn(async () => {})
  const controller: Controller = {
    wake: async () => ({ state: 'running', display: { path: '/v1/display', token: 'guest-per-wake', protocol: 'caboose-display' },
      computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }),
    park, activeResources: () => null, hasSavedState: () => false, stats: () => ({}),
    apps: async () => [], launch: async () => {}, guest: () => undefined, ensureAgentSeat: async () => {},
    displayUrl: `ws://127.0.0.1:${(upstream.address() as AddressInfo).port}/old?discard=yes`, agentDisplayUrl: 'ws://127.0.0.1:1',
  }
  const promote = vi.fn(() => controller.wake())
  controller.promote = promote
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null },
    settingsLimits(), { load: async () => undefined, save: async () => {} })
  const directory = await mkdtemp(join(tmpdir(), 'caboose-gpu-route-'))
  const computers = await ComputerRegistry.open(directory)
  const phones = PhoneTokens.memory()
  const app = createCabooseServer({ token: 'owner-token', settings, controller,
    fleet: { computers, phones, defaults: { memoryMb: 2048, vcpus: 2, idleMs: 60_000 },
      maxRunning: 1, open: async () => ({ settings, controller }) } })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const clients: WebSocket[] = []
  let stopping: Promise<void> | undefined
  const shutdown = () => stopping ??= app.shutdown()
  cleanup.push(async () => {
    for (const client of clients) if (client.readyState !== WebSocket.CLOSED) client.terminate()
    await shutdown()
    for (const client of upstream.clients) client.terminate()
    await new Promise<void>(resolve => upstream.close(() => resolve()))
    await rm(directory, { recursive: true, force: true })
  })
  if (headless) await app.computer.wake('headless')
  else await fetch(`${base}/v1/session`, { method: 'POST', headers: { authorization: 'Bearer owner-token' } })
  function connect(path = '/v1/gpu', protocol: string | string[] = GPU_PROTOCOL, headers: Record<string, string> = {}) {
    const client = new WebSocket(base.replace('http:', 'ws:') + path, protocol, {
      headers: { authorization: 'Bearer owner-token', ...headers }, handshakeTimeout: 2_000,
    })
    client.on('error', () => {})
    clients.push(client)
    return client
  }
  return { app, base, upstream, requests, connect, park, shutdown, phones, promote, controller }
}

async function refused(client: WebSocket): Promise<number> {
  return new Promise(resolve => client.once('unexpected-response', (_request, response) => {
    response.resume()
    client.terminate()
    resolve(response.statusCode!)
  }))
}

it('authenticates GPU upgrades and sends only trusted identities and the guest token upstream', async () => {
  const f = await fixture()
  expect(await refused(f.connect('/v1/gpu', GPU_PROTOCOL, { authorization: 'Bearer wrong' }))).toBe(401)
  const client = f.connect('/v1/gpu', GPU_PROTOCOL, {
    'x-caboose-gpu-computer': 'spoofed', 'x-caboose-gpu-executor': 'spoofed', origin: 'https://untrusted.invalid',
  })
  await once(client, 'open')
  const reply = once(client, 'message')
  client.send(Buffer.from([0, 255, 17, 9]))
  const [bytes, binary] = await reply
  expect(bytes).toEqual(Buffer.from([0, 255, 17, 9]))
  expect(binary).toBe(true)
  expect(client.protocol).toBe(GPU_PROTOCOL)
  expect(f.requests).toHaveLength(1)
  const request = f.requests[0]!
  expect(request.url).toBe('/gpu')
  expect(request.headers.authorization).toBe('Bearer guest-per-wake')
  expect(request.headers['x-caboose-gpu-computer']).toBe('owner')
  expect(request.headers['x-caboose-gpu-executor']).toMatch(/^[a-f0-9-]{36}$/)
  expect(request.headers.origin).toBeUndefined()
  expect(request.headers['sec-websocket-extensions']).toBeUndefined()
})

it('rejects agent routing, query credentials and legacy or ambiguous protocols before opening upstream', async () => {
  const f = await fixture()
  for (const query of ['?seat=agent', '?seat=owner', '?token=x', '?executor=x']) {
    expect(await refused(f.connect('/v1/gpu' + query))).toBe(400)
  }
  expect(await refused(f.connect('/v1/gpu', 'binary'))).toBe(400)
  expect(await refused(f.connect('/v1/gpu', [GPU_PROTOCOL, 'binary']))).toBe(400)
  expect(f.requests).toHaveLength(0)
})

it('allows one executor, releases both ends on disconnect, and mints a new identity on reconnect', async () => {
  const f = await fixture()
  const first = f.connect()
  await once(first, 'open')
  const firstReply = once(first, 'message'); first.send(Buffer.from([1])); await firstReply
  const identity = f.requests[0]!.headers['x-caboose-gpu-executor']
  expect(await refused(f.connect())).toBe(409)
  const closed = once(first, 'close'); first.close(); await closed
  await vi.waitFor(() => expect(f.upstream.clients.size).toBe(0))
  // The relay closes before its reservation is made available again.
  await new Promise(resolve => setImmediate(resolve))
  const second = f.connect(); await once(second, 'open')
  const secondReply = once(second, 'message'); second.send(Buffer.from([2])); await secondReply
  expect(f.requests[1]!.headers['x-caboose-gpu-executor']).not.toBe(identity)
})

it('rejects text without relaying it and closes the guest connection', async () => {
  const f = await fixture()
  const client = f.connect(); await once(client, 'open')
  const reply = once(client, 'message'); client.send(Buffer.from([1])); await reply
  const messages = vi.fn(); [...f.upstream.clients][0]!.on('message', messages)
  const closed = once(client, 'close'); client.send('not command bytes'); await closed
  expect(messages).not.toHaveBeenCalled()
  await vi.waitFor(() => expect(f.upstream.clients.size).toBe(0))
})

it('rejects oversized messages and tears down both ends', async () => {
  const f = await fixture()
  const client = f.connect(); await once(client, 'open')
  const closed = once(client, 'close'); client.send(Buffer.alloc(GPU_MAX_MESSAGE + 1)); await closed
  await vi.waitFor(() => expect(f.upstream.clients.size).toBe(0))
})

it('fails closed when the guest negotiates the wrong protocol', async () => {
  const f = await fixture('binary')
  const client = f.connect()
  const closed = once(client, 'close')
  await closed
  await vi.waitFor(() => expect(f.upstream.clients.size).toBe(0))
})

it('drops executor connections during normal host shutdown', async () => {
  const f = await fixture()
  const client = f.connect(); await once(client, 'open')
  const reply = once(client, 'message'); client.send(Buffer.from([1])); await reply
  const closed = once(client, 'close')
  await f.shutdown()
  await closed
  await vi.waitFor(() => expect(f.upstream.clients.size).toBe(0))
  expect(f.park).toHaveBeenCalledOnce()
})

it('fences a paired phone to its computer and closes its live GPU connection on revocation', async () => {
  const f = await fixture()
  const { phone, token } = await f.phones.mint('owner', 'Synthetic phone')
  const headers = { authorization: `Bearer ${token}` }
  expect(await refused(f.connect('/v1/computers/owner/gpu', GPU_PROTOCOL, headers))).toBe(403)
  const client = f.connect('/v1/gpu', GPU_PROTOCOL, headers)
  await once(client, 'open')
  const reply = once(client, 'message'); client.send(Buffer.from([1])); await reply
  const closed = once(client, 'close')
  const response = await fetch(`${f.base}/v1/computers/owner/phones/${phone.id}`, {
    method: 'DELETE', headers: { authorization: 'Bearer owner-token' },
  })
  expect(response.status).toBe(200)
  await closed
  await vi.waitFor(() => expect(f.upstream.clients.size).toBe(0))
  expect(await refused(f.connect('/v1/gpu', GPU_PROTOCOL, headers))).toBe(401)
})

it('revokes a phone while its executor upgrade is waiting for interactive readiness', async () => {
  const f = await fixture(GPU_PROTOCOL, true)
  const { phone, token } = await f.phones.mint('owner', 'Synthetic phone')
  let ready!: () => void
  const waiting = new Promise<void>(resolve => { ready = resolve })
  f.promote.mockImplementationOnce(async () => { await waiting; return f.controller.wake() })
  const client = f.connect('/v1/gpu', GPU_PROTOCOL, { authorization: `Bearer ${token}` })
  const closed = new Promise(resolve => client.once('close', resolve))
  try {
    await vi.waitFor(() => expect(f.promote).toHaveBeenCalledOnce())
    expect(await refused(f.connect())).toBe(409)
    const response = await fetch(`${f.base}/v1/computers/owner/phones/${phone.id}`, {
      method: 'DELETE', headers: { authorization: 'Bearer owner-token' },
    })
    expect(response.status).toBe(200)
    await closed
    expect(f.requests).toHaveLength(0)
  } finally { ready() }
  await new Promise(resolve => setImmediate(resolve))
  expect(f.requests).toHaveLength(0)
})


it('preserves a real broker normal-close receipt through the authenticated relay', async () => {
  const f = await fixture()
  const client = f.connect()
  await once(client, 'open')
  const reply = once(client, 'message'); client.send(Buffer.from([1])); await reply
  const closed = once(client, 'close')
  const upstream = [...f.upstream.clients][0]!
  upstream.close(1000)
  expect((await closed)[0]).toBe(1000)
  await vi.waitFor(() => expect(f.upstream.clients.size).toBe(0))
})
