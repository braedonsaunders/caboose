import { once } from 'node:events'
import { createServer } from 'node:http'
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { WebSocket } from 'ws'
import { afterEach, expect, it, vi } from 'vitest'
import { createCabooseServer, type Controller, type Session } from './server.js'
import { openSettings } from './settings.js'
import { ServiceMemory } from './running-apps.js'
import { ContainerSpecStore } from './container-spec.js'

const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close() })

async function fixture(configure?: (controller: Controller) => void, extra: Partial<Parameters<typeof createCabooseServer>[0]> = {}) {
  const root = await mkdtemp(join(tmpdir(), 'caboose-management-'))
  cleanup.push(() => rm(root, { recursive: true, force: true }))
  const defaults = { name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 600000, defaultAgent: null }
  const settings = await openSettings(join(root, 'caboose.json'), defaults)
  let active: { memoryMb: number; vcpus: number } | null = null
  const session = (): Session => ({ state: 'running', display: { path: '/v1/display', token: 'display-secret', protocol: 'caboose-display' },
    computer: { name: settings.get().name, image: 'Debian 13', ...active! } })
  const controller: Controller = {
    wake: vi.fn(async () => { active ??= { memoryMb: settings.get().memoryMb, vcpus: settings.get().vcpus }; return session() }),
    restart: vi.fn(async () => { active = { memoryMb: settings.get().memoryMb, vcpus: settings.get().vcpus }; return session() }),
    park: vi.fn(async () => {}), activeResources: () => active, hasSavedState: () => active !== null,
    stats: () => ({ kvm: true }), apps: async () => [], launch: async () => {},
    displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => undefined,
  }
  configure?.(controller)
  const webRoot = join(root, 'web')
  await mkdir(join(webRoot, 'assets'), { recursive: true })
  await writeFile(join(webRoot, 'index.html'), '<!doctype html><title>Caboose</title>')
  await writeFile(join(webRoot, 'assets', 'app.js'), 'window.caboose=true;')
  await writeFile(join(root, 'private.txt'), 'private-host-data')
  await symlink(join(root, 'private.txt'), join(webRoot, 'leak.txt'))
  const app = createCabooseServer({ token: 'owner', settings, controller, webRoot, ...extra })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  cleanup.push(() => app.shutdown().catch(() => {})) // A test may have stopped it already.
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
  const reopened = await openSettings(join(root, 'caboose.json'), { name: 'env', memoryMb: 512, vcpus: 1, idleMs: 60000, defaultAgent: null })
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

it('reports asynchronous component updates without blocking the display', async () => {
  let finish!: (value: string) => void
  const pending = new Promise<string>(resolve => { finish = resolve })
  const { request, base } = await fixture(controller => {
    controller.componentsMode = 'vm'
    controller.guest = () => ({ run: async () => pending })
  })
  expect((await request('/v1/session', 'POST')).status).toBe(200)
  const socket = new WebSocket(base.replace('http:', 'ws:') + '/v1/control', { headers: { authorization: 'Bearer owner' } })
  cleanup.push(async () => { socket.terminate() })
  const events: any[] = []
  socket.on('message', data => events.push(JSON.parse(String(data))))
  await once(socket, 'open')
  expect((await (await request('/v1/computer')).json()).upgrade.state).toBe('checking')
  expect((await request('/v1/session/park', 'POST')).status).toBe(409)
  // Deliberately invalid staging path: the error is visible and does not affect the display.
  finish('invalid staging path')
  await vi.waitFor(async () => expect((await (await request('/v1/computer')).json()).upgrade.state).toBe('failed'))
  expect(events.some(e => e.type === 'computer.upgrade' && e.upgrade.state === 'failed')).toBe(true)
  expect((await (await request('/v1/computer')).json()).state).toBe('running')
})

it('shows the computer’s own address and reachable servers, tells caboose-ports, follows a rename, and stays awake for a server', async () => {
  const tailnet = { state: 'running' as const, name: 'caboose.tailnet.ts.net', addresses: ['100.64.1.2'] }
  const commands: string[][] = []
  let listening = true
  const tables = () => `@@ /proc/sys/net/ipv4/ip_local_port_range\n32768 60999\n@@ /proc/net/tcp\n  sl local rem st\n${listening ? '   0: 00000000:1538 00000000:0000 0A 0 0 0 0 0 0 0 1\n' : ''}@@ /proc/net/tcp6\n@@ /proc/net/udp\n@@ /proc/net/udp6\n`
  let network!: () => void
  const guest = { run: vi.fn(async (command: string, args: string[]) => { commands.push([command, ...args]); return args[1]?.includes('/proc/net/tcp') ? tables() : '' }) }
  let running = false
  const { request, app, controller } = await fixture(controller => {
    controller.network = () => ({ tailnet })
    controller.onNetworkChange = listener => { network = listener }
    controller.renameNetwork = vi.fn(async () => {})
    const wake = controller.wake
    controller.wake = async mode => { running = true; return wake(mode) }
    controller.park = vi.fn(async () => { running = false })
    controller.guest = () => running ? guest : undefined
  })
  await request('/v1/session', 'POST')
  network()
  await vi.waitFor(() => expect(commands.some(args => args.at(-1) === '{"forward":true}')).toBe(true))
  await request('/v1/computer')
  await vi.waitFor(async () => expect((await (await request('/v1/computer')).json()).network)
    .toEqual({ tailnet, servers: [{ protocol: 'tcp', address: '0.0.0.0', port: 5432 }] }))
  await request('/v1/computer/settings', 'PATCH', { forwardLoopback: false })
  await vi.waitFor(() => expect(commands.some(args => args.at(-1) === '{"forward":false}')).toBe(true))
  await request('/v1/computer/settings', 'PATCH', { name: 'Dev Box' })
  expect(controller.renameNetwork).toHaveBeenCalledOnce()
  // Postgres listening on the computer's own address keeps it awake past its idle timeout.
  app.computer.setIdleMs(100)
  await new Promise(resolve => setTimeout(resolve, 400))
  expect(app.computer.state).toBe('running')
  listening = false
  await vi.waitFor(() => expect(app.computer.state).toBe('parked'))
})

it('wakes a computer whose services start with it after the host starts, headless, and keeps it awake while they run', async () => {
  let active = 1
  const guest = { run: vi.fn(async (command: string, args: string[]) => {
    if (command === '/usr/local/bin/caboose-scopes' && args[0] === 'activity') return JSON.stringify({ ok: true, result: { services: { active, autostart: 1, failed: 0 }, listening: [] } })
    return ''
  }) }
  let running = false
  const root = await mkdtemp(join(tmpdir(), 'caboose-autostart-'))
  cleanup.push(() => rm(root, { recursive: true, force: true }))
  await writeFile(join(root, 'services.json'), '{"autostart":true}')
  const { app, controller } = await fixture(controller => {
    controller.componentsMode = 'container'
    const wake = controller.wake
    controller.wake = vi.fn(async mode => { running = true; return wake(mode) })
    controller.park = vi.fn(async () => { running = false })
    controller.guest = () => running ? guest : undefined
  }, { serviceMemory: await ServiceMemory.open(join(root, 'services.json')), autostartDelayMs: 10 })
  await vi.waitFor(() => expect(app.computer.state).toBe('running'))
  expect(controller.wake).toHaveBeenCalledWith('headless')
  app.computer.setIdleMs(100)
  await new Promise(resolve => setTimeout(resolve, 400))
  expect(app.computer.state).toBe('running')
  active = 0
  await vi.waitFor(() => expect(app.computer.state).toBe('parked'))
})

it('does not pause a computer in memory while Steam listens, nor while an app works, and pauses it once idle', async () => {
  let listening = true, cpu = 0
  const tables = () => `@@ /proc/sys/net/ipv4/ip_local_port_range\n32768 60999\n@@ /proc/net/tcp\n  sl local rem st\n${listening ? '   0: 00000000:6984 00000000:0000 0A 0 0 0 0 0 0 0 1\n' : ''}@@ /proc/net/tcp6\n@@ /proc/net/udp\n@@ /proc/net/udp6\n`
  const app = { id: 'app-steam-1.scope', kind: 'app', desktopId: null, name: 'Steam', origin: 'launch', startedAt: 1, windows: [], memoryBytes: 1, io: { readBytesPerSecond: 0, writeBytesPerSecond: 0 }, gpu: null, processCount: 1, processes: [], ports: [] }
  const guest = { run: vi.fn(async (command: string, args: string[]) => {
    if (command === '/bin/sh') return tables()
    if (args[0] === 'activity') return JSON.stringify({ ok: true, result: { services: { active: 0, autostart: 0, failed: 0 }, listening: [] } })
    if (args[0] === 'list') return JSON.stringify({ ok: true, result: { version: 1, sampledAt: 1, intervalMs: 2000, machine: { cpus: 4, memoryBytes: 1 }, apps: [{ ...app, cpuPercent: cpu }], services: [] } })
    return ''
  }) }
  let running = false
  // An empty terminal service, so only the busy check stands between the computer and a pause.
  const terminals = createServer((_, response) => { response.setHeader('content-type', 'application/json'); response.end('{"sessions":[]}') })
  terminals.listen(0, '127.0.0.1')
  await once(terminals, 'listening')
  cleanup.push(() => new Promise<void>(resolve => terminals.close(() => resolve())))
  const { app: server, controller, request } = await fixture(controller => {
    controller.componentsMode = 'container'
    controller.terminalService = () => ({ url: `http://127.0.0.1:${(terminals.address() as AddressInfo).port}`, token: 't' })
    const wake = controller.wake
    controller.wake = async mode => { running = true; return wake(mode) }
    controller.canFreeze = () => true
    controller.freeze = vi.fn(async () => {})
    controller.thaw = vi.fn(async () => {})
    controller.guest = () => running ? guest : undefined
  })
  await request('/v1/session', 'POST')
  await new Promise(resolve => setTimeout(resolve, 3500))
  expect(server.computer.state).toBe('running')
  expect(controller.freeze).not.toHaveBeenCalled()
  // Steam stops listening but is downloading: still at work.
  listening = false; cpu = 25
  server.computer.setIdleMs(4000)
  await new Promise(resolve => setTimeout(resolve, 4500))
  expect(controller.freeze).not.toHaveBeenCalled()
  cpu = 0
  await vi.waitFor(() => expect(controller.freeze).toHaveBeenCalled(), { timeout: 8000 })
}, 20_000)

it('keeps a container computer’s image, folders and devices for the operator, read from its container or set whole', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-container-'))
  cleanup.push(() => rm(root, { recursive: true, force: true }))
  const containerSpec = await ContainerSpecStore.open(join(root, 'container.json'))
  const existing = { image: 'caboose-computer:flathub-79f46a1', mounts: [{ source: '/home/bsaun/gpu-remoting/ge', target: '/opt/caboose-games/GE-Proton11-11', readOnly: true }] }
  const { request } = await fixture(controller => {
    controller.existingContainerSpec = async () => existing
    controller.containerSpecApplied = async () => JSON.stringify(containerSpec.get()) === JSON.stringify(existing)
  }, { containerSpec })
  expect(await (await request('/v1/computers/owner/container')).json()).toEqual({ spec: {}, applied: false })
  expect(await (await request('/v1/computers/owner/container/import', 'POST')).json()).toEqual({ spec: existing, applied: true })
  const put = await request('/v1/computers/owner/container', 'PUT', { ...existing, image: 'caboose-owner:steam-ready-5051b68' })
  expect(await put.json()).toEqual({ spec: { ...existing, image: 'caboose-owner:steam-ready-5051b68' }, applied: false })
  expect((await request('/v1/computers/owner/container', 'PUT', { mounts: [{ source: '/', target: '/home/caboose', readOnly: false }] })).status).toBe(400)
  expect(containerSpec.get().image).toBe('caboose-owner:steam-ready-5051b68')
  expect((await request('/v1/computers/nope/container')).status).toBe(404)
})

it('has no container settings for a microVM computer', async () => {
  const { request } = await fixture()
  expect((await request('/v1/computers/owner/container')).status).toBe(409)
})

it('leaves a busy container running when the host stops, and the next host adopts it', async () => {
  const tables = '@@ /proc/net/tcp\n  sl local rem st\n   0: 00000000:6984 00000000:0000 0A 0 0 0 0 0 0 0 1\n'
  const guest = { run: vi.fn(async (command: string) => command === '/bin/sh' ? tables : JSON.stringify({ ok: true, result: { services: { active: 0, autostart: 0, failed: 0 }, listening: [] } })) }
  let running = true
  const first = await fixture(controller => {
    controller.componentsMode = 'container'
    controller.guest = () => running ? guest : undefined
    controller.park = vi.fn(async () => { running = false })
  }, { autostartDelayMs: 60_000 })
  await first.request('/v1/session', 'POST')
  await first.app.shutdown()
  expect(first.controller.park).not.toHaveBeenCalled()
  expect(running).toBe(true)
  // The next host finds it running and takes it back, headless.
  const second = await fixture(controller => {
    controller.componentsMode = 'container'
    controller.resident = async () => running
    controller.guest = () => running ? guest : undefined
  }, { autostartDelayMs: 10 })
  await vi.waitFor(() => expect(second.app.computer.state).toBe('running'))
  expect(second.controller.wake).toHaveBeenCalledWith('headless')
})

it('parks an idle container when the host stops', async () => {
  const guest = { run: vi.fn(async (command: string) => command === '/bin/sh' ? '@@ /proc/net/tcp\n' : '') }
  const { app, controller, request } = await fixture(controller => {
    controller.componentsMode = 'container'
    controller.guest = () => guest
  }, { autostartDelayMs: 60_000 })
  await request('/v1/session', 'POST')
  await app.shutdown()
  expect(controller.park).toHaveBeenCalledOnce()
})
