import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { ComputerRegistry, OWNER_COMPUTER, PairingCodes, PhoneTokens } from './computers.js'

const roots: string[] = []
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }) })
async function root(): Promise<string> {
  const path = await mkdtemp(join(tmpdir(), 'caboose-computers-'))
  roots.push(path)
  return path
}

describe('ComputerRegistry', () => {
  it("always has the owner's computer, on slot 0 with its files at the image root", async () => {
    const dir = await root()
    const registry = await ComputerRegistry.open(dir)
    expect(registry.list()).toEqual([{ id: OWNER_COMPUTER, slot: 0, createdAt: null }])
    expect(registry.dataDir(OWNER_COMPUTER)).toBe(dir)
    await expect(registry.remove(OWNER_COMPUTER)).rejects.toThrow(/cannot be deleted/)
  })

  it('makes computers on the lowest free slot, keeps them across restarts, and frees a deleted slot', async () => {
    const dir = await root()
    const registry = await ComputerRegistry.open(dir)
    const a = await registry.create(new Date('2026-10-28T12:00:00Z'))
    const b = await registry.create()
    expect(a).toEqual({ id: expect.stringMatching(/^c-[0-9a-f]{10}$/), slot: 1, createdAt: '2026-10-28T12:00:00.000Z' })
    expect(b.slot).toBe(2)
    expect(registry.dataDir(a.id)).toBe(join(dir, 'computers', a.id))
    await registry.remove(a.id)
    expect((await registry.create()).slot).toBe(1)
    const reopened = await ComputerRegistry.open(dir)
    expect(reopened.list().map(c => c.slot)).toEqual([0, 2, 1])
    expect(reopened.get(b.id)).toEqual(b)
  })

  it('refuses a damaged registry rather than forgetting computers', async () => {
    const dir = await root()
    const registry = await ComputerRegistry.open(dir)
    await registry.create()
    const path = join(dir, 'computers.json')
    const stored = JSON.parse(await readFile(path, 'utf8'))
    stored.computers.push({ ...stored.computers[0] })
    const { writeFile } = await import('node:fs/promises')
    await writeFile(path, JSON.stringify(stored))
    await expect(ComputerRegistry.open(dir)).rejects.toThrow(/Duplicate/)
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
    expect(phones.resolve(token)).toEqual({ phoneId: phone.id, computerId: 'c-0123456789' })
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
    expect(codes.redeem(first.code.toLowerCase())).toBe('owner')
    expect(codes.redeem(first.code)).toBeUndefined()
    const late = codes.issue('owner')
    now += 10 * 60_000
    expect(codes.redeem(late.code)).toBeUndefined()
    const gone = codes.issue('c-0123456789')
    codes.revokeComputer('c-0123456789')
    expect(codes.redeem(gone.code)).toBeUndefined()
  })

  it('pauses pairing after a burst of wrong codes', () => {
    let now = 0
    const codes = new PairingCodes(10 * 60_000, () => now)
    const good = codes.issue('owner')
    for (let attempt = 0; attempt < 20; attempt++) expect(codes.redeem('AAAAAAAA')).toBeUndefined()
    expect(() => codes.redeem(good.code)).toThrow(/Too many/)
    now += 60_000
    expect(codes.redeem(good.code)).toBe('owner')
  })
})
