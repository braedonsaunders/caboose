import { once } from 'node:events'
import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo } from 'node:net'
import { WebSocket, WebSocketServer } from 'ws'
import { afterEach, expect, it, vi } from 'vitest'
import { ComputerRegistry, PhoneTokens, type ComputerRecord } from './computers.js'
import { PushDevices, PushService } from './push.js'
import { createCabooseServer, STANDALONE_COMPUTER, type ComputerPieces, type Controller } from './server.js'
import { SettingsStore, settingsLimits, type ComputerSettings } from './settings.js'

const close: Array<() => Promise<void>> = []
afterEach(async () => { for (const f of close.splice(0).reverse()) await f() })

/** A computer that wakes at once and records what was asked of it. */
function fakeController(id: string, displayUrl = 'ws://127.0.0.1:1') {
  const calls: string[] = []
  const controller: Controller = {
    wake: async () => { calls.push('wake'); return { state: 'running', display: { path: '/v1/display', token: `display-${id}`, protocol: 'caboose-display' }, computer: { name: id, image: 'Debian 13', memoryMb: 2048, vcpus: 2 } } },
    park: async () => { calls.push('park') },
    destroy: async () => { calls.push('destroy') },
    activeResources: () => null, hasSavedState: () => false, stats: () => ({ host: 'caboose-host' }),
    apps: async () => [{ id: `${id}.desktop`, name: id, icon: '', categories: [], exec: id, actions: [] }], launch: async () => {},
    displayUrl, agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => undefined,
  }
  return { controller, calls }
}

function memorySettings(value: ComputerSettings): SettingsStore {
  return new SettingsStore(value, settingsLimits(), { load: async () => undefined, save: async () => {} })
}

/** A host with one computer already made (`first`), or none when `empty`. */
async function startHost(gpu = false, small = false, empty = false) {
  const root = await mkdtemp(join(tmpdir(), 'caboose-fleet-'))
  close.push(() => rm(root, { recursive: true, force: true }))
  const echo = new WebSocketServer({ port: 0 })
  await once(echo, 'listening')
  close.push(() => new Promise(resolve => echo.close(() => resolve())))
  echo.on('connection', socket => socket.on('message', (data, binary) => socket.send(data, { binary })))
  const echoUrl = `ws://127.0.0.1:${(echo.address() as AddressInfo).port}`
  const computers = await ComputerRegistry.open(root)
  const phones = PhoneTokens.memory()
  const sent: string[] = []
  const sender = { send: async (message: { token: string }) => { sent.push(message.token); return { status: 200 } } }
  const made = new Map<string, ReturnType<typeof fakeController>>()
  async function open(record: ComputerRecord, initial?: ComputerSettings): Promise<ComputerPieces> {
    const fake = fakeController(record.id, echoUrl)
    made.set(record.id, fake)
    await mkdir(computers.dataDir(record.id), { recursive: true })
    await writeFile(join(computers.dataDir(record.id), 'caboose.json'), '{}')
    const push = new PushService(await PushDevices.open(join(computers.dataDir(record.id), 'push-devices.json')), sender)
    return { settings: memorySettings(initial ?? { name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 600_000, defaultAgent: null }), controller: fake.controller, push }
  }
  const existing: Array<{ record: ComputerRecord; pieces: ComputerPieces }> = []
  if (!empty) {
    const record = await computers.create()
    existing.push({ record, pieces: await open(record) })
  }
  const app = createCabooseServer({ token: 'owner', ...(small ? { machine: async () => ({ memoryMb: 2048, availableMemoryMb: 1024, cpus: 2, disk: null }) } : {}), ...(gpu ? { host: { version: 'test', node: 'test', runtime: 'container' as const, gpu: 'dri' as const, image: 'test', push: false, liveActivities: false, settings: [] } } : {}), fleet: { computers, phones, open, existing, defaults: { memoryMb: 4096, vcpus: 2, idleMs: 600_000 }, maxRunning: 4 } })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.push(() => new Promise(resolve => app.server.close(() => resolve())))
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const call = (path: string, init: Omit<RequestInit, 'body'> & { token?: string; body?: unknown } = {}) => fetch(`${base}${path}`, {
    ...init,
    headers: { authorization: `Bearer ${init.token ?? 'owner'}`, ...(init.body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  })
  return { root, base, call, made, computers, phones, sent, first: existing[0]?.record.id as string }
}

it('lists, makes and serves several computers, each through its own routes', async () => {
  const host = await startHost()
  const listed = await (await host.call('/v1/computers')).json()
  expect(listed).toMatchObject({ canCreate: true, limits: { computers: 32832, running: 4 }, defaultComputer: host.first, computers: [{ id: host.first, state: 'parked', settings: { name: 'Caboose' } }] })

  expect((await host.call('/v1/computers', { method: 'POST', body: { memoryMb: 2048 } })).status).toBe(400)
  expect((await host.call('/v1/computers', { method: 'POST', body: { name: 'Kids', defaultAgent: 'claude' } })).status).toBe(400)
  expect((await host.call('/v1/computers', { method: 'POST', body: { name: 'Kids', memoryMb: 1 } })).status).toBe(400)
  const created = await host.call('/v1/computers', { method: 'POST', body: { name: '  Kids ', vcpus: 3 } })
  expect(created.status).toBe(201)
  const kids = await created.json()
  expect(kids).toMatchObject({ id: expect.stringMatching(/^c-/), state: 'parked', settings: { name: 'Kids', memoryMb: 4096, vcpus: 3 } })
  expect(kids.createdAt).toEqual(expect.any(String))

  expect((await host.call(`/v1/computers/${kids.id}/session`, { method: 'POST' })).status).toBe(200)
  expect(host.made.get(kids.id)!.calls).toEqual(['wake'])
  expect(host.made.get(host.first)!.calls).toEqual([])
  expect(await (await host.call(`/v1/computers/${kids.id}/apps`)).json()).toEqual([expect.objectContaining({ id: `${kids.id}.desktop` })])
  expect((await (await host.call(`/v1/computers/${kids.id}`)).json()).state).toBe('running')
  // The routes without a computer stay the default computer's.
  expect((await (await host.call('/v1/computer')).json()).state).toBe('parked')
  expect((await host.call('/v1/computers/c-ffffffffff/computer')).status).toBe(404)
  expect((await host.call('/v1/computers/c-ffffffffff')).status).toBe(404)

  const after = await (await host.call('/v1/computers')).json()
  expect(after.computers.map((c: { id: string }) => c.id)).toEqual([host.first, kids.id])
})

it('applies presets through creation and settings without changing custom machines', async () => {
  const host = await startHost()
  const status = await (await host.call('/v1/computer')).json()
  expect(status.sizes).toContainEqual({ id: 'gpu', name: 'GPU', memoryMb: 8192, vcpus: 8, available: false })
  expect((await host.call('/v1/computers', { method: 'POST', body: { name: 'GPU', size: 'gpu' } })).status).toBe(400)
  const created = await (await host.call('/v1/computers', { method: 'POST', body: { name: 'Micro', size: 'micro' } })).json()
  expect(created.settings).toMatchObject({ memoryMb: 2048, vcpus: 2 })
  const path = `/v1/computers/${created.id}/computer/settings`
  const resized = await host.call(path, { method: 'PATCH', body: { size: 'standard' } })
  expect((await resized.json()).settings).toMatchObject({ memoryMb: 4096, vcpus: 4 })
  expect((await host.call(path, { method: 'PATCH', body: { size: 'gpu' } })).status).toBe(400)
  expect((await host.call(path, { method: 'PATCH', body: { size: 'micro', vcpus: 5 } })).status).toBe(400)
  expect((await (await host.call(path, { method: 'PATCH', body: { vcpus: 3 } })).json()).settings).toMatchObject({ memoryMb: 4096, vcpus: 3 })
})

it('offers and applies GPU size when container GPU access is enabled', async () => {
  const host = await startHost(true)
  const status = await (await host.call('/v1/computer')).json()
  expect(status.sizes.find((size: { id: string }) => size.id === 'gpu').available).toBe(true)
  const response = await host.call('/v1/computers', { method: 'POST', body: { name: 'GPU', size: 'gpu' } })
  expect(response.status).toBe(201)
  expect((await response.json()).settings).toMatchObject({ memoryMb: 8192, vcpus: 8 })
})

it('rejects a preset larger than the host without altering settings', async () => {
  const host = await startHost(false, true)
  expect((await host.call('/v1/computers', { method: 'POST', body: { name: 'Large', size: 'standard' } })).status).toBe(409)
  expect((await host.call('/v1/computer/settings', { method: 'PATCH', body: { size: 'standard' } })).status).toBe(409)
  expect((await (await host.call('/v1/computer')).json()).settings).toMatchObject({ memoryMb: 2048, vcpus: 2 })
})

it('signs a phone in to one computer only, and signing it out closes what it has open', async () => {
  const host = await startHost()
  const kids = await (await host.call('/v1/computers', { method: 'POST', body: { name: 'Kids' } })).json()
  const issued = await (await host.call(`/v1/computers/${kids.id}/pairing`, { method: 'POST' })).json()
  expect(issued).toEqual({ code: expect.stringMatching(/^[A-Z2-9]{8}$/), expiresAt: expect.any(String) })
  const pair = (body: unknown) => fetch(`${host.base}/v1/pair`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
  expect((await pair({ code: issued.code, deviceName: '' })).status).toBe(400)
  expect((await pair({ code: 'WRONGCOD', deviceName: 'iPad' })).status).toBe(404)
  const paired = await pair({ code: ` ${issued.code.slice(0, 4).toLowerCase()}-${issued.code.slice(4)} `, deviceName: 'iPad' })
  expect(paired.status).toBe(201)
  const minted = await paired.json()
  expect(minted).toEqual({ token: expect.stringMatching(/^cbp_/), scope: 'computer', computer: { id: kids.id, name: 'Kids' } })
  // A code pairs one phone, once.
  expect((await pair({ code: issued.code, deviceName: 'Another' })).status).toBe(404)
  const phone = minted.token as string

  // The phone's own routes are its computer's; host and fleet routes are the owner's alone.
  expect((await host.call('/v1/session', { method: 'POST', token: phone })).status).toBe(200)
  expect(host.made.get(kids.id)!.calls).toEqual(['wake'])
  expect(host.made.get(host.first)!.calls).toEqual([])
  for (const path of ['/v1/health', '/v1/computers', `/v1/computers/${kids.id}`, `/v1/computers/${kids.id}/phones`, `/v1/computers/${kids.id}/pairing`, `/v1/computers/${host.first}/computer`]) {
    expect((await host.call(path, { token: phone })).status, path).toBe(403)
  }
  expect((await host.call('/v1/computer', { token: 'cbp_not-a-token' })).status).toBe(401)
  const chat = '11111111-1111-4111-8111-111111111111'
  expect((await host.call(`/v1/computers/${host.first}/agent/tasks/${chat}`, { method: 'DELETE', token: phone, body: { stop: true } })).status).toBe(403)
  expect(host.made.get(host.first)!.calls).toEqual([])


  // Notifications it registers are its computer's, and go when it is signed out.
  expect((await host.call('/v1/devices/push', { method: 'POST', token: phone, body: { token: 'ab'.repeat(32), environment: 'sandbox', kinds: ['task'] } })).status).toBe(200)
  expect((await (await host.call(`/v1/computers/${kids.id}/devices/push`)).json()).devices).toHaveLength(1)
  expect((await (await host.call('/v1/devices/push')).json()).devices).toHaveLength(0)

  const socket = new WebSocket(`${host.base.replace('http:', 'ws:')}/v1/display`, 'binary', { headers: { authorization: `Bearer ${phone}` } })
  await once(socket, 'open')
  socket.send(Buffer.from([7]))
  expect((await once(socket, 'message'))[0]).toEqual(Buffer.from([7]))

  const listed = await (await host.call(`/v1/computers/${kids.id}/phones`)).json()
  expect(listed.phones).toEqual([expect.objectContaining({ name: 'iPad', lastUsedAt: expect.any(String) })])
  const phoneId = listed.phones[0].id as string
  expect((await host.call(`/v1/computers/${host.first}/phones/${phoneId}`, { method: 'DELETE' })).status).toBe(404)
  const closed = once(socket, 'close')
  expect((await host.call(`/v1/computers/${kids.id}/phones/${phoneId}`, { method: 'DELETE' })).status).toBe(200)
  await closed
  expect((await host.call('/v1/computer', { token: phone })).status).toBe(401)
  expect((await (await host.call(`/v1/computers/${kids.id}/devices/push`)).json()).devices).toHaveLength(0)
})

it('deletes any computer with its disk, files and phones, and moves the default to the next', async () => {
  const host = await startHost()
  const kids = await (await host.call('/v1/computers', { method: 'POST', body: { name: 'Kids' } })).json()
  const { token } = await host.phones.mint(kids.id, 'iPad')
  const { code } = await (await host.call(`/v1/computers/${kids.id}/pairing`, { method: 'POST' })).json()
  const dir = host.computers.dataDir(kids.id)
  expect(existsSync(join(dir, 'caboose.json'))).toBe(true)

  expect((await host.call(`/v1/computers/${kids.id}`, { method: 'DELETE', body: {} })).status).toBe(400)
  const deleted = await host.call(`/v1/computers/${kids.id}`, { method: 'DELETE', body: { confirm: true } })
  expect(deleted.status).toBe(200)
  expect(host.made.get(kids.id)!.calls).toEqual(['destroy'])
  expect(existsSync(dir)).toBe(false)
  expect(host.computers.get(kids.id)).toBeUndefined()
  expect((await host.call(`/v1/computers/${kids.id}`)).status).toBe(404)
  expect((await host.call('/v1/computer', { token })).status).toBe(401)
  expect((await fetch(`${host.base}/v1/pair`, { method: 'POST', body: JSON.stringify({ code, deviceName: 'Late' }) })).status).toBe(404)
  expect((await (await host.call('/v1/computers')).json()).computers.map((c: { id: string }) => c.id)).toEqual([host.first])
  expect(host.made.get(host.first)!.calls).toEqual([])

  // The first computer is nothing special: deleting the default hands it to the next one.
  const next = await (await host.call('/v1/computers', { method: 'POST', body: { name: 'Next' } })).json()
  expect((await host.call(`/v1/computers/${host.first}`, { method: 'DELETE', body: { confirm: true } })).status).toBe(200)
  expect(await (await host.call('/v1/host/settings')).json()).toMatchObject({ defaultComputer: next.id })
  expect((await (await host.call('/v1/computer')).json()).settings.name).toBe('Next')
  expect((await host.call(`/v1/computers/${next.id}`, { method: 'DELETE', body: { confirm: true } })).status).toBe(200)
  expect(await (await host.call('/v1/host/settings')).json()).toMatchObject({ defaultComputer: null })
  expect(await (await host.call('/v1/computer')).json()).toEqual({ error: 'This host has no computer yet; create one', code: 'no-computer' })
})

it('serves a host with no computers, and makes its first computer the default', async () => {
  const host = await startHost(false, false, true)
  expect(await (await host.call('/v1/computers')).json()).toMatchObject({ computers: [], canCreate: true, defaultComputer: null, sizes: expect.arrayContaining([expect.objectContaining({ id: 'micro' })]) })
  for (const path of ['/v1/computer', '/v1/session', '/v1/boot']) {
    const response = await host.call(path, { method: path === '/v1/computer' ? 'GET' : 'POST' })
    expect(response.status, path).toBe(404)
    expect((await response.json()).code, path).toBe('no-computer')
  }
  const socket = new WebSocket(`${host.base.replace('http:', 'ws:')}/v1/display`, 'binary', { headers: { authorization: 'Bearer owner' } })
  expect((await once(socket, 'unexpected-response'))[1].statusCode).toBe(404)
  expect((await (await host.call('/v1/health')).json()).computers).toEqual({ running: 0, total: 0 })

  const first = await (await host.call('/v1/computers', { method: 'POST', body: { name: 'Mine' } })).json()
  expect(await (await host.call('/v1/host/settings')).json()).toEqual({ name: null, displayName: 'Caboose', defaultComputer: first.id })
  expect((await (await host.call('/v1/computer')).json()).settings.name).toBe('Mine')
  // A second computer leaves the default alone until the owner moves it.
  const second = await (await host.call('/v1/computers', { method: 'POST', body: { name: 'Other' } })).json()
  expect((await (await host.call('/v1/computers')).json()).defaultComputer).toBe(first.id)
  expect((await host.call('/v1/host/settings', { method: 'PATCH', body: { defaultComputer: 'c-ffffffffff' } })).status).toBe(400)
  expect((await host.call('/v1/host/settings', { method: 'PATCH', body: { color: 'red' } })).status).toBe(400)
  expect(await (await host.call('/v1/host/settings', { method: 'PATCH', body: { name: ' Den ', defaultComputer: second.id } })).json()).toEqual({ name: 'Den', displayName: 'Den', defaultComputer: second.id })
  expect((await (await host.call('/v1/computer')).json()).settings.name).toBe('Other')
})

it('pairs a host phone that reaches every computer as the owner, and signs it out', async () => {
  const host = await startHost(false, false, true)
  const issued = await (await host.call('/v1/host/pairing', { method: 'POST' })).json()
  const pair = (body: unknown) => fetch(`${host.base}/v1/pair`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
  const minted = await (await pair({ code: issued.code, deviceName: 'Owner iPhone' })).json()
  expect(minted).toEqual({ token: expect.stringMatching(/^cbp_/), scope: 'host', computer: null })
  const phone = minted.token as string
  expect((await (await host.call('/v1/host/phones')).json()).phones).toEqual([expect.objectContaining({ name: 'Owner iPhone' })])

  // With no computer yet, the phone sees the empty host and makes the first one.
  expect((await (await host.call('/v1/computers', { token: phone })).json()).computers).toEqual([])
  const made = await host.call('/v1/computers', { method: 'POST', token: phone, body: { name: 'First', size: 'micro' } })
  expect(made.status).toBe(201)
  const first = await made.json()
  expect((await host.call(`/v1/computers/${first.id}/session`, { method: 'POST', token: phone })).status).toBe(200)
  const socket = new WebSocket(`${host.base.replace('http:', 'ws:')}/v1/computers/${first.id}/display`, 'binary', { headers: { authorization: `Bearer ${phone}` } })
  await once(socket, 'open')
  expect((await host.call('/v1/host/settings', { token: phone })).status).toBe(200)
  // Host routes are the operator's; a computer phone has none of them.
  const computerPhone = (await host.phones.mint(first.id, 'Kid iPad')).token
  expect((await host.call('/v1/host/phones', { token: computerPhone })).status).toBe(403)
  expect((await host.call('/v1/host/pairing', { method: 'POST', token: computerPhone })).status).toBe(403)

  const phoneId = (await (await host.call('/v1/host/phones')).json()).phones[0].id as string
  expect((await host.call(`/v1/computers/${first.id}/phones/${phoneId}`, { method: 'DELETE' })).status).toBe(404)
  const closed = once(socket, 'close')
  expect(await (await host.call(`/v1/host/phones/${phoneId}`, { method: 'DELETE' })).json()).toEqual({ revoked: true })
  await closed
  expect((await host.call('/v1/computers', { token: phone })).status).toBe(401)
  expect((await host.call(`/v1/host/phones/${phoneId}`, { method: 'DELETE' })).status).toBe(404)
})

it('starts a new computer and streams each step of its boot until it runs', async () => {
  const host = await startHost(false, false, true)
  const made = await (await host.call('/v1/computers', { method: 'POST', body: { name: 'First', start: true } })).json()
  expect(made.boot).toMatchObject({ state: 'running' })
  await vi.waitFor(async () => expect((await (await host.call(`/v1/computers/${made.id}/boot`)).json()).boot.state).toBe('succeeded'))
  const { boot } = await (await host.call(`/v1/computers/${made.id}/boot`)).json()
  expect(boot.error).toBeNull()
  expect(boot.finishedAt).toEqual(expect.any(String))
  expect(host.made.get(made.id)!.calls).toEqual(['wake'])
  expect((await host.call('/v1/computers', { method: 'POST', body: { name: 'Bad', start: 'yes' } })).status).toBe(400)

  // A failing start says so, at the step it failed, and the same route retries it.
  const second = await (await host.call('/v1/computers', { method: 'POST', body: { name: 'Second' } })).json()
  const fake = host.made.get(second.id)!
  let fail = true
  const wake = fake.controller.wake
  fake.controller.wake = async mode => { if (fail) throw new Error('No space left on device'); return wake(mode) }
  const events = await fetch(`${host.base}/v1/computers/${second.id}/boot`, { headers: { authorization: 'Bearer owner', accept: 'text/event-stream' } })
  expect(events.headers.get('content-type')).toMatch(/^text\/event-stream/)
  expect((await host.call(`/v1/computers/${second.id}/boot`, { method: 'POST' })).status).toBe(202)
  const stream = await events.text()
  const frames = stream.split('\n\n').filter(frame => frame.startsWith('event: boot')).map(frame => JSON.parse(frame.split('\ndata: ')[1]!).boot)
  expect(frames[0]).toBeNull()
  expect(frames.at(-1)).toMatchObject({ state: 'failed', error: 'No space left on device' })
  fail = false
  expect((await host.call(`/v1/computers/${second.id}/boot`, { method: 'POST' })).status).toBe(202)
  await vi.waitFor(async () => expect((await (await host.call(`/v1/computers/${second.id}/boot`)).json()).boot.state).toBe('succeeded'))
})

it('serves the one computer it is given without a fleet', async () => {
  const { controller } = fakeController('solo')
  const app = createCabooseServer({ token: 'owner', settings: memorySettings({ name: 'Solo', memoryMb: 2048, vcpus: 2, idleMs: 600_000, defaultAgent: null }), controller })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  close.push(() => new Promise(resolve => app.server.close(() => resolve())))
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const headers = { authorization: 'Bearer owner', 'content-type': 'application/json' }
  expect(await (await fetch(`${base}/v1/computers`, { headers })).json()).toMatchObject({ canCreate: false, computers: [{ id: STANDALONE_COMPUTER, createdAt: null }] })
  expect((await fetch(`${base}/v1/computers`, { method: 'POST', headers, body: JSON.stringify({ name: 'More' }) })).status).toBe(409)
  expect((await fetch(`${base}/v1/computers/${STANDALONE_COMPUTER}/pairing`, { method: 'POST', headers })).status).toBe(409)
  expect((await fetch(`${base}/v1/computers/${STANDALONE_COMPUTER}/computer`, { headers })).status).toBe(200)
  expect((await fetch(`${base}/v1/computers/${STANDALONE_COMPUTER}`, { method: 'DELETE', headers, body: JSON.stringify({ confirm: true }) })).status).toBe(409)
})

it('deletes a computer whose first-wake components upgrade is still running, once the upgrade is done', async () => {
  const host = await startHost()
  const kids = await (await host.call('/v1/computers', { method: 'POST', body: { name: 'Kids' } })).json()
  const fake = host.made.get(kids.id)!
  // The guest answers the upgrade's first command only when let go.
  let letGo!: () => void
  const held = new Promise<void>(resolve => { letGo = resolve })
  let upgrading = false
  fake.controller.componentsMode = 'container'
  fake.controller.guest = () => ({ ownerEnv: [], run: async () => { upgrading = true; await held; return '' } })
  expect((await host.call(`/v1/computers/${kids.id}/session`, { method: 'POST' })).status).toBe(200)
  await vi.waitFor(() => expect(upgrading).toBe(true))
  expect((await (await host.call(`/v1/computers/${kids.id}`)).json()).upgrade?.state).toBe('checking')

  let answered = false
  const deleting = host.call(`/v1/computers/${kids.id}`, { method: 'DELETE', body: { confirm: true } }).then(response => { answered = true; return response })
  await new Promise(resolve => setTimeout(resolve, 100))
  expect(answered).toBe(false)
  expect(fake.calls).not.toContain('destroy')
  letGo()
  expect((await deleting).status).toBe(200)
  expect(fake.calls).toContain('destroy')
})
