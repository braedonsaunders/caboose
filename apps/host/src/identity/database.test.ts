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
    const tables = await first.pool.query("select table_name from information_schema.tables where table_schema = 'public' order by 1")
    expect(tables.rows.map(row => row.table_name)).toEqual(expect.arrayContaining(['users', 'sessions', 'accounts', 'verifications', 'tenants', 'tenant_users', 'caboose_invites']))
    await first.close()
    await expect(stat(socketDir)).rejects.toMatchObject({ code: 'ENOENT' })
    expect((await stat(dataDir)).mode & 0o777).toBe(0o700)
    const again = await openIdentityDatabase({ dataDir })
    expect((await again.db.select().from(tenants)).map(row => row.name)).toEqual(['Home'])
    await again.close()
  } finally { await rm(root, { recursive: true, force: true }) }
}, 60_000)
