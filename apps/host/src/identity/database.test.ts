import { mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it } from 'vitest'
import { openIdentityDatabase } from './database.js'
import { tenants } from '@braedonsaunders/appkit-db/schema'

it('keeps an embedded database in the state directory, migrated, private and durable', async () => {
  const root = await mkdtemp(join(tmpdir(), 'caboose-identity-'))
  try {
    const dataDir = join(root, 'long-home-directory-'.repeat(8), 'Application Support/Caboose/disks/identity')
    const first = await openIdentityDatabase({ dataDir })
    expect(first.kind).toBe('pglite')
    const socketDir = first.pool.options.host!
    expect((await stat(socketDir)).mode & 0o777).toBe(0o700)
    await first.db.insert(tenants).values({ name: 'Home', slug: 'home' })
    // Recreate the previous constraint and migration state, then reopen as an upgrade.
    await first.pool.query('ALTER TABLE caboose_computers DROP CONSTRAINT caboose_computers_slot_check')
    await first.pool.query('ALTER TABLE caboose_computers ADD CONSTRAINT caboose_computers_slot_check CHECK (slot BETWEEN 0 AND 63)')
    await first.pool.query('DELETE FROM drizzle.__caboose_migrations WHERE created_at = 1793203200002')
    await first.pool.query("INSERT INTO caboose_computers(id, slot, assignment_pending) VALUES ('c-0123456788', 63, true)")
    const tables = await first.pool.query("select table_name from information_schema.tables where table_schema = 'public' order by 1")
    expect(tables.rows.map(row => row.table_name)).toEqual(expect.arrayContaining(['users', 'sessions', 'accounts', 'verifications', 'tenants', 'tenant_users', 'caboose_invites']))
    await first.close()
    await expect(stat(socketDir)).rejects.toMatchObject({ code: 'ENOENT' })
    expect((await stat(dataDir)).mode & 0o777).toBe(0o700)
    const again = await openIdentityDatabase({ dataDir })
    expect((await again.db.select().from(tenants)).map(row => row.name)).toEqual(['Home'])
    expect((await again.pool.query("SELECT slot FROM caboose_computers WHERE id='c-0123456788'")).rows[0].slot).toBe(63)
    await again.pool.query("INSERT INTO caboose_computers(id, slot, assignment_pending) VALUES ('c-0123456789', 64, true)")
    expect((await again.pool.query("SELECT slot FROM caboose_computers WHERE id='c-0123456789'")).rows[0].slot).toBe(64)
    await again.close()
  } finally { await rm(root, { recursive: true, force: true }) }
}, 60_000)
