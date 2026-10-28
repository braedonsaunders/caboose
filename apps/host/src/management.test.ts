import { once } from 'node:events'
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { WebSocket } from 'ws'
import { afterEach, expect, it, vi } from 'vitest'
import { createCabooseServer, type Controller, type Session } from './server.js'
import { openSettings } from './settings.js'

const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close() })

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'caboose-management-'))
  cleanup.push(() => rm(root, { recursive: true, force: true }))
  const defaults = { name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 600000 }
  const settings = await openSettings(join(root, 'caboose.json'), defaults)
  let active: { memoryMb: number; vcpus: number } | null = null
  const session = (): Session => ({ state: 'running', display: { path: '/v1/display', token: 'display-secret', protocol: 'xpra-ws' },
    computer: { name: settings.get().name, image: 'Debian 13', ...active! } })
  const controller: Controller = {
    wake: vi.fn(async () => { active ??= { memoryMb: settings.get().memoryMb, vcpus: settings.get().vcpus }; return session() }),
    restart: vi.fn(async () => { active = { memoryMb: settings.get().memoryMb, vcpus: settings.get().vcpus }; return session() }),
    park: vi.fn(async () => {}), activeResources: () => active, hasSavedState: () => active !== null,
    stats: () => ({ kvm: true }), apps: async () => [], launch: async () => {},
    displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => undefined,
  }
  const webRoot = join(root, 'web')
  await mkdir(join(webRoot, 'assets'), { recursive: true })
  await writeFile(join(webRoot, 'index.html'), '<!doctype html><title>Caboose</title>')
  await writeFile(join(webRoot, 'assets', 'app.js'), 'window.caboose=true;')
  await writeFile(join(root, 'private.txt'), 'private-host-data')
  await symlink(join(root, 'private.txt'), join(webRoot, 'leak.txt'))
  const app = createCabooseServer({ token: 'owner', settings, controller, webRoot })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  cleanup.push(() => app.shutdown())
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  const request = (path: string, method = 'GET', body?: unknown) => fetch(base + path, {
    method, headers: { authorization: 'Bearer owner', 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  return { root, app, settings, controller, base, request }
}

it('authenticates every management endpoint and polls status without waking or leasing', async () => {
  const { base, request, controller, app } = await fixture()
  for (const [path, method] of [['/v1/computer', 'GET'], ['/v1/computer/settings', 'PATCH'], ['/v1/computer/restart', 'POST']]) {
    expect((await fetch(base + path, { method })).status).toBe(401)
  }
  const status = await (await request('/v1/computer')).json()
  expect(status).toMatchObject({ state: 'parked', activeResources: null, restartRequired: false,
    clients: { display: 0, control: 0 }, tasks: { running: 0, paused: 0 }, capabilities: { restart: true }, lastError: null,
    limits: { memoryMb: { min: 512, max: 65536 } } })
  expect(JSON.stringify(status)).not.toContain('owner')
  expect(controller.wake).not.toHaveBeenCalled()
  await request('/v1/session', 'POST')
  app.computer.setIdleMs(20)
  for (let i = 0; i < 3; i++) await request('/v1/computer')
  await vi.waitFor(() => expect(controller.park).toHaveBeenCalledOnce())
})

it('persists settings, reports pending resources, and applies them only on confirmed restart', async () => {
  const { request, controller, root, settings } = await fixture()
  await request('/v1/session', 'POST')
  const updated = await request('/v1/computer/settings', 'PATCH', { name: 'My desk', memoryMb: 4096, vcpus: 4 })
  expect(updated.status).toBe(200)
  expect(await updated.json()).toMatchObject({ restartRequired: true, activeResources: { memoryMb: 2048, vcpus: 2 }, settings: { name: 'My desk', memoryMb: 4096, vcpus: 4 } })
  expect((await (await request('/v1/session', 'POST')).json()).computer.name).toBe('My desk')
  expect((await request('/v1/computer/restart', 'POST', {})).status).toBe(400)
  expect((await request('/v1/computer/restart', 'POST', { confirm: 'true' })).status).toBe(400)
  expect(controller.restart).not.toHaveBeenCalled()
  const result = await request('/v1/computer/restart', 'POST', { confirm: true })
  expect(await result.json()).toMatchObject({ state: 'running', restartRequired: false, activeResources: { memoryMb: 4096, vcpus: 4 } })
  const reopened = await openSettings(join(root, 'caboose.json'), { name: 'env', memoryMb: 512, vcpus: 1, idleMs: 60000 })
  expect(reopened.get()).toEqual(settings.get())
})

it('rejects invalid bodies atomically and exposes lifecycle errors', async () => {
  const { request, base, settings, controller } = await fixture()
  const original = settings.get()
  for (const body of [[], null, { memoryMb: 0, name: 'must not save' }, { idleMs: 0 }, { vcpus: 1.1 }, { arbitrary: true }]) {
    expect((await request('/v1/computer/settings', 'PATCH', body)).status).toBe(400)
    expect(settings.get()).toEqual(original)
  }
  expect((await fetch(base + '/v1/computer/settings', { method: 'PATCH', headers: { authorization: 'Bearer owner' }, body: '{' })).status).toBe(400)
  vi.mocked(controller.restart!).mockRejectedValueOnce(new Error('Guest disk could not be synced'))
  expect((await request('/v1/computer/restart', 'POST', { confirm: true })).status).toBe(500)
  expect(await (await request('/v1/computer')).json()).toMatchObject({ state: 'error', lastError: 'Guest disk could not be synced' })
})

it('broadcasts settings changes and disconnects control clients on restart', async () => {
  const { request, base } = await fixture()
  await request('/v1/session', 'POST')
  const client = new WebSocket(base.replace('http:', 'ws:') + '/v1/control', { headers: { authorization: 'Bearer owner' } })
  cleanup.push(async () => { client.terminate() })
  const messages: any[] = []
  client.on('message', data => messages.push(JSON.parse(String(data))))
  await once(client, 'open')
  expect((await (await request('/v1/computer')).json()).clients.control).toBe(1)
  await request('/v1/computer/settings', 'PATCH', { name: 'Updated' })
  await vi.waitFor(() => expect(messages.some(event => event.type === 'computer.settings' && event.computer.settings.name === 'Updated')).toBe(true))
  const closed = once(client, 'close')
  await request('/v1/computer/restart', 'POST', { confirm: true })
  await closed
})

it('serves public SPA files without exposing API paths or escaping the asset root', async () => {
  const { base } = await fixture()
  for (const path of ['/', '/settings', '/agents']) {
    const result = await fetch(base + path)
    expect(result.status).toBe(200)
    expect(result.headers.get('content-type')).toContain('text/html')
    expect(result.headers.get('cache-control')).toBe('no-store')
    expect(result.headers.get('content-security-policy')).toContain("frame-ancestors 'none'")
  }
  const asset = await fetch(base + '/assets/app.js')
  expect(asset.headers.get('content-type')).toContain('javascript')
  expect((await fetch(base + '/assets/missing.js')).status).toBe(404)
  expect((await fetch(base + '/v1/not-a-route')).status).toBe(401)
  expect((await fetch(base + '/v1')).status).toBe(401)
  expect((await fetch(base + '/%2e%2e%2fprivate.txt')).status).toBe(403)
  expect((await fetch(base + '/leak.txt')).status).toBe(403)
  expect((await fetch(base + '/.env')).status).toBe(403)
})
