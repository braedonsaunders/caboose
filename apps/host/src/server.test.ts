import { once } from 'node:events'
import type { AddressInfo } from 'node:net'
import { WebSocket, WebSocketServer } from 'ws'
import { afterEach, expect, it, vi } from 'vitest'
import { createCabooseServer, type Controller } from './server.js'

const close: Array<() => Promise<void>> = []
afterEach(async () => { for (const f of close.splice(0)) await f() })

it('authenticates routes and relays binary websocket messages while holding a lease', async () => {
  const upstream = new WebSocketServer({ port: 0 })
  await once(upstream, 'listening')
  close.push(() => new Promise(resolve => upstream.close(() => resolve())))
  upstream.on('connection', socket => socket.on('message', (data, binary) => socket.send(data, { binary })))
  const wake = vi.fn(async () => ({ state: 'running', display: { path: '/v1/display', token: 'display', protocol: 'xpra-ws' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }))
  const park = vi.fn(async () => {})
  const controller: Controller = { wake, park, stats: () => ({ ok: true }), apps: async () => [], launch: async () => {}, displayUrl: `ws://127.0.0.1:${(upstream.address() as AddressInfo).port}`, agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => undefined }
  const app = createCabooseServer({ token: 'owner', idleMs: 50, controller })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.push(() => new Promise(resolve => app.server.close(() => resolve())))
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  expect((await fetch(`${base}/v1/health`)).status).toBe(401)
  expect((await fetch(`${base}/v1/session`, { method: 'POST', headers: { authorization: 'Bearer owner' } })).status).toBe(200)
  const client = new WebSocket(base.replace('http:', 'ws:') + '/v1/display', 'binary', { headers: { authorization: 'Bearer owner' } })
  await once(client, 'open')
  expect(client.protocol).toBe('binary')
  client.send(Buffer.from([1, 2, 3]))
  const [data, isBinary] = await once(client, 'message')
  expect(isBinary).toBe(true)
  expect(data).toEqual(Buffer.from([1, 2, 3]))
  await new Promise(resolve => setTimeout(resolve, 90))
  expect(park).not.toHaveBeenCalled()
  client.close()
  await once(client, 'close')
  await vi.waitFor(() => expect(park).toHaveBeenCalledTimes(1))
})
