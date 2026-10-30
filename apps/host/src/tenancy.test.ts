import { once } from 'node:events'
import { WebSocket } from 'ws'
import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo } from 'node:net'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { ComputerRegistry, OWNER_COMPUTER, PhoneTokens, type ComputerRecord } from './computers.js'
import { openIdentityDatabase, type IdentityDatabase } from './identity/database.js'
import { Identity } from './identity/service.js'
import { createCabooseServer, type ComputerPieces, type Controller } from './server.js'
import { ReachService, Tailscale } from './reach.js'
import { SettingsStore, settingsLimits, type ComputerSettings } from './settings.js'

let root: string
let database: IdentityDatabase
let base: string
let computers: ComputerRegistry
let closeServer: () => Promise<void>
const disks = new Map<string, number>()
const woken: string[] = []

function fakeController(id: string): Controller {
  return {
    wake: async () => { woken.push(id); return { state: 'running', display: { path: '/v1/display', token: 'd', protocol: 'caboose-display' }, computer: { name: id, image: 'Debian 13', memoryMb: 2048, vcpus: 2 } } },
    park: async () => {}, destroy: async () => {},
    activeResources: () => null, hasSavedState: () => false, stats: () => ({ host: 'caboose-host' }),
    apps: async () => [], launch: async () => {},
    displayUrl: 'ws://127.0.0.1:1', agentDisplayUrl: 'ws://127.0.0.1:1', ensureAgentSeat: async () => {}, guest: () => undefined,
  }
}

beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), 'caboose-tenancy-'))
  database = await openIdentityDatabase({ dataDir: join(root, 'identity') })
  const identity = Identity.create({ database, baseURL: 'http://127.0.0.1:7310', secret: 's'.repeat(40), setupCodePath: join(root, 'setup-code') })
  computers = await ComputerRegistry.open(root, database)
  async function open(record: ComputerRecord, initial?: ComputerSettings): Promise<ComputerPieces> {
    await mkdir(computers.dataDir(record.id), { recursive: true })
    await writeFile(join(computers.dataDir(record.id), 'caboose.json'), '{}')
    const settings = new SettingsStore(initial ?? { name: 'Caboose', memoryMb: 2048, vcpus: 2, idleMs: 600_000, defaultAgent: null }, settingsLimits(), { load: async () => undefined, save: async () => {} })
    return { settings, controller: fakeController(record.id) }
  }
  const owner = await open(computers.get(OWNER_COMPUTER)!)
  const webRoot = join(root, 'web')
  await mkdir(webRoot)
  await writeFile(join(webRoot, 'index.html'), '<!doctype html><title>Caboose</title>')
  const app = createCabooseServer({
    token: 'owner-token-for-tests', ...owner, identity, webRoot,
    reach: new ReachService({ bind: '127.0.0.1', port: 7310, publicUrl: 'https://caboose.example.com', mdns: false, id: 'test-host', name: () => 'Caboose', tailscale: new Tailscale(7310, null) }),
    fleet: { computers, phones: PhoneTokens.memory(), open, defaults: { memoryMb: 2048, vcpus: 2, idleMs: 600_000 }, maxRunning: 4, diskBytes: async record => disks.get(record.id) ?? 0 },
  })
  app.server.listen(0, '127.0.0.1')
  await once(app.server, 'listening')
  base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
  closeServer = () => new Promise(resolve => app.server.close(() => resolve()))
}, 60_000)

afterAll(async () => {
  await closeServer()
  await database.close()
  await rm(root, { recursive: true, force: true })
})

/** A browser: it keeps the session cookie the host sets and sends it back. */
function browser() {
  let cookie = ''
  return async (path: string, init: { method?: string; body?: unknown; headers?: Record<string, string> } = {}) => {
    const response = await fetch(`${base}${path}`, {
      method: init.method ?? 'GET', redirect: 'manual',
      headers: { ...(cookie ? { cookie } : {}), ...(init.body !== undefined ? { 'content-type': 'application/json' } : {}), origin: base, ...init.headers },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    })
    const set = response.headers.getSetCookie().map(value => value.split(';')[0]).filter(Boolean)
    if (set.length) cookie = set.join('; ')
    return response
  }
}

const proxied = { 'x-forwarded-for': '203.0.113.9' }

describe('a host with accounts and tenants', () => {
  const operator = browser()
  let home: string

  it('requires the setup code even on loopback, claims once and gives its computers to the first tenant', async () => {
    const anonymous = browser()
    expect(await (await anonymous('/v1/setup')).json()).toEqual({ claimed: false, codeRequired: true })
    expect(await (await anonymous('/v1/setup', { headers: proxied })).json()).toEqual({ claimed: false, codeRequired: true })
    expect((await anonymous('/setup', { headers: proxied })).status).toBe(403)
    expect((await anonymous('/setup')).status).toBe(403)
    expect((await anonymous('/setup?code=wrong')).status).toBe(403)
    expect((await anonymous(`/setup?code=${'é'.repeat(64)}`)).status).toBe(403)
    const code = (await readFile(join(root, 'setup-code'), 'utf8')).trim()
    expect((await anonymous(`/setup?code=${code}`, { headers: proxied })).status).toBe(200)
    expect(existsSync(join(root, 'setup-code'))).toBe(true)
    expect((await anonymous('/v1/me')).status).toBe(401)
    const tokenHeaders = { authorization: 'Bearer owner-token-for-tests' }
    expect((await (await anonymous('/v1/me', { headers: tokenHeaders })).json()).setupRequired).toBe(true)
    expect((await (await anonymous('/v1/computers', { headers: tokenHeaders })).json()).canCreate).toBe(false)
    expect((await anonymous('/v1/computers', { method: 'POST', headers: tokenHeaders, body: { name: 'Unowned' } })).status).toBe(409)
    expect((await anonymous('/v1/setup/link', { method: 'POST' })).status).toBe(401)
    expect((await (await anonymous('/v1/setup/link', { method: 'POST', headers: tokenHeaders })).json()).path).toBe(`/setup?code=${code}`)

    const owner = { name: 'Braedon', email: 'owner@example.com', password: 'correct horse', tenantName: 'Home' }
    expect((await anonymous('/v1/setup', { method: 'POST', body: owner, headers: proxied })).status).toBe(400)
    expect((await anonymous('/v1/setup', { method: 'POST', body: owner })).status).toBe(400)
    expect((await anonymous('/v1/setup', { method: 'POST', body: { ...owner, code: 'é'.repeat(64) } })).status).toBe(400)
    expect((await operator('/v1/setup', { method: 'POST', body: { ...owner, code }, headers: proxied })).status).toBe(201)
    expect(await (await anonymous('/v1/setup')).json()).toEqual({ claimed: true, codeRequired: false })
    expect(existsSync(join(root, 'setup-code'))).toBe(false)
    expect((await anonymous('/v1/setup', { method: 'POST', body: { ...owner, email: 'again@example.com' } })).status).toBe(409)
    expect((await anonymous('/setup')).status).toBe(302)

    const me = await (await operator('/v1/me')).json()
    expect(me).toMatchObject({ kind: 'admin', operator: true, user: { name: 'Braedon', email: 'owner@example.com' }, tenants: [{ name: 'Home' }] })
    home = me.tenants[0].id
    expect(computers.get(OWNER_COMPUTER)?.tenantId).toBe(home)
    const persons = (await (await operator(`/v1/tenants/${home}/people`)).json()).people
    expect(persons).toEqual([expect.objectContaining({ name: 'Braedon', userId: me.user.id, tenantId: home })])
    expect(computers.get(OWNER_COMPUTER)?.personId).toBe(persons[0].id)
    expect((await operator('/v1/setup/link', { method: 'POST' })).status).toBe(403)
    const listed = await (await operator('/v1/computers')).json()
    expect(listed.computers).toEqual([expect.objectContaining({ id: 'owner', tenantId: home })])
    expect((await operator('/v1/health')).status).toBe(200)
    const capacity = await operator('/v1/host/capacity')
    expect(capacity.status).toBe(200)
    expect(capacity.headers.get('cache-control')).toBe('no-store')
    expect((await capacity.json()).scope).toBe('host')
    expect((await anonymous('/v1/host/capacity')).status).toBe(401)
    expect((await anonymous('/v1/computers/owner/usage')).status).toBe(401)
    expect((await operator('/v1/computers/owner/usage')).status).toBe(200)
    expect((await operator('/v1/computers/owner/usage/storage', { method: 'POST' })).status).toBe(200)
    expect((await operator('/v1/host/reach')).status).toBe(200)
    const unavailable = await operator('/v1/host/reach/tailscale', { method: 'PUT', body: { enabled: true } })
    expect(unavailable.status).toBe(409)
    expect((await unavailable.json()).error).toMatch(/Tailscale is not installed/)
    // The owner token keeps working beside accounts.
    expect((await fetch(`${base}/v1/computers`, { headers: { authorization: 'Bearer owner-token-for-tests' } })).status).toBe(200)
  })

  it("keeps each tenant's computers within its quotas, when made, resized and woken", async () => {
    const made = await (await operator('/v1/tenants', { method: 'POST', body: { name: 'Family', quotas: { memoryMb: 4096, vcpus: 4, diskGb: 1 } } })).json()
    expect(made).toMatchObject({ name: 'Family', quotas: { memoryMb: 4096, vcpus: 4, diskGb: 1 }, usage: { computers: 0, memoryMb: 0, vcpus: 0, diskBytes: 0 } })
    const family = made.id as string
    expect((await operator('/v1/computers', { method: 'POST', body: { name: 'Sam' } })).status).toBe(400)
    const sam = await (await operator('/v1/computers', { method: 'POST', body: { name: 'Sam', tenantId: family, person: 'Sam', memoryMb: 2048, vcpus: 2 } })).json()
    expect(sam).toMatchObject({ tenantId: family, person: 'Sam', settings: { memoryMb: 2048 } })
    const over = await operator('/v1/computers', { method: 'POST', body: { name: 'Alex', person: 'Alex', tenantId: family, memoryMb: 4096, vcpus: 2 } })
    expect((await operator('/v1/computers', { method: 'POST', body: { name: 'Preset', person: 'Preset', tenantId: family, size: 'standard' } })).status).toBe(409)
    expect(over.status).toBe(409)
    expect((await over.json()).error).toMatch(/6144 MiB.*quota is 4096/)
    expect((await operator(`/v1/computers/${sam.id}/computer/settings`, { method: 'PATCH', body: { vcpus: 6 } })).status).toBe(409)
    expect((await operator(`/v1/computers/${sam.id}/computer/settings`, { method: 'PATCH', body: { memoryMb: 4096 } })).status).toBe(200)

    disks.set(sam.id, 2 * 1024 ** 3)
    const refused = await operator(`/v1/computers/${sam.id}/session`, { method: 'POST' })
    expect(refused.status).toBe(409)
    expect((await refused.json()).error).toMatch(/disk.*quota is 1 GiB/)
    expect(woken).not.toContain(sam.id)
    disks.set(sam.id, 1024 ** 2)
    expect((await operator(`/v1/computers/${sam.id}/session`, { method: 'POST' })).status).toBe(200)
    expect(woken).toContain(sam.id)

    const tenants = await (await operator('/v1/tenants')).json()
    expect(tenants.tenants.find((tenant: { id: string }) => tenant.id === family).usage).toEqual({ computers: 1, memoryMb: 4096, vcpus: 2, diskBytes: 1024 ** 2 })
    expect((await operator(`/v1/tenants/${family}`, { method: 'DELETE' })).status).toBe(409)
  })

  it('invites an administrator by link, who then sees only their tenant', async () => {
    const tenants = (await (await operator('/v1/tenants')).json()).tenants as Array<{ id: string; name: string }>
    const family = tenants.find(tenant => tenant.name === 'Family')!.id
    const { token } = await (await operator(`/v1/tenants/${family}/invites`, { method: 'POST', body: { email: 'parent@example.com' } })).json()
    const parent = browser()
    expect(await (await parent(`/v1/invites/${token}`)).json()).toMatchObject({ tenantName: 'Family', email: 'parent@example.com', accountExists: false })
    expect((await parent(`/v1/invites/${token}/accept`, { method: 'POST', body: { name: 'Parent', password: 'parent password' } })).status).toBe(200)
    const me = await (await parent('/v1/me')).json()
    expect(me).toMatchObject({ kind: 'admin', operator: false, user: { name: 'Parent' }, tenants: [{ id: family }] })

    const theirs = (await (await parent('/v1/computers')).json()).computers as Array<{ id: string; tenantId: string }>
    expect(theirs.map(computer => computer.tenantId)).toEqual([family])
    expect((await parent(`/v1/computers/${theirs[0]!.id}/recovery`)).status).toBe(200)
    expect((await operator(`/v1/computers/${OWNER_COMPUTER}/recovery`)).status).toBe(200)
    for (const [suffix, method] of [['recovery', 'GET'], ['recovery/capture', 'POST'], ['recovery/captures/00000000-0000-4000-8000-000000000000/restore', 'POST']]) {
      expect((await parent(`/v1/computers/${OWNER_COMPUTER}/${suffix}`, { method })).status).toBe(404)
    }
    expect((await parent('/v1/recovery')).status).toBe(403)

    expect((await parent(`/v1/computers/${OWNER_COMPUTER}`)).status).toBe(404)
    expect((await parent(`/v1/computers/${OWNER_COMPUTER}/computer`)).status).toBe(404)
    expect((await parent('/v1/computer')).status).toBe(403)
    expect((await parent('/v1/health')).status).toBe(403)
    expect((await parent('/v1/host')).status).toBe(403)
    const beforeCapacity = woken.length
    for (const [suffix, method] of [['usage', 'GET'], ['usage/storage', 'POST']]) {
      expect((await parent(`/v1/computers/${OWNER_COMPUTER}/${suffix}`, { method })).status).toBe(404)
      const response = await parent(`/v1/computers/${theirs[0]!.id}/${suffix}`, { method })
      expect(response.status).toBe(200)
      expect(response.headers.get('cache-control')).toBe('no-store')
    }
    expect((await parent('/v1/host/capacity')).status).toBe(403)
    expect((await parent(`/v1/tenants/${home}/capacity`)).status).toBe(404)
    const usage = await (await parent(`/v1/tenants/${family}/capacity`)).json()
    expect(usage.scope).toBe('tenant')
    expect(usage.host).toBeUndefined()
    expect(usage.counts.total).toBe(theirs.length)
    expect(usage.counts.queued.value).toBeNull()
    expect(woken.length).toBe(beforeCapacity)
    expect((await parent('/v1/host/reach')).status).toBe(403)
    expect((await parent('/v1/host/reach/tailscale', { method: 'PUT', body: { enabled: true } })).status).toBe(403)
    expect((await parent('/v1/tenants', { method: 'POST', body: { name: 'Mine' } })).status).toBe(403)
    expect((await parent(`/v1/tenants/${home}`)).status).toBe(404)
    expect((await parent(`/v1/tenants/${family}`, { method: 'PATCH', body: { quotas: { memoryMb: null } } })).status).toBe(403)
    expect((await parent(`/v1/tenants/${family}`, { method: 'PATCH', body: { name: 'The Family' } })).status).toBe(200)
    expect((await parent('/v1/computers', { method: 'POST', body: { name: 'Elsewhere', tenantId: home } })).status).toBe(400)
    expect((await parent(`/v1/computers/${theirs[0]!.id}`, { method: 'PATCH', body: { tenantId: home } })).status).toBe(400)
    const theirComputer = await (await parent(`/v1/computers/${theirs[0]!.id}`)).json()
    expect((await parent(`/v1/computers/${theirs[0]!.id}`, { method: 'PATCH', body: { person: 'Samuel' } })).status).toBe(400)
    expect((await parent(`/v1/people/${theirComputer.personId}`, { method: 'PATCH', body: { name: 'Samuel' } })).status).toBe(200)
    expect((await (await parent(`/v1/computers/${theirs[0]!.id}`)).json()).person).toBe('Samuel')
    expect((await parent(`/v1/people/${theirComputer.personId}`, { method: 'DELETE' })).status).toBe(409)
    const homePerson = (await (await operator(`/v1/tenants/${home}/people`)).json()).people[0]
    expect((await parent(`/v1/people/${homePerson.id}`, { method: 'PATCH', body: { name: 'Wrong tenant' } })).status).toBe(404)
    expect((await parent(`/v1/people/${homePerson.id}`, { method: 'DELETE' })).status).toBe(404)
    expect((await parent(`/v1/tenants/${home}/people`)).status).toBe(404)
    expect((await parent(`/v1/tenants/${home}/people`, { method: 'POST', body: { name: 'Wrong tenant' } })).status).toBe(404)
    expect((await parent('/v1/computers', { method: 'POST', body: { name: 'Cross tenant', tenantId: family, personId: homePerson.id } })).status).toBe(400)
    expect((await operator(`/v1/computers/${theirs[0]!.id}`, { method: 'PATCH', body: { tenantId: home } })).status).toBe(400)
    expect((await operator(`/v1/computers/${theirs[0]!.id}`, { method: 'PATCH', body: { tenantId: home, personId: homePerson.id } })).status).toBe(200)
    expect((await parent(`/v1/computers/${theirs[0]!.id}`)).status).toBe(404)
    expect((await operator(`/v1/computers/${theirs[0]!.id}`, { method: 'PATCH', body: { tenantId: family, personId: theirComputer.personId } })).status).toBe(200)
    const pairing = await parent(`/v1/computers/${theirs[0]!.id}/pairing`, { method: 'POST' })
    expect(pairing.status).toBe(201)
    const { code } = await pairing.json()
    const paired = await browser()('/v1/pair', { method: 'POST', body: { code, deviceName: 'Family phone' } })
    expect(paired.status).toBe(201)
    const { token: phoneToken } = await paired.json()
    const phone = browser()
    const headers = { authorization: `Bearer ${phoneToken}` }
    for (const [path, method] of [['/v1/recovery', 'GET'], ['/v1/recovery/capture', 'POST'], [`/v1/computers/${theirs[0]!.id}/recovery`, 'GET']]) {
      expect((await phone(path!, { headers, method })).status).toBe(403)
    }

    expect((await phone('/v1/host/reach', { headers })).status).toBe(403)
    expect((await phone('/v1/host/capacity', { headers })).status).toBe(403)
    expect((await phone(`/v1/computers/${theirs[0]!.id}/usage`, { headers })).status).toBe(403)
    expect((await phone(`/v1/computers/${theirs[0]!.id}/usage/storage`, { headers, method: 'POST' })).status).toBe(403)
    expect((await phone(`/v1/tenants/${family}/capacity`, { headers })).status).toBe(403)
    expect((await phone(`/v1/tenants/${family}/people`, { headers })).status).toBe(403)
    expect((await phone(`/v1/people/${theirComputer.personId}`, { headers, method: 'DELETE' })).status).toBe(403)
    expect((await phone('/v1/setup/link', { headers, method: 'POST' })).status).toBe(403)
    expect((await phone('/v1/host/reach/tailscale', { method: 'PUT', body: { enabled: false }, headers })).status).toBe(403)
    expect((await (await parent(`/v1/tenants/${family}/administrators`)).json()).administrators.map((admin: { email: string }) => admin.email)).toEqual(['parent@example.com'])

    // Signed out, the session no longer works.
    expect((await parent('/v1/auth/sign-out', { method: 'POST', body: {} })).status).toBe(200)
    expect((await parent('/v1/me')).status).toBe(401)
    // Signing back in through Better Auth's route sets a new session.
    expect((await parent('/v1/auth/sign-in/email', { method: 'POST', body: { email: 'parent@example.com', password: 'parent password' } })).status).toBe(200)
    expect((await parent('/v1/me')).status).toBe(200)
  })
})


it('closes a live administrator control socket when its session is revoked', async () => {
  const signedIn = await fetch(`${base}/v1/auth/sign-in/email`, {
    method: 'POST', headers: { origin: base, 'content-type': 'application/json' },
    body: JSON.stringify({ email: 'owner@example.com', password: 'correct horse' }),
  })
  expect(signedIn.status).toBe(200)
  const cookie = signedIn.headers.getSetCookie().map(value => value.split(';')[0]).join('; ')
  const accountHeaders = { cookie, origin: base, 'content-type': 'application/json' }
  const current = await (await fetch(`${base}/v1/auth/get-session`, { headers: accountHeaders })).json()
  expect((await fetch(`${base}/v1/session`, { method: 'POST', headers: accountHeaders, body: '{}' })).status).toBe(200)
  const socket = new WebSocket(`${base.replace('http:', 'ws:')}/v1/control`, { headers: { cookie }, handshakeTimeout: 5_000 })
  try {
    await once(socket, 'open')
    const closed = once(socket, 'close')
    const revoked = await fetch(`${base}/v1/auth/revoke-session`, { method: 'POST', headers: accountHeaders, body: JSON.stringify({ id: current.session.id }) })
    expect(revoked.status).toBe(200)
    await closed
    expect(socket.readyState).toBe(WebSocket.CLOSED)
    expect((await fetch(`${base}/v1/me`, { headers: accountHeaders })).status).toBe(401)
  } finally { socket.terminate() }
}, 15_000)

it('fences the former tenant socket on a move and admits the destination administrator', async () => {
  const ownerHeaders = { authorization: 'Bearer owner-token-for-tests', origin: base, 'content-type': 'application/json' }
  const records = (await (await fetch(`${base}/v1/computers`, { headers: ownerHeaders })).json()).computers as Array<{ id: string; tenantId: string; personId: string }>
  // Earlier tests rename the tenant. Ownership IDs remain the fixture identity.
  const owned = records.filter(record => record.id !== OWNER_COMPUTER)
  expect(owned).toHaveLength(1)
  const target = owned[0]!
  const family = { id: target.tenantId }
  const home = { id: records.find(record => record.id === OWNER_COMPUTER)!.tenantId }
  const homePerson = (await (await fetch(`${base}/v1/tenants/${home.id}/people`, { headers: ownerHeaders })).json()).people[0]
  const signedIn = await fetch(`${base}/v1/auth/sign-in/email`, { method: 'POST', headers: { origin: base, 'content-type': 'application/json' }, body: JSON.stringify({ email: 'parent@example.com', password: 'parent password' }) })
  expect(signedIn.status).toBe(200)
  const oldCookie = signedIn.headers.getSetCookie().map(value => value.split(';')[0]).join('; ')
  expect((await fetch(`${base}/v1/computers/${target.id}/session`, { method: 'POST', headers: { cookie: oldCookie, origin: base, 'content-type': 'application/json' }, body: '{}' })).status).toBe(200)
  const invitation = await (await fetch(`${base}/v1/tenants/${home.id}/invites`, { method: 'POST', headers: ownerHeaders, body: JSON.stringify({ email: 'move-admin@example.com' }) })).json()
  const accepted = await fetch(`${base}/v1/invites/${invitation.token}/accept`, { method: 'POST', headers: { origin: base, 'content-type': 'application/json' }, body: JSON.stringify({ name: 'Move administrator', password: 'move admin password' }) })
  expect(accepted.status).toBe(200)
  const newCookie = accepted.headers.getSetCookie().map(value => value.split(';')[0]).join('; ')
  const socketURL = `${base.replace('http:', 'ws:')}/v1/computers/${target.id}/control`
  const oldSocket = new WebSocket(socketURL, { headers: { cookie: oldCookie }, handshakeTimeout: 5_000 })
  let newSocket: WebSocket | undefined
  try {
    await once(oldSocket, 'open')
    const closed = once(oldSocket, 'close')
    const moved = await fetch(`${base}/v1/computers/${target.id}`, { method: 'PATCH', headers: ownerHeaders, body: JSON.stringify({ tenantId: home.id, personId: homePerson.id }) })
    expect(moved.status).toBe(200)
    await closed
    expect(oldSocket.readyState).toBe(WebSocket.CLOSED)
    expect((await fetch(`${base}/v1/computers/${target.id}`, { headers: { cookie: oldCookie } })).status).toBe(404)
    newSocket = new WebSocket(socketURL, { headers: { cookie: newCookie }, handshakeTimeout: 5_000 })
    await once(newSocket, 'open')
    expect(newSocket.readyState).toBe(WebSocket.OPEN)
  } finally {
    oldSocket.terminate(); newSocket?.terminate()
    await fetch(`${base}/v1/computers/${target.id}`, { method: 'PATCH', headers: ownerHeaders, body: JSON.stringify({ tenantId: family.id, personId: target.personId }) })
  }
}, 20_000)
