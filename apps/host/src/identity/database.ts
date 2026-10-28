import { chmod, mkdir, rm } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { PGlite } from '@electric-sql/pglite'
import { PGLiteSocketServer } from '@electric-sql/pglite-socket'
import { drizzle, type NodePgDatabase } from 'drizzle-orm/node-postgres'
import { migrate } from 'drizzle-orm/node-postgres/migrator'
import pg from 'pg'
import { schema } from './schema.js'

/**
 * Where accounts, tenants and invites live: Postgres when `CABOOSE_DATABASE_URL` names one,
 * otherwise an embedded PGlite database in the host's state directory, so a personal install
 * needs no database server. PGlite is served over a Unix socket only the host's user can open,
 * and reached through a one-connection pool, so Better Auth and the host's own queries speak
 * plain Postgres to either and never share a session.
 */
export interface IdentityDatabase {
  kind: 'pglite' | 'postgres'
  pool: pg.Pool
  db: NodePgDatabase<typeof schema>
  close(): Promise<void>
}

const SOCKET_PORT = 5432

export async function openIdentityDatabase(options: { url?: string | null; dataDir: string }): Promise<IdentityDatabase> {
  if (options.url) {
    const pool = new pg.Pool({ connectionString: options.url, max: 10 })
    pool.on('error', error => console.error('Identity database connection error:', error.message))
    const db = drizzle(pool, { schema })
    await migrateIdentity(db)
    return { kind: 'postgres', pool, db, close: () => pool.end() }
  }

  await mkdir(options.dataDir, { recursive: true, mode: 0o700 })
  await chmod(options.dataDir, 0o700)
  const socketDir = join(options.dataDir, 'socket')
  await rm(socketDir, { recursive: true, force: true })
  await mkdir(socketDir, { mode: 0o700 })
  const pglite = await PGlite.create(join(options.dataDir, 'pgdata'))
  const server = new PGLiteSocketServer({ db: pglite, path: join(socketDir, `.s.PGSQL.${SOCKET_PORT}`) })
  await server.start()
  const pool = new pg.Pool({ host: socketDir, port: SOCKET_PORT, user: 'postgres', database: 'postgres', max: 1 })
  pool.on('error', error => console.error('Identity database connection error:', error.message))
  const db = drizzle(pool, { schema })
  try {
    await migrateIdentity(db)
  } catch (error) {
    await pool.end().catch(() => {})
    await server.stop().catch(() => {})
    await pglite.close().catch(() => {})
    throw error
  }
  return {
    kind: 'pglite', pool, db,
    async close() {
      await pool.end()
      await server.stop()
      await pglite.close()
    },
  }
}

/** AppKit's identity schema first (its own migration history), then Caboose's tables on top. */
async function migrateIdentity(db: NodePgDatabase<typeof schema>): Promise<void> {
  const require = createRequire(import.meta.url)
  const appkit = dirname(require.resolve('@braedonsaunders/appkit-db/package.json'))
  await migrate(db, { migrationsFolder: join(appkit, 'drizzle'), migrationsTable: '__appkit_db_migrations' })
  await migrate(db, { migrationsFolder: fileURLToPath(new URL('../../migrations', import.meta.url)), migrationsTable: '__caboose_migrations' })
}
