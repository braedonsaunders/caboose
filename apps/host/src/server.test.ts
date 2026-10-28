import { once } from 'node:events'
import { readFile } from 'node:fs/promises'
import type { AddressInfo } from 'node:net'
import { WebSocket, WebSocketServer } from 'ws'
import { afterEach, expect, it, vi } from 'vitest'
import { AgentRegistry } from './registry.js'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'

const close: Array<() => Promise<void>> = []
afterEach(async () => { for (const f of close.splice(0)) await f() })

it('authenticates routes and relays binary websocket messages while holding a lease', async () => {
  const upstream = new WebSocketServer({ port: 0 })
  await once(upstream, 'listening')
  close.push(() => new Promise(resolve => upstream.close(() => resolve())))
  upstream.on('connection', socket => socket.on('message', (data, binary) => socket.send(data, { binary })))
  const wake = vi.fn(async () => ({ state: 'running', display: { path: '/v1/display', token: 'display', protocol: 'xpra-ws' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }))
  const park = vi.fn(async () => {})
  const controller: Controller = { wake, park, activeResources: () => null, hasSavedState: () => false, stats: () => ({ ok: true }), apps: async () => [], launch: async () => {}, displayUrl: `ws://127.0.0.1:${(upstream.address() as AddressInfo).port}`, agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => undefined }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 50, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
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

it('routes agent replies, approvals, files and links with the right status codes', async () => {
  const runs: string[][] = []
  const guest = { run: async (command: string, args: string[]) => {
    runs.push([command, ...args])
    return args[5]?.includes('while [ -e "$target" ]') ? '/home/caboose/Downloads/a.txt' : ''
  } }
  const controller: Controller = { wake: async () => ({ state: 'running', display: { path: '/v1/display', token: 'd', protocol: 'xpra-ws' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }),
    park: async () => {}, activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch: async () => {},
    displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => guest }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: 'claude-acp' }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const registry = new AgentRegistry({ fetch: (async () => new Response(await readFile(new URL('./fixtures/acp-registry.json', import.meta.url)))) as unknown as typeof fetch })
  const app = createCabooseServer({ token: 'owner', settings, controller, registry })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.push(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const post = (path: string, body: unknown) => fetch(base + path, { method: 'POST', headers: { authorization: 'Bearer owner' }, body: JSON.stringify(body) })
  const missing = '11111111-1111-4111-8111-111111111111'
  expect((await post(`/v1/agent/tasks/${missing}/reply`, { prompt: 'x' })).status).toBe(409)
  expect(await (await post('/v1/files', { name: 'a.txt', data: 'aGk=' })).json()).toEqual({ path: '/home/caboose/Downloads/a.txt' })
  await post('/v1/session', {})
  expect((await post(`/v1/agent/tasks/${missing}/reply`, { prompt: 'x' })).status).toBe(404)
  expect((await post(`/v1/agent/tasks/${missing}/approvals/${missing}`, { allow: true })).status).toBe(404)
  const { id } = await (await post('/v1/agent/tasks', { prompt: 'hi' })).json() as { id: string }
  expect((await post(`/v1/agent/tasks/${id}/reply`, { prompt: 'more' })).status).toBe(409)
  expect((await post(`/v1/agent/tasks/${id}/approvals/${missing}`, { allow: 'yes' })).status).toBe(400)
  expect(await (await post(`/v1/agent/tasks/${id}/approvals/${missing}`, { allow: true })).json()).toEqual({ resolved: false })
  expect((await post('/v1/agent/tasks', { prompt: 'x', agent: 'codex', approvals: 'sometimes' })).status).toBe(400)
  expect((await post('/v1/agent/tasks', { prompt: 'x', agent: 'no-such-agent' })).status).toBe(404)
  expect((await post('/v1/agent/tasks', { prompt: 'x', agent: 'codex', approvals: 'ask' })).status).toBe(200)
  expect(await (await post('/v1/files', { name: 'a.txt', data: 'aGk=' })).json()).toEqual({ path: '/home/caboose/Downloads/a.txt' })
  expect((await post('/v1/open', { url: 'file:///etc/passwd' })).status).toBe(400)
  expect(await (await post('/v1/open', { url: 'https://example.com' })).json()).toEqual({ opened: true })
  expect(runs.at(-1)?.at(-1)).toBe('https://example.com/')
})
