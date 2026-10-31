import { chmod, mkdir, mkdtemp, rm } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
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

export async function openIdentityDatabase(options: { url?: string | null; dataDir: string; queryTimeoutMs?: number }): Promise<IdentityDatabase> {
  if (options.url) {
    const pool = new pg.Pool({ connectionString: options.url, max: 10, query_timeout: options.queryTimeoutMs, connectionTimeoutMillis: options.queryTimeoutMs, statement_timeout: options.queryTimeoutMs })
    pool.on('error', error => console.error('Identity database connection error:', error.message))
    const db = drizzle(pool, { schema })
    await migrateIdentity(db)
    return { kind: 'postgres', pool, db, close: () => pool.end() }
  }

  await mkdir(options.dataDir, { recursive: true, mode: 0o700 })
  await chmod(options.dataDir, 0o700)
  // macOS limits Unix socket paths to 103 bytes. Data directories (especially a normal
  // Application Support install under a long home path) need not fit that limit.
  const socketDir = await mkdtemp(join(process.platform === 'darwin' ? '/tmp' : tmpdir(), 'caboose-db-'))
  let pglite: PGlite | undefined
  let server: PGLiteSocketServer | undefined
  let pool: pg.Pool | undefined
  async function close() {
    try { await pool?.end() } finally {
      try { await server?.stop() } finally {
        try { await pglite?.close() } finally { await rm(socketDir, { recursive: true, force: true }) }
      }
    }
  }
  try {
    pglite = await PGlite.create(join(options.dataDir, 'pgdata'))
    server = new PGLiteSocketServer({ db: pglite, path: join(socketDir, `.s.PGSQL.${SOCKET_PORT}`) })
    await server.start()
    pool = new pg.Pool({ host: socketDir, port: SOCKET_PORT, user: 'postgres', database: 'postgres', max: 1 })
    pool.on('error', error => console.error('Identity database connection error:', error.message))
    const db = drizzle(pool, { schema })
    await migrateIdentity(db)
    return { kind: 'pglite', pool, db, close }
  } catch (error) {
    await close().catch(() => {})
    throw error
  }
}

/** AppKit's identity schema first (its own migration history), then Caboose's tables on top. */
async function migrateIdentity(db: NodePgDatabase<typeof schema>): Promise<void> {
  const require = createRequire(import.meta.url)
  const appkit = dirname(require.resolve('@braedonsaunders/appkit-db/package.json'))
  await migrate(db, { migrationsFolder: join(appkit, 'drizzle'), migrationsTable: '__appkit_db_migrations' })
  await migrate(db, { migrationsFolder: fileURLToPath(new URL('../../migrations', import.meta.url)), migrationsTable: '__caboose_migrations' })
}
