import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, expect, it } from 'vitest'
import { ComputerRegistry } from '../computers.js'
import { openIdentityDatabase, type IdentityDatabase } from './database.js'
import { Identity } from './service.js'

let root: string
let database: IdentityDatabase
let identity: Identity
let registry: ComputerRegistry
beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), 'caboose-ownership-'))
  database = await openIdentityDatabase({ dataDir: join(root, 'identity') })
  identity = Identity.create({ database, baseURL: 'http://localhost:7310', secret: 'x'.repeat(40), setupCodePath: join(root, 'setup-code') })
  registry = await ComputerRegistry.open(root, database)
}, 60_000)
afterAll(async () => { await database.close(); await rm(root, { recursive: true, force: true }) })

it('rolls back the entire setup if assigning the existing computer fails, then retries safely', async () => {
  const code = await identity.setupCode()
  const input = { code, name: 'Owner', email: 'owner@example.com', password: 'a proper password', tenantName: 'Home' }
  await database.pool.query(`CREATE FUNCTION reject_assignment() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'simulated assignment failure'; END $$;
    CREATE TRIGGER reject_assignment BEFORE UPDATE ON caboose_computers FOR EACH ROW EXECUTE FUNCTION reject_assignment()`)
  await expect(registry.synchronize(() => identity.claim(input))).rejects.toThrow()
  expect(await identity.claimed()).toBe(false)
  expect(await identity.tenants()).toEqual([])
  expect(registry.get('owner')?.personId).toBeNull()
  expect(await identity.setupCode()).toBe(code)
  expect(Number((await database.pool.query('SELECT count(*) n FROM accounts')).rows[0].n)).toBe(0)
  await database.pool.query('DROP TRIGGER reject_assignment ON caboose_computers; DROP FUNCTION reject_assignment()')
  const claimed = await registry.synchronize(() => identity.claim(input))
  expect(registry.get('owner')).toMatchObject({ tenantId: claimed.tenantId, personId: claimed.personId, person: 'Owner', slot: 0 })
  expect((await identity.signIn(input.email, input.password, new Headers())).status).toBe(200)
  expect((await ComputerRegistry.open(root, database)).get('owner')).toEqual(registry.get('owner'))
})

it('enforces person membership and referential integrity in the database, including concurrent deletion', async () => {
  const owner = registry.get('owner')!
  const other = await identity.createTenant({ name: 'Other' })
  const person = await identity.createPerson(other.id, { name: 'Sam' })
  await expect(registry.assign('owner', { tenantId: other.id, personId: owner.personId })).rejects.toThrow(/person.*tenant/i)
  expect(registry.get('owner')).toEqual(owner)
  await expect(identity.deletePerson(owner.personId!)).rejects.toThrow(/Reassign/)
  await expect(identity.deleteTenant(owner.tenantId!)).rejects.toThrow(/computers first/)
  // The rejected deletion rolls back both people and administrator memberships.
  expect((await identity.people(owner.tenantId!)).length).toBe(1)
  expect((await identity.administrators(owner.tenantId!)).length).toBe(1)
  await registry.assign('owner', { tenantId: other.id, personId: person.id, person: person.name })
  expect(registry.get('owner')?.personId).toBe(person.id)
  const direct = await database.pool.connect()
  try {
    await direct.query('BEGIN')
    await expect(direct.query('DELETE FROM caboose_people WHERE id=$1', [person.id])).rejects.toHaveProperty('constraint', 'caboose_computers_person_tenant_fk')
    await direct.query('ROLLBACK')
  } finally { direct.release() }
  const unused = await identity.createPerson(other.id, { name: 'Unused' })
  await identity.deletePerson(unused.id)
  await expect(registry.assign('owner', { personId: unused.id })).rejects.toThrow(/person.*tenant/i)
  expect(registry.get('owner')?.personId).toBe(person.id)
  await registry.synchronize(() => identity.updatePerson(person.id, { name: 'Samuel' }))
  expect(registry.get('owner')?.person).toBe('Samuel')
})

it('imports legacy slots and named people atomically without guessing identities or reimporting stale JSON', async () => {
  const legacyRoot = await mkdtemp(join(tmpdir(), 'caboose-legacy-ownership-'))
  const legacyDatabase = await openIdentityDatabase({ dataDir: join(legacyRoot, 'identity') })
  try {
    const { rows: [tenant] } = await legacyDatabase.pool.query("INSERT INTO tenants(name,slug) VALUES('Legacy','legacy') RETURNING id")
    const legacy = { owner: { tenantId: tenant.id, person: 'Same name', createdAt: null }, computers: [
      { id: 'c-123456789a', slot: 5, tenantId: tenant.id, person: 'Same name', createdAt: '2026-01-01T00:00:00Z' },
      { id: 'c-123456789b', slot: 6, tenantId: tenant.id, person: null, createdAt: '2026-01-01T00:00:00Z' },
    ] }
    const path = join(legacyRoot, 'computers.json')
    const invalid = structuredClone(legacy)
    invalid.computers[1]!.tenantId = '00000000-0000-4000-8000-000000000001'
    await writeFile(path, JSON.stringify(invalid))
    await expect(ComputerRegistry.open(legacyRoot, legacyDatabase)).rejects.toThrow()
    expect(Number((await legacyDatabase.pool.query('SELECT count(*) n FROM caboose_computers')).rows[0].n)).toBe(0)
    expect(Number((await legacyDatabase.pool.query('SELECT count(*) n FROM caboose_people')).rows[0].n)).toBe(0)
    await writeFile(path, JSON.stringify(legacy))
    const imported = await ComputerRegistry.open(legacyRoot, legacyDatabase)
    expect(imported.list().map(record => record.slot)).toEqual([0, 5, 6])
    expect(imported.get('owner')!.personId).not.toBe(imported.get('c-123456789a')!.personId)
    expect(imported.get('c-123456789b')).toMatchObject({ tenantId: tenant.id, personId: null })
    await imported.remove('c-123456789a')
    expect(JSON.parse(await readFile(path, 'utf8'))).toEqual(legacy)
    await writeFile(path, 'old backup is no longer authoritative')
    expect((await ComputerRegistry.open(legacyRoot, legacyDatabase)).get('c-123456789a')).toBeUndefined()
    expect(Number((await legacyDatabase.pool.query('SELECT count(*) n FROM caboose_people')).rows[0].n)).toBe(2)
  } finally { await legacyDatabase.close(); await rm(legacyRoot, { recursive: true, force: true }) }
}, 60_000)
