import { once } from 'node:events'
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
  computers = await ComputerRegistry.open(root)
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
    const listed = await (await operator('/v1/computers')).json()
    expect(listed.computers).toEqual([expect.objectContaining({ id: 'owner', tenantId: home })])
    expect((await operator('/v1/health')).status).toBe(200)
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
    const over = await operator('/v1/computers', { method: 'POST', body: { name: 'Alex', tenantId: family, memoryMb: 4096, vcpus: 2 } })
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
    expect((await parent(`/v1/computers/${OWNER_COMPUTER}`)).status).toBe(404)
    expect((await parent(`/v1/computers/${OWNER_COMPUTER}/computer`)).status).toBe(404)
    expect((await parent('/v1/computer')).status).toBe(403)
    expect((await parent('/v1/health')).status).toBe(403)
    expect((await parent('/v1/host')).status).toBe(403)
    expect((await parent('/v1/host/reach')).status).toBe(403)
    expect((await parent('/v1/host/reach/tailscale', { method: 'PUT', body: { enabled: true } })).status).toBe(403)
    expect((await parent('/v1/tenants', { method: 'POST', body: { name: 'Mine' } })).status).toBe(403)
    expect((await parent(`/v1/tenants/${home}`)).status).toBe(404)
    expect((await parent(`/v1/tenants/${family}`, { method: 'PATCH', body: { quotas: { memoryMb: null } } })).status).toBe(403)
    expect((await parent(`/v1/tenants/${family}`, { method: 'PATCH', body: { name: 'The Family' } })).status).toBe(200)
    expect((await parent('/v1/computers', { method: 'POST', body: { name: 'Elsewhere', tenantId: home } })).status).toBe(400)
    expect((await parent(`/v1/computers/${theirs[0]!.id}`, { method: 'PATCH', body: { tenantId: home } })).status).toBe(400)
    expect((await (await parent(`/v1/computers/${theirs[0]!.id}`, { method: 'PATCH', body: { person: 'Samuel' } })).json()).person).toBe('Samuel')
    const pairing = await parent(`/v1/computers/${theirs[0]!.id}/pairing`, { method: 'POST' })
    expect(pairing.status).toBe(201)
    const { code } = await pairing.json()
    const paired = await browser()('/v1/pair', { method: 'POST', body: { code, deviceName: 'Family phone' } })
    expect(paired.status).toBe(201)
    const { token: phoneToken } = await paired.json()
    const phone = browser()
    const headers = { authorization: `Bearer ${phoneToken}` }
    expect((await phone('/v1/host/reach', { headers })).status).toBe(403)
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
