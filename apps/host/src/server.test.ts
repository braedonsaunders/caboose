import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { ActivityService, ActivityStore } from './activities.js'
import { PushDevices, PushService } from './push.js'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { WebSocket, WebSocketServer } from 'ws'
import { afterEach, expect, it, vi } from 'vitest'
import { AgentNotFoundError, START_SCRIPT, REPLY_SCRIPT } from './agents.js'
import { AgentRegistry } from './registry.js'
import { createCabooseServer, type Controller } from './server.js'
import { SettingsStore, settingsLimits } from './settings.js'
import { describeHost } from './host-info.js'
import { config } from './config.js'

const close: Array<() => Promise<void>> = []
afterEach(async () => { for (const f of close.splice(0)) await f() })

it('authenticates routes and relays binary websocket messages while holding a lease', async () => {
  const upstream = new WebSocketServer({ port: 0 })
  await once(upstream, 'listening')
  close.push(() => new Promise(resolve => upstream.close(() => resolve())))
  upstream.on('connection', socket => socket.on('message', (data, binary) => socket.send(data, { binary })))
  const wake = vi.fn(async () => ({ state: 'running', display: { path: '/v1/display', token: 'display', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }))
  const park = vi.fn(async () => {})
  const controller: Controller = { wake, park, activeResources: () => null, hasSavedState: () => false, stats: () => ({ ok: true }), apps: async () => [], launch: async () => {}, displayUrl: `ws://127.0.0.1:${(upstream.address() as AddressInfo).port}`, agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => undefined }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 50, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const machine = { memoryMb: 32768, availableMemoryMb: 20480, cpus: 16, disk: null }
  const app = createCabooseServer({ token: 'owner', settings, controller, machine: async () => machine })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.push(() => new Promise(resolve => app.server.close(() => resolve())))
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  expect((await fetch(`${base}/v1/health`)).status).toBe(401)
  expect(await (await fetch(`${base}/v1/health`, { headers: { authorization: 'Bearer owner' } })).json()).toEqual({ ok: true, machine })
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
  const background = new WebSocket(base.replace('http:', 'ws:') + '/v1/control?foreground=0', { headers: { authorization: 'Bearer owner' } })
  await once(background, 'open')
  const backgroundClosed = once(background, 'close')
  await vi.waitFor(() => expect(park).toHaveBeenCalledTimes(1))
  await backgroundClosed
})

it('routes agent replies, approvals, files and links with the right status codes', async () => {
  const display = new WebSocketServer({ port: 0 })
  await once(display, 'listening')
  close.push(() => new Promise(resolve => display.close(() => resolve())))
  const fileServer = createServer((req, res) => {
    req.resume()
    req.on('end', () => { res.writeHead(201, { 'content-type': 'application/json' }); res.end('{}') })
  })
  fileServer.listen(0, '127.0.0.1')
  await once(fileServer, 'listening')
  close.push(() => new Promise(resolve => fileServer.close(() => resolve())))
  const runs: string[][] = []
  const transcripts = new Map<string, string>()
  const launch = vi.fn(async (_id: string, _path?: string, _action?: string) => {})
  const guest = { ownerEnv: ['DISPLAY=:110'], run: async (command: string, args: string[]) => {
    runs.push([command, ...args])
    if (args.includes('/opt/caboose/a11y.py')) return '0\n{"elements":[]}'
    if (command === '/usr/bin/python3' && args[2] === 'list') return '{}'
    // This route fixture models a runner that immediately claims admitted prompts.
    // Durable delivery now asks for that evidence before draining queued replies.
    if (args[5] === START_SCRIPT) transcripts.set(args[7]!, JSON.stringify({ type: 'user', turn: 1, text: args[8] }))
    if (args[5] === REPLY_SCRIPT) {
      transcripts.set(args[7]!, (transcripts.get(args[7]!) ?? '') + '\n' + JSON.stringify({ type: 'user', turn: Number(args[9]), text: 'claimed reply' }))
      return 'claimed'
    }
    if (args[8]?.startsWith('// caboose delivery evidence')) return JSON.stringify({ journal: '', receipt: '', receiptExists: false, inbox: '', published: '', transcript: transcripts.get(args[7]!) ?? '', alive: true })
    return args[5]?.includes('while [ -e "$target" ]') ? '/home/caboose/Downloads/a.txt' : ''
  } }
  const session = { state: 'running', display: { path: '/v1/display', token: 'd', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }
  const wake = vi.fn(async () => session), promote = vi.fn(async () => session)
  const controller: Controller = { wake, promote,
    park: async () => {}, activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch,
    displayUrl: `ws://127.0.0.1:${(display.address() as AddressInfo).port}`, agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => guest,
    fileService: () => ({ url: `http://127.0.0.1:${(fileServer.address() as AddressInfo).port}`, token: 'test' }) }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: 'claude-acp' }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const registry = new AgentRegistry({ fetch: (async () => new Response(await readFile(new URL('./fixtures/acp-registry.json', import.meta.url)))) as unknown as typeof fetch })
  const app = createCabooseServer({ token: 'owner', settings, controller, registry })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.push(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const post = (path: string, body: unknown) => fetch(base + path, { method: 'POST', headers: { authorization: 'Bearer owner' }, body: JSON.stringify(body) })
  const missing = '11111111-1111-4111-8111-111111111111'
  const headlessTask = await post('/v1/agent/tasks', { prompt: 'headless' })
  expect(headlessTask.status).toBe(200)
  expect(wake).toHaveBeenCalledWith('headless')
  expect(promote).not.toHaveBeenCalled()
  expect((await post(`/v1/agent/tasks/${missing}/reply`, { prompt: 'x' })).status).toBe(404)
  const displayClient = new WebSocket(base.replace('http:', 'ws:') + '/v1/display', 'binary', { headers: { authorization: 'Bearer owner' } })
  const [opened, launched, uploaded, screen] = await Promise.all([
    post('/v1/open', { url: 'https://example.com' }),
    post('/v1/apps/firefox.desktop/launch', {}),
    post('/v1/files', { name: 'open.txt', data: 'aGk=', open: true }),
    fetch(base + '/v1/screen/elements', { headers: { authorization: 'Bearer owner' } }),
    once(displayClient, 'open'),
  ])
  expect(opened.status).toBe(200)
  expect(launched.status).toBe(200)
  expect(uploaded.status).toBe(200)
  expect(screen.status).toBe(200)
  expect(promote).toHaveBeenCalledOnce()
  displayClient.close()
  await once(displayClient, 'close')
  expect(await (await post('/v1/files', { name: 'a.txt', data: 'aGk=' })).json()).toEqual({ path: '/home/caboose/Downloads/a.txt' })
  await post('/v1/session', {})
  expect(promote).toHaveBeenCalledOnce()
  expect((await post('/v1/fs/open', { path: 'Documents/a.psd', app: 'ai.storyteller.photocraft.desktop' })).status).toBe(200)
  expect(launch).toHaveBeenCalledWith('ai.storyteller.photocraft.desktop', 'Documents/a.psd')
  expect((await post('/v1/fs/open', { path: '../bad', app: 'a.desktop' })).status).toBe(400)
  expect((await post('/v1/fs/open', { path: 'a', app: '../bad.desktop' })).status).toBe(400)
  expect((await fetch(base + '/v1/apps/firefox.desktop/desktop-shortcut', { method: 'POST' })).status).toBe(401)
  const shortcut = await post('/v1/apps/firefox.desktop/desktop-shortcut', {})
  expect(shortcut.status).toBe(201)
  expect(await shortcut.json()).toEqual({ path: 'Desktop/firefox.desktop' })
  expect((await post('/v1/apps/bad%2Fid.desktop/desktop-shortcut', {})).status).toBe(400)
  // A launch takes no body, or { action } naming one of the entry's desktop actions.
  expect((await fetch(base + '/v1/apps/firefox.desktop/launch', { method: 'POST', headers: { authorization: 'Bearer owner' } })).status).toBe(200)
  expect(launch).toHaveBeenLastCalledWith('firefox.desktop', undefined, undefined)
  expect((await post('/v1/apps/firefox.desktop/launch', { action: 'new-private-window' })).status).toBe(200)
  expect(launch).toHaveBeenLastCalledWith('firefox.desktop', undefined, 'new-private-window')
  launch.mockClear()
  for (const action of ['new window', '../x', '', 'a'.repeat(65), 7]) expect((await post('/v1/apps/firefox.desktop/launch', { action })).status).toBe(400)
  expect(launch).not.toHaveBeenCalled()
  launch.mockRejectedValueOnce(new AgentNotFoundError('Application action not found'))
  const unknown = await post('/v1/apps/firefox.desktop/launch', { action: 'missing' })
  expect(unknown.status).toBe(404)
  expect(await unknown.json()).toEqual({ error: 'Application action not found' })
  expect((await post(`/v1/agent/tasks/${missing}/reply`, { prompt: 'x' })).status).toBe(404)
  expect((await post(`/v1/agent/tasks/${missing}/approvals/${missing}`, { allow: true })).status).toBe(404)
  const { id } = await (await post('/v1/agent/tasks', { prompt: 'hi' })).json() as { id: string }
  // A reply to a working agent waits for its turn to end.
  expect(await (await post(`/v1/agent/tasks/${id}/reply`, { prompt: 'more' })).json()).toMatchObject({ task: { id, status: 'running', queued: ['more'] } })
  // Replies accept the same attachment body size as task start, beyond the ordinary 64 KiB limit.
  const attached = await post(`/v1/agent/tasks/${id}/reply`, { prompt: 'read this', attachments: [{ name: 'notes.txt', type: 'text/plain', data: Buffer.alloc(70_000, 65).toString('base64') }] })
  expect(attached.status).toBe(200)
  expect(await attached.json()).toMatchObject({ task: { queued: ['more', 'read this'], queuedAttachments: [[], [expect.stringContaining('/notes.txt')]] } })
  expect((await post(`/v1/agent/tasks/${missing}/send-now`, {})).status).toBe(404)
  expect(await (await post(`/v1/agent/tasks/${id}/send-now`, {})).json()).toMatchObject({ task: { turns: 2, status: 'running' } })
  expect((await post(`/v1/agent/tasks/${id}/send-now`, {})).status).toBe(409)
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


it('exposes authenticated push registration and capability only when configured', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-push-api-'))
  close.push(() => rm(root, { recursive: true, force: true }))
  const devices = await PushDevices.open(join(root, 'devices.json'))
  const push = new PushService(devices, { send: async () => ({ status: 200 }) })
  const controller: Controller = { wake: async () => { throw new Error('not used') }, park: async () => {}, activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => undefined }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller, push })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.unshift(() => new Promise(resolve => app.server.close(() => resolve())))
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const request = (method: string, body: object, auth = true) => fetch(base + '/v1/devices/push', { method, headers: { ...(auth ? { authorization: 'Bearer owner' } : {}), 'content-type': 'application/json' }, body: JSON.stringify(body) })
  const device = { token: 'ab'.repeat(32), environment: 'sandbox', kinds: ['approval'] }
  expect((await request('POST', device, false)).status).toBe(401)
  expect((await request('POST', { ...device, environment: 'other' })).status).toBe(400)
  expect((await request('POST', device)).status).toBe(200)
  expect(devices.list()).toEqual([device])
  expect(await (await fetch(base + '/v1/computer', { headers: { authorization: 'Bearer owner' } })).json()).toMatchObject({ capabilities: { push: true } })
  const listed = await fetch(base + '/v1/devices/push', { headers: { authorization: 'Bearer owner' } })
  expect(listed.status).toBe(200)
  const { devices: summaries } = await listed.json() as { devices: Array<{ id: string }> }
  expect(summaries).toEqual([{ id: expect.stringMatching(/^[0-9a-f]{16}$/), environment: 'sandbox', kinds: ['approval'] }])
  expect(JSON.stringify(summaries)).not.toContain(device.token)
  expect((await fetch(base + '/v1/devices/push')).status).toBe(401)
  const removeById = (id: string, auth = true) => fetch(`${base}/v1/devices/push/${id}`, { method: 'DELETE', headers: auth ? { authorization: 'Bearer owner' } : {} })
  expect((await removeById(summaries[0]!.id, false)).status).toBe(401)
  expect((await removeById('nope')).status).toBe(400)
  expect((await removeById('0'.repeat(16))).status).toBe(404)
  expect((await removeById(summaries[0]!.id)).status).toBe(200)
  expect(devices.list()).toEqual([])
  expect((await request('POST', device)).status).toBe(200)
  expect((await request('DELETE', { token: device.token })).status).toBe(200)
  expect(devices.list()).toEqual([])
})

it('lists push devices only when push is configured, and describes the host when told how it started', async () => {
  const controller: Controller = { wake: async () => { throw new Error('not used') }, park: async () => {}, activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => undefined }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const env = { CABOOSE_OWNER_TOKEN: 'owner-secret-token', CABOOSE_RUNTIME: 'container', CABOOSE_GPU: 'none' }
  const host = describeHost(config(env), env, { push: false, liveActivities: false })
  const app = createCabooseServer({ token: 'owner', settings, controller, host })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.unshift(() => new Promise(resolve => app.server.close(() => resolve())))
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const get = (path: string, auth = true) => fetch(base + path, { headers: auth ? { authorization: 'Bearer owner' } : {} })
  expect((await get('/v1/devices/push')).status).toBe(503)
  expect((await get('/v1/host', false)).status).toBe(401)
  const described = await (await get('/v1/host')).json()
  expect(described).toMatchObject({ runtime: 'container', gpu: 'none', image: 'caboose-computer:latest', push: false })
  expect(JSON.stringify(described)).not.toContain('owner-secret-token')
})


it('routes Live Activity registrations and distinguishes foreground app sockets', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-activity-api-'))
  close.push(() => rm(root, { recursive: true, force: true }))
  const store = await ActivityStore.open(join(root, 'activities.json'))
  const send = vi.fn(async () => ({ status: 200 }))
  const activities = new ActivityService(store, send, 'example.app')
  const controller: Controller = { wake: async () => ({ state: 'running', display: { path: '/v1/display', token: 'x', protocol: 'caboose-display' }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }), park: async () => {}, activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => undefined }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller, activities })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  close.unshift(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const request = (path: string, method: string, body?: object) => fetch(base + path, { method, headers: { authorization: 'Bearer owner', 'content-type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) })
  const starter = { token: 'ab'.repeat(32), environment: 'sandbox', deviceId: 'cd'.repeat(32) }
  expect((await request('/v1/activities/start-token', 'POST', starter)).status).toBe(200)
  expect((await request('/v1/activities', 'POST', { token: 'bad', environment: 'sandbox' })).status).toBe(400)
  await request('/v1/session', 'POST')
  const client = new WebSocket(base.replace('http:', 'ws:') + '/v1/control?foreground=1', { headers: { authorization: 'Bearer owner' } })
  await once(client, 'open')
  const job = { id: 'job-1', kind: 'install', title: 'Install', status: 'running', detail: 'Installing' }
  expect((await request('/v1/jobs/activity', 'POST', { start: true, job })).status).toBe(200)
  expect(send).not.toHaveBeenCalled()
  client.close(); await once(client, 'close')
  await vi.waitFor(async () => {
    const status = await (await request('/v1/computer', 'GET')).json() as { clients: { control: number } }
    expect(status.clients.control).toBe(0)
  })
  expect((await request('/v1/jobs/activity', 'POST', { start: true, job })).status).toBe(200)
  expect(send).toHaveBeenCalledOnce()
  expect((await request('/v1/activities/start-token', 'DELETE', { deviceId: starter.deviceId })).status).toBe(200)
  expect(store.list().starters).toEqual([])
})

it('serves the catalog and serializes authenticated application operations', async () => {
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  const guest = { run: async (_command: string, args: string[]) => { if (args[2] === 'list') return '{"apps":{}}'; if (args[1]?.includes('AppStream.Pool.new')) return '[]'; await gate; return '' } }
  const controller: Controller = { wake: async () => ({ state: 'running', display: { path: '/v1/display', token: 'd', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }), park: async () => {}, activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => guest }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening'); close.push(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const req = (path: string, method = 'GET') => fetch(base + path, { method, headers: { authorization: 'Bearer owner' } })
  expect((await fetch(base + '/v1/catalog')).status).toBe(401)
  await req('/v1/session', 'POST')
  const list = await (await req('/v1/catalog')).json() as { apps: { id: string }[] }
  expect(list.apps.some(a => a.id === 'gridcraft')).toBe(true)
  expect((await req('/v1/catalog/packs/creative-studio/install', 'POST')).status).toBe(404)
  expect((await req('/v1/catalog/no-such-app/install', 'POST')).status).toBe(404)
  expect((await req('/v1/catalog/gimp/install', 'POST')).status).toBe(202)
  expect((await req('/v1/catalog/krita/install', 'POST')).status).toBe(409)
  expect((await req('/v1/catalog/gimp/rollback', 'POST')).status).toBe(404)
  expect((await req('/v1/session/park', 'POST')).status).toBe(409)
  finish()
  await vi.waitFor(async () => { const result = await (await req('/v1/catalog')).json() as { apps: { id: string; progress: { phase: string } }[] }; expect(result.apps.find(a => a.id === 'gimp')?.progress.phase).toBe('finished') })
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
  const controller: Controller = { wake: async () => ({ state: 'running', display: { path: '/v1/display', token: 'd', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }),
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

it('runs only a whitelisted installed Craft app and publishes job progress', async () => {
  const job = '0123456789abcdef0123456789abcdef'
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  const guest = { run: vi.fn(async (_command: string, args: string[]) => {
    if (args[2] === 'list') return JSON.stringify({ apps: { photocraft: { installedVersion: '0.16.0', lastError: null, interrupted: false } }, environment: {} })
    if (args[0] === '-c' && args[1]?.includes('Run one host-whitelisted')) { await gate; return JSON.stringify({ outputs: [`.caboose-jobs/${job}/output-0.png`] }) }
    return ''
  }) }
  const controller: Controller = { wake: async () => ({ state: 'running', display: { path: '/v1/display', token: 'd', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }), park: async () => {}, activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: '', agentDisplayUrl: '', ensureAgentSeat: async () => {}, guest: () => guest }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening')
  close.push(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const post = (path: string, body: unknown, auth = true) => fetch(base + path, { method: 'POST', headers: auth ? { authorization: 'Bearer owner' } : {}, body: JSON.stringify(body) })
  const input = { job, inputs: ['input-0.jpg'], format: 'png' }
  expect((await post('/v1/catalog/photocraft/run', input, false)).status).toBe(401)
  expect((await post('/v1/catalog/photocraft/run', { ...input, inputs: ['../../etc'] })).status).toBe(400)
  await post('/v1/session', {})
  const socket = new WebSocket(base.replace('http:', 'ws:') + '/v1/control', { headers: { authorization: 'Bearer owner' } })
  await once(socket, 'open')
  const events: Array<{ type?: string; job?: { status?: string } }> = []
  socket.on('message', raw => { try { events.push(JSON.parse(raw.toString())) } catch {} })
  const pending = post('/v1/catalog/photocraft/run', input)
  await vi.waitFor(() => expect(events.some(e => e.type === 'job.progress' && e.job?.status === 'running')).toBe(true))
  expect((await post('/v1/session/park', {})).status).toBe(409)
  expect((await post('/v1/catalog/photocraft/run', input)).status).toBe(409)
  expect((await fetch(base + '/v1/apps', { headers: { authorization: 'Bearer owner' } })).status).toBe(200)
  finish()
  const response = await pending
  expect(response.status).toBe(200)
  expect(await response.json()).toEqual({ job, outputs: [`.caboose-jobs/${job}/output-0.png`], warnings: [] })
  await vi.waitFor(() => expect(events.filter(e => e.type === 'job.progress').map(e => e.job?.status)).toEqual(['running', 'succeeded']))
  socket.close(); await once(socket, 'close')
})

it('serves the MCP Library to an authorized client without ever returning its keys', async () => {
  const { SmitheryCatalog } = await import('./smithery.js')
  const { listing } = await import('./smithery.test.js')
  const dir = await mkdtemp(join(tmpdir(), 'caboose-mcp-server-'))
  close.push(() => rm(dir, { recursive: true, force: true }))
  const key = 'sk-owner-key-1234'
  const answer = (body: unknown, status = 200) => ({ status, headers: { 'content-type': 'application/json' }, body: Buffer.from(JSON.stringify(body)) })
  const request = vi.fn(async (url: string, _max: number, init: { method?: string; body?: string } = {}) => {
    const parsed = new URL(url)
    if (parsed.hostname === 'registry.smithery.ai') return parsed.pathname === '/servers' ? answer({ servers: [listing('brave', 900)], pagination: { totalCount: 1 } }) : answer({ ...listing('brave', 900), tools: [] })
    if (parsed.pathname === '/namespaces') return answer({ namespaces: [{ name: 'space' }], pagination: {} })
    if (parsed.pathname === '/tokens') return answer({ token: 'svc-scoped-token-1', expiresAt: '2999-01-01T00:00:00Z' })
    if (parsed.pathname.endsWith('/mcp')) { const body = JSON.parse(init.body!); return answer({ jsonrpc: '2.0', id: body.id, result: body.method === 'initialize' ? {} : { tools: [{ name: 'search' }] } }) }
    if (init.method === 'PUT') return answer({ connectionId: 'x', name: 'Brave', mcpUrl: 'https://brave.run.tools', metadata: JSON.parse(init.body!).metadata, status: { state: 'connected' } }, 201)
    return answer({ error: 'not found' }, 404)
  })
  const controller: Controller = { wake: async () => ({ state: 'running', display: { path: '/v1/display', token: 'd', protocol: 'caboose-display' as const }, computer: { name: 'Caboose', image: 'Debian', memoryMb: 2048, vcpus: 2 } }), park: async () => {}, activeResources: () => null, hasSavedState: () => false, stats: () => ({}), apps: async () => [], launch: async () => {}, displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => undefined }
  const settings = new SettingsStore({ name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 60_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
  const app = createCabooseServer({ token: 'owner', settings, controller, mcpLibraryFile: join(dir, 'mcp-library.json'),
    library: { mcp: { catalog: new SmitheryCatalog(join(dir, 'catalog'), request as never), hostId: '0123456789abcdef', request: request as never } } })
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening'); close.push(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const req = (path: string, method = 'GET', body?: unknown) => fetch(base + path, { method, headers: { authorization: 'Bearer owner' }, ...(body ? { body: JSON.stringify(body) } : {}) })
  expect((await fetch(base + '/v1/mcp/account')).status).toBe(401)
  expect(await (await req('/v1/mcp/account')).json()).toEqual({ connected: false, namespace: null, disconnecting: false })
  expect((await req('/v1/mcp/connections', 'POST', { server: 'brave' })).status).toBe(409)
  expect(await (await req('/v1/mcp/account', 'PUT', { apiKey: key })).json()).toEqual({ connected: true, namespace: 'space', disconnecting: false })
  const storefront = await (await req('/v1/mcp/storefront')).json() as { groups: Array<{ id: string; servers: Array<Record<string, unknown>> }> }
  expect(storefront.groups[0]?.servers[0]).toMatchObject({ id: 'brave', uses: 900, connection: null })
  expect(storefront.groups[0]?.servers[0]).not.toHaveProperty('iconUrl')
  const added = await (await req('/v1/mcp/connections', 'POST', { server: 'brave' })).json() as { id: string; status: unknown }
  expect(added.status).toEqual({ state: 'connected', tools: 1 })
  expect((await (await req('/v1/mcp/discover?q=brave')).json() as { servers: Array<{ connection: string }> }).servers[0]?.connection).toBe(added.id)
  const everything = [await (await req('/v1/mcp/connections')).text(), await (await req('/v1/mcp/account')).text(), await (await req('/v1/mcp/storefront')).text()].join()
  expect(everything).not.toContain(key)
  expect(everything).not.toContain('svc-scoped-token-1')
  expect((await req('/v1/mcp/connections/not-an-id', 'DELETE')).status).toBe(404)
  expect((await req('/v1/mcp/icons/../../etc')).status).toBe(404)
  expect((await req('/v1/mcp/discover?page=x')).status).toBe(400)
  expect(await readFile(join(dir, 'mcp-library.json'), 'utf8')).toContain(key)
})
