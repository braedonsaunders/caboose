import { once } from 'node:events'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterEach, expect, it, vi } from 'vitest'
import { WebSocket } from 'ws'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'

const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const close of cleanup.splice(0)) await close() })

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
    wake: async () => { wakes++; return { state: 'running', display: { path: '/v1/display', token: '', protocol: 'xpra-ws' }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } } },
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
    wake: async () => ({ state: 'running', display: { path: '/v1/display', token: '', protocol: 'xpra-ws' }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }),
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
