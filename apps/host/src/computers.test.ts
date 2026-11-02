import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { ComputerRegistry, LEGACY_COMPUTER, PairingCodes, PhoneTokens } from './computers.js'

const roots: string[] = []
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }) })
async function root(): Promise<string> {
  const path = await mkdtemp(join(tmpdir(), 'caboose-computers-'))
  roots.push(path)
  return path
}

describe('ComputerRegistry', () => {
  it('starts a new host with no computers, and lets any computer go', async () => {
    const dir = await root()
    const registry = await ComputerRegistry.open(dir)
    expect(registry.list()).toEqual([])
    const only = await registry.create()
    expect(only.slot).toBe(1)
    await registry.remove(only.id)
    expect(registry.list()).toEqual([])
    expect((await ComputerRegistry.open(dir)).list()).toEqual([])
  })

  it('makes computers on the lowest free slot, keeps them across restarts, and frees a deleted slot', async () => {
    const dir = await root()
    const registry = await ComputerRegistry.open(dir)
    const a = await registry.create({ tenantId: null, person: null }, new Date('2026-10-28T12:00:00Z'))
    const b = await registry.create()
    expect(a).toEqual({ id: expect.stringMatching(/^c-[0-9a-f]{10}$/), slot: 1, createdAt: '2026-10-28T12:00:00.000Z', tenantId: null, person: null })
    expect(b.slot).toBe(2)
    expect(registry.dataDir(a.id)).toBe(join(dir, 'computers', a.id))
    await registry.remove(a.id)
    expect((await registry.create()).slot).toBe(1)
    const reopened = await ComputerRegistry.open(dir)
    expect(reopened.list().map(c => c.slot)).toEqual([2, 1])
    expect(reopened.get(b.id)).toEqual(b)
  })

  it('persists computers beyond the legacy 64-slot range', async () => {
    const dir = await root()
    const registry = await ComputerRegistry.open(dir)
    for (let slot = 1; slot <= 65; slot++) expect((await registry.create()).slot).toBe(slot)
    const reopened = await ComputerRegistry.open(dir)
    expect(reopened.list().map(computer => computer.slot)).toEqual(Array.from({ length: 65 }, (_, i) => i + 1))
  })

  it('keeps each computer in a tenant with its person, and gives a new host\'s computers to its first tenant', async () => {
    const dir = await root()
    const registry = await ComputerRegistry.open(dir)
    const tenant = '11111111-1111-4111-8111-111111111111'
    const other = '22222222-2222-4222-8222-222222222222'
    const kids = await registry.create({ tenantId: other, person: '  Sam ' })
    expect(kids).toMatchObject({ tenantId: other, person: 'Sam' })
    const loose = await registry.create()
    await registry.adoptUnassigned(tenant)
    expect(registry.get(loose.id)?.tenantId).toBe(tenant)
    expect(registry.get(kids.id)?.tenantId).toBe(other)
    await registry.assign(loose.id, { person: 'Braedon' })
    await registry.assign(kids.id, { person: null })
    await expect(registry.assign(kids.id, { person: 'tab\there' })).rejects.toThrow(/person/)
    const reopened = await ComputerRegistry.open(dir)
    expect(reopened.get(loose.id)).toMatchObject({ tenantId: tenant, person: 'Braedon' })
    expect(reopened.get(kids.id)).toMatchObject({ tenantId: other, person: null })
  })

  it('keeps an older host\'s built-in computer as an ordinary, deletable computer under its id and slot', async () => {
    const dir = await root()
    const tenant = '11111111-1111-4111-8111-111111111111'
    await writeFile(join(dir, 'computers.json'), JSON.stringify({ owner: { createdAt: '2026-10-01T00:00:00.000Z', tenantId: tenant, person: 'Braedon' }, computers: [{ id: 'c-0123456789', slot: 1, createdAt: '2026-10-02T00:00:00.000Z' }] }))
    const registry = await ComputerRegistry.open(dir)
    expect(registry.list()).toEqual([
      { id: LEGACY_COMPUTER, slot: 0, createdAt: '2026-10-01T00:00:00.000Z', tenantId: tenant, person: 'Braedon' },
      { id: 'c-0123456789', slot: 1, createdAt: '2026-10-02T00:00:00.000Z', tenantId: null, person: null },
    ])
    expect(registry.dataDir(LEGACY_COMPUTER)).toBe(join(dir, 'computers', 'owner'))
    // A new computer never takes slot 0, even once the legacy computer is gone.
    await registry.remove(LEGACY_COMPUTER)
    expect((await registry.create()).slot).toBe(2)
    const reopened = await ComputerRegistry.open(dir)
    expect(reopened.get(LEGACY_COMPUTER)).toBeUndefined()
    expect(reopened.list().map(c => c.slot)).toEqual([1, 2])
  })

  it('reads a registry from before tenants', async () => {
    const dir = await root()
    await writeFile(join(dir, 'computers.json'), JSON.stringify({ ownerCreatedAt: '2026-10-01T00:00:00.000Z', computers: [{ id: 'c-0123456789', slot: 1, createdAt: '2026-10-02T00:00:00.000Z' }] }))
    const registry = await ComputerRegistry.open(dir)
    expect(registry.list()).toEqual([
      { id: LEGACY_COMPUTER, slot: 0, createdAt: '2026-10-01T00:00:00.000Z', tenantId: null, person: null },
      { id: 'c-0123456789', slot: 1, createdAt: '2026-10-02T00:00:00.000Z', tenantId: null, person: null },
    ])
  })

  it('finds the built-in computer of a host that never wrote a registry, from the files it left', async () => {
    const dir = await root()
    await writeFile(join(dir, 'caboose.json'), JSON.stringify({ name: 'Den' }))
    expect((await ComputerRegistry.open(dir)).list()).toEqual([{ id: LEGACY_COMPUTER, slot: 0, createdAt: null, tenantId: null, person: null }])
  })

  it('refuses a damaged registry rather than forgetting computers', async () => {
    const dir = await root()
    const registry = await ComputerRegistry.open(dir)
    await registry.create()
    const path = join(dir, 'computers.json')
    const stored = JSON.parse(await readFile(path, 'utf8'))
    stored.computers.push({ ...stored.computers[0] })
    await writeFile(path, JSON.stringify(stored))
    await expect(ComputerRegistry.open(dir)).rejects.toThrow(/Duplicate/)
  })

  it('refuses slot 0 for anything but the legacy computer', async () => {
    const dir = await root()
    await writeFile(join(dir, 'computers.json'), JSON.stringify({ version: 2, computers: [{ id: 'c-0123456789', slot: 0, createdAt: '2026-10-02T00:00:00.000Z' }] }))
    await expect(ComputerRegistry.open(dir)).rejects.toThrow(/Invalid computer record/)
  })
})

describe('PhoneTokens', () => {
  it('shows a token once, keeps only its hash, and resolves it to its computer', async () => {
    const dir = await root()
    const path = join(dir, 'phones.json')
    const phones = await PhoneTokens.open(path)
    const { phone, token } = await phones.mint('c-0123456789', '  Braedon’s iPhone ', new Date('2026-10-28T12:00:00Z'))
    expect(token).toMatch(/^cbp_[A-Za-z0-9_-]{43}$/)
    expect(phone).toEqual({ id: expect.stringMatching(/^p-[0-9a-f]{12}$/), name: 'Braedon’s iPhone', createdAt: '2026-10-28T12:00:00.000Z', lastUsedAt: null })
    expect(await readFile(path, 'utf8')).not.toContain(token.slice(4))
    expect(phones.resolve(token)).toEqual({ phoneId: phone.id, computerId: 'c-0123456789', personId: null })
    expect(phones.resolve(`${token}x`)).toBeUndefined()
    expect(phones.resolve('owner-token')).toBeUndefined()
    await phones.settled()
    const reopened = await PhoneTokens.open(path)
    expect(reopened.resolve(token)?.computerId).toBe('c-0123456789')
    expect(reopened.list('c-0123456789')[0]?.lastUsedAt).not.toBeNull()
    await reopened.settled()
  })

  it('lists phones per computer with their last use, and signs one or all out', async () => {
    const phones = PhoneTokens.memory()
    const a = await phones.mint('owner', 'Phone A')
    const b = await phones.mint('owner', 'Phone B')
    const c = await phones.mint('c-0123456789', 'Phone C')
    phones.resolve(a.token, Date.parse('2026-10-28T13:00:00Z'))
    expect(phones.list('owner').map(p => [p.name, p.lastUsedAt])).toEqual([['Phone A', '2026-10-28T13:00:00.000Z'], ['Phone B', null]])
    expect(await phones.revoke('c-0123456789', a.phone.id)).toBe(false)
    expect(await phones.revoke('owner', a.phone.id)).toBe(true)
    expect(phones.resolve(a.token)).toBeUndefined()
    await phones.revokeComputer('owner')
    expect(phones.resolve(b.token)).toBeUndefined()
    expect(phones.resolve(c.token)?.computerId).toBe('c-0123456789')
  })

  it('signs a host phone in to the host, with the person who paired it', async () => {
    const phones = PhoneTokens.memory()
    const person = '33333333-3333-4333-8333-333333333333'
    const host = await phones.mint(null, 'Owner phone', new Date(), person)
    const other = await phones.mint('c-0123456789', 'Kid phone', new Date(), person)
    expect(phones.resolve(host.token)).toEqual({ phoneId: host.phone.id, computerId: null, personId: person })
    // Only a host phone carries a person; a computer phone is its computer's.
    expect(phones.resolve(other.token)?.personId).toBeNull()
    expect(phones.list(null).map(phone => phone.name)).toEqual(['Owner phone'])
    expect(await phones.revoke('c-0123456789', host.phone.id)).toBe(false)
    expect(await phones.revoke(null, host.phone.id)).toBe(true)
    expect(phones.resolve(host.token)).toBeUndefined()
  })

  it('rejects a name it would not show', async () => {
    const phones = PhoneTokens.memory()
    await expect(phones.mint('owner', '')).rejects.toThrow(/name/)
    await expect(phones.mint('owner', 'x'.repeat(61))).rejects.toThrow(/name/)
    await expect(phones.mint('owner', 'tab\there')).rejects.toThrow(/name/)
  })
})

describe('PairingCodes', () => {
  it('pairs once, within ten minutes, and forgets a deleted computer', () => {
    let now = Date.parse('2026-10-28T12:00:00Z')
    const codes = new PairingCodes(10 * 60_000, () => now)
    const first = codes.issue('owner')
    expect(first).toEqual({ code: expect.stringMatching(/^[ABCDEFGHJKMNPQRSTVWXYZ2-9]{8}$/), expiresAt: '2026-10-28T12:10:00.000Z' })
    expect(codes.redeem(first.code.toLowerCase())).toEqual({ computerId: 'owner', personId: null })
    expect(codes.redeem(first.code)).toBeUndefined()
    const late = codes.issue('owner')
    now += 10 * 60_000
    expect(codes.redeem(late.code)).toBeUndefined()
    const gone = codes.issue('c-0123456789')
    codes.revokeComputer('c-0123456789')
    expect(codes.redeem(gone.code)).toBeUndefined()
  })

  it('issues host codes that carry the issuing person', () => {
    const codes = new PairingCodes()
    const person = '33333333-3333-4333-8333-333333333333'
    const host = codes.issue(null, person)
    expect(codes.redeem(host.code)).toEqual({ computerId: null, personId: person })
    // A computer's code never carries a person.
    expect(codes.redeem(codes.issue('c-0123456789', person).code)).toEqual({ computerId: 'c-0123456789', personId: null })
  })

  it('pauses pairing after a burst of wrong codes', () => {
    let now = 0
    const codes = new PairingCodes(10 * 60_000, () => now)
    const good = codes.issue('owner')
    for (let attempt = 0; attempt < 20; attempt++) expect(codes.redeem('AAAAAAAA')).toBeUndefined()
    expect(() => codes.redeem(good.code)).toThrow(/Too many/)
    now += 60_000
    expect(codes.redeem(good.code)).toEqual({ computerId: 'owner', personId: null })
  })
})
