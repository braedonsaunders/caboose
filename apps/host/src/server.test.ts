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

it('relays phone events only to authenticated phone controls and serves staged files', async () => {
  let drains = 0
  const id = 'a'.repeat(32)
  const event = { type: 'phone.share', id, path: `/home/caboose/.cache/caboose/phone/files/${id}`, name: 'test.txt', size: 3, contentType: 'text/plain' }
  const guest = { run: vi.fn(async (_command: string, args: string[]) => {
    if (args.includes('drain')) { drains++; return JSON.stringify(drains === 1 ? [event] : []) }
    if (args.includes('info')) return '3'
    if (args.includes('read')) return 'YWJj'
    return ''
  }) }
  const controller: Controller = { wake: async () => ({ state: 'running', display: { path: '/v1/display', token: 'd', protocol: 'xpra-ws' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }),
    park: async () => {}, activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch: async () => {},
    displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => guest }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  close.push(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const auth = { authorization: 'Bearer owner' }
  expect((await fetch(`${base}/v1/phone/files/${id}`)).status).toBe(401)
  expect((await fetch(`${base}/v1/session`, { method: 'POST', headers: auth })).status).toBe(200)
  const control = new WebSocket(base.replace('http:', 'ws:') + '/v1/control', { headers: auth })
  const seen: unknown[] = []
  control.on('message', data => seen.push(JSON.parse(String(data))))
  await once(control, 'open')
  await new Promise(resolve => setTimeout(resolve, 50))
  expect(drains).toBe(0)
  const phone = new WebSocket(base.replace('http:', 'ws:') + '/v1/control?phone=1', { headers: auth })
  const received: unknown[] = []
  phone.on('message', data => received.push(JSON.parse(String(data))))
  await once(phone, 'open')
  await vi.waitFor(() => expect(received).toContainEqual(event))
  expect(seen).not.toContainEqual(event)
  expect(await (await fetch(`${base}/v1/phone/files/${id}`, { headers: auth })).json()).toEqual({ data: 'YWJj' })
  expect((await fetch(`${base}/v1/phone/files/bad`, { headers: auth })).status).toBe(400)
  phone.close(); control.close()
  await Promise.all([once(phone, 'close'), once(control, 'close')])
})
