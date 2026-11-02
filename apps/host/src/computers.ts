import type pg from 'pg'
import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto'
import { access } from 'node:fs/promises'
import { join } from 'node:path'
import { MAX_SLOTS } from './network.js'
import { readJsonFile, SettingsInputError, writePrivateJson } from './settings.js'
import { ComputerStore } from './identity/computer-store.js'
import type { IdentityDatabase } from './identity/database.js'

/**
 * The computers a host runs, all alike: a host may have none, and any can be deleted. Each
 * keeps its own files under `computers/<id>/`. A computer's id is `c-` followed by ten hex
 * digits; a host from before computers were equal keeps its first computer under the legacy id
 * `owner` and slot 0. A slot names a computer's network: a new computer gets the lowest free
 * one from 1, and a deleted computer's slot is freed.
 */
export const LEGACY_COMPUTER = 'owner'
export const COMPUTER_ID_PATTERN = /^(?:owner|c-[0-9a-f]{10})$/

/**
 * `createdAt` is null for a legacy computer made before the host recorded it. `tenantId` is
 * the tenant the computer belongs to, null until the host is set up; `person` is the name of
 * the one person whose computer it is, who uses it from their phone.
 */
export interface ComputerRecord { id: string; slot: number; createdAt: string | null; tenantId: string | null; person: string | null; personId?: string | null }

/** What the registry keeps about a computer besides its identity. */
export type ComputerAssignment = Pick<ComputerRecord, 'tenantId' | 'person' | 'personId'>

export class ComputerCapacityError extends Error {}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
/** The registry file's format: version 2 lists every computer; earlier files left out the legacy one. */
const REGISTRY_VERSION = 2

export function personName(value: unknown): string | null {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string' || !value.trim() || value.trim().length > 80 || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new SettingsInputError('person must be 1–80 characters without control characters, or null')
  }
  return value.trim()
}

function assignment(v: Record<string, unknown>): ComputerAssignment {
  const tenantId = v.tenantId ?? null
  if (tenantId !== null && (typeof tenantId !== 'string' || !UUID.test(tenantId))) throw new Error('Invalid computer tenant')
  return { tenantId, person: personName(v.person) }
}

/** Slot 0 belongs only to the legacy computer; every other computer has a slot from 1. */
function record(value: unknown): ComputerRecord {
  const v = value as Record<string, unknown> | null
  if (!v || typeof v !== 'object' || typeof v.id !== 'string' || !COMPUTER_ID_PATTERN.test(v.id)
    || typeof v.slot !== 'number' || !Number.isSafeInteger(v.slot) || v.slot < 0 || v.slot >= MAX_SLOTS || (v.slot === 0) !== (v.id === LEGACY_COMPUTER)
    || (typeof v.createdAt !== 'string' && !(v.createdAt === null && v.id === LEGACY_COMPUTER))) {
    throw new Error('Invalid computer record')
  }
  return { id: v.id, slot: v.slot, createdAt: v.createdAt as string | null, ...assignment(v) }
}

/**
 * Files a host from before computers were equal kept at its image root. Any one of them means
 * the host ran its built-in computer, which the registry then keeps as the legacy computer.
 */
export const LEGACY_ROOT_FILES = ['caboose.json', 'push-devices.json', 'activities.json', 'container.json', 'agent-profiles.json', 'services.json',
  'commands', 'mcp-library.json', 'keyring-secret', 'agent-tool-receipts.json', 'agent-routines.json'] as const
const LEGACY_EVIDENCE = ['computers.json', 'host-id', 'phones.json', ...LEGACY_ROOT_FILES, `overlays/${LEGACY_COMPUTER}.raw`, `overlays/${LEGACY_COMPUTER}.snapshot`]

/** The computers a registry file lists, the legacy computer included when the file (or the host) predates version 2. */
async function readRegistryFile(root: string, path: string): Promise<ComputerRecord[]> {
  const value = await readJsonFile(path)
  if (value !== undefined && (!value || typeof value !== 'object' || !Array.isArray((value as { computers?: unknown }).computers))) throw new Error('Invalid computer registry')
  const stored = value as { version?: unknown; computers: unknown[]; owner?: Record<string, unknown>; ownerCreatedAt?: unknown } | undefined
  if (stored?.version === REGISTRY_VERSION) return stored.computers.map(record)
  const others = (stored?.computers ?? []).map(record)
  if (others.some(c => c.id === LEGACY_COMPUTER)) throw new Error('Invalid computer record')
  if (!stored && !(await Promise.all(LEGACY_EVIDENCE.map(name => exists(join(root, name))))).some(Boolean)) return []
  // Registries from before tenants kept only the built-in computer's creation time.
  const meta = stored?.owner ?? {}
  const createdAt = typeof meta.createdAt === 'string' ? meta.createdAt : typeof stored?.ownerCreatedAt === 'string' ? stored.ownerCreatedAt : null
  return [{ id: LEGACY_COMPUTER, slot: 0, createdAt, ...assignment(meta) }, ...others]
}

async function exists(path: string): Promise<boolean> {
  return access(path).then(() => true, () => false)
}

export class ComputerRegistry {
  private pending: Promise<void> = Promise.resolve()
  private failure: unknown
  private constructor(readonly root: string, private path: string, private records: ComputerRecord[], private store?: ComputerStore) {}

  static async open(root: string, database?: IdentityDatabase): Promise<ComputerRegistry> {
    const path = join(root, 'computers.json')
    const store = database ? new ComputerStore(database.pool) : undefined
    if (store) return new ComputerRegistry(root, path, await store.initialize(() => readRegistryFile(root, path)), store)
    const value = await readJsonFile(path)
    const records = await readRegistryFile(root, path)
    if (new Set(records.map(c => c.id)).size !== records.length || new Set(records.map(c => c.slot)).size !== records.length) throw new Error('Duplicate computer in the registry')
    // Settle the format at once, so a later start never mistakes this host for an older one.
    if ((value as { version?: unknown } | undefined)?.version !== REGISTRY_VERSION) await writePrivateJson(path, { version: REGISTRY_VERSION, computers: records })
    return new ComputerRegistry(root, path, records)
  }

  /** Serialize changes made by identity setup/people with registry writes, then refresh. */
  async synchronize<T>(work: () => Promise<T>): Promise<T> {
    const next = this.pending.then(async () => {
      try { return await work() } finally {
        if (this.store) {
          try { this.records = await this.store.load(); this.failure = undefined }
          catch (error) { this.failure = error; throw error }
        }
      }
    })
    this.pending = next.then(() => {}, () => {})
    return next
  }

  list(): ComputerRecord[] {
    if (this.failure) throw new Error('Computer ownership is unavailable; restart the host to reload it', { cause: this.failure })
    return this.records.map(c => ({ ...c }))
  }

  get(id: string): ComputerRecord | undefined { return this.list().find(c => c.id === id) }

  /** Where a computer's own files live. */
  dataDir(id: string): string {
    if (!COMPUTER_ID_PATTERN.test(id)) throw new Error('Invalid computer id')
    return join(this.root, 'computers', id)
  }

  private save(change: (records: ComputerRecord[]) => ComputerRecord[]): Promise<void> {
    const work = this.pending.then(async () => {
      const next = change(this.list())
      if (this.store) {
        try { this.records = await this.store.save(this.list(), next) }
        catch (error) {
          // A lost commit acknowledgement must never leave old authorization cached.
          if (!(error instanceof SettingsInputError)) this.failure = error
          throw error
        }
      } else {
        await writePrivateJson(this.path, { version: REGISTRY_VERSION, computers: next })
        this.records = next
      }
    })
    this.pending = work.catch(() => {})
    return work
  }

  async create(assigned: ComputerAssignment = { tenantId: null, person: null }, now = new Date()): Promise<ComputerRecord> {
    let made: ComputerRecord | undefined
    await this.save(records => {
      const taken = new Set(records.map(c => c.slot))
      let slot = 1
      while (taken.has(slot)) slot++
      if (slot >= MAX_SLOTS) throw new ComputerCapacityError(`A host runs at most ${MAX_SLOTS - 1} computers`)
      let id: string
      do id = `c-${randomBytes(5).toString('hex')}`; while (records.some(c => c.id === id))
      made = { id, slot, createdAt: now.toISOString(), ...assigned, person: personName(assigned.person) }
      return [...records, made]
    })
    return this.get(made!.id)!
  }

  /** Moves a computer to a tenant, or names its person; fields left out are kept. */
  async assign(id: string, change: Partial<ComputerAssignment>): Promise<ComputerRecord> {
    const update = (current: ComputerAssignment): ComputerAssignment => ({
      tenantId: change.tenantId !== undefined ? change.tenantId : current.tenantId,
      person: change.person !== undefined ? personName(change.person) : current.person,
      ...(change.personId !== undefined ? { personId: change.personId } : current.personId !== undefined ? { personId: current.personId } : {}),
    })
    await this.save(records => {
      if (!records.some(c => c.id === id)) throw new SettingsInputError('computer not found')
      return records.map(c => c.id === id ? { ...c, ...update(c) } : c)
    })
    return this.get(id)!
  }

  /** Puts every computer that has no tenant yet in this one, as setting the host up does. */
  async adoptUnassigned(tenantId: string): Promise<void> {
    await this.save(records => records.map(c => c.tenantId ? c : { ...c, tenantId }))
  }

  async remove(id: string): Promise<void> {
    await this.save(records => records.filter(c => c.id !== id))
  }
}

/**
 * Sign-in tokens for phones. A computer phone is bound to one computer; a host phone
 * (`computerId` null) signs its owner in to the host, with the owner token's reach, and
 * remembers the person of the account that paired it (`personId`), whose computers it makes.
 * The host keeps only a SHA-256 of each token, so a token is shown once, when it is made;
 * revoking one signs that phone out.
 */
export interface PhoneSummary { id: string; name: string; createdAt: string; lastUsedAt: string | null }
interface PhoneEntry extends PhoneSummary { computerId: string | null; personId: string | null; hash: string }
export interface PhoneSignIn { phoneId: string; computerId: string | null; personId: string | null }

const PHONE_ID = /^p-[0-9a-f]{12}$/
const HASH = /^[0-9a-f]{64}$/
const TOKEN_PREFIX = 'cbp_'
const USE_PERSIST_MS = 60_000

function digest(token: string): string { return createHash('sha256').update(token, 'utf8').digest('hex') }

export function phoneName(value: unknown): string {
  if (typeof value !== 'string' || !value.trim() || value.trim().length > 60 || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new SettingsInputError('name must be 1–60 characters without control characters')
  }
  return value.trim()
}

function phoneEntry(value: unknown): PhoneEntry {
  const v = value as Record<string, unknown> | null
  if (!v || typeof v !== 'object' || typeof v.id !== 'string' || !PHONE_ID.test(v.id) || (v.computerId !== null && (typeof v.computerId !== 'string' || !COMPUTER_ID_PATTERN.test(v.computerId)))
    || (v.personId !== undefined && v.personId !== null && (typeof v.personId !== 'string' || !UUID.test(v.personId)))
    || typeof v.hash !== 'string' || !HASH.test(v.hash) || typeof v.createdAt !== 'string' || (v.lastUsedAt !== null && typeof v.lastUsedAt !== 'string')) {
    throw new Error('Invalid phone sign-in')
  }
  return { id: v.id, computerId: v.computerId as string | null, personId: (v.personId ?? null) as string | null, name: phoneName(v.name), hash: v.hash, createdAt: v.createdAt, lastUsedAt: v.lastUsedAt as string | null }
}

export class PhoneTokens {
  private pending: Promise<void> = Promise.resolve()
  private lastPersisted = new Map<string, number>()
  private constructor(private path: string, private entries: PhoneEntry[], private pool?: pg.Pool) {}

  static async open(path: string, pool?: pg.Pool): Promise<PhoneTokens> {
    if (pool) {
      await pool.query("CREATE TABLE IF NOT EXISTS caboose_cluster_phones (id integer PRIMARY KEY CHECK(id=1), entries jsonb NOT NULL)")
      const local = await readJsonFile(path)
      await pool.query('INSERT INTO caboose_cluster_phones VALUES(1,$1) ON CONFLICT DO NOTHING', [JSON.stringify(local ?? [])])
      const tokens = new PhoneTokens(path, [], pool)
      await tokens.refresh()
      return tokens
    }
    const value = await readJsonFile(path)
    if (value !== undefined && !Array.isArray(value)) throw new Error('Invalid phone sign-in store')
    return new PhoneTokens(path, (value ?? []).map(phoneEntry))
  }

  async refresh(): Promise<void> {
    if (!this.pool) return
    const result = await this.pool.query('SELECT entries FROM caboose_cluster_phones WHERE id=1')
    this.entries = result.rows[0].entries.map(phoneEntry)
  }

  /** An in-memory store, for a host that keeps none on disk (tests). */
  static memory(): PhoneTokens { return new PhoneTokens('', []) }

  private save(change: (entries: PhoneEntry[]) => PhoneEntry[]): Promise<void> {
    const work = this.pending.then(async () => {
      if (this.pool) {
        const client = await this.pool.connect()
        try {
          await client.query('BEGIN')
          const result = await client.query('SELECT entries FROM caboose_cluster_phones WHERE id=1 FOR UPDATE')
          const next = change(result.rows[0].entries.map(phoneEntry))
          await client.query('UPDATE caboose_cluster_phones SET entries=$1 WHERE id=1', [JSON.stringify(next)])
          await client.query('COMMIT')
          this.entries = next
        } catch(error) { await client.query('ROLLBACK'); throw error } finally { client.release() }
      } else {
        const next = change(this.entries.map(e => ({ ...e })))
        if (this.path) await writePrivateJson(this.path, next)
        this.entries = next
      }
    })
    this.pending = work.catch(() => {})
    return work
  }

  /** The phones signed in to a computer, or with `null` the host phones. */
  list(computerId: string | null): PhoneSummary[] {
    return this.entries.filter(e => e.computerId === computerId).map(({ id, name, createdAt, lastUsedAt }) => ({ id, name, createdAt, lastUsedAt }))
  }

  async mint(computerId: string | null, name: unknown, now = new Date(), personId: string | null = null): Promise<{ phone: PhoneSummary; token: string }> {
    const entry: PhoneEntry = { id: `p-${randomBytes(6).toString('hex')}`, computerId, personId: computerId ? null : personId, name: phoneName(name), hash: '', createdAt: now.toISOString(), lastUsedAt: null }
    const token = `${TOKEN_PREFIX}${randomBytes(32).toString('base64url')}`
    entry.hash = digest(token)
    await this.save(entries => [...entries, entry])
    const { id, name: label, createdAt, lastUsedAt } = entry
    return { phone: { id, name: label, createdAt, lastUsedAt }, token }
  }

  /** False when the phone is not signed in to this computer (or, with `null`, to the host). */
  async revoke(computerId: string | null, id: string): Promise<boolean> {
    let removed = false
    await this.save(entries => {
      removed = entries.some(e => e.id === id && e.computerId === computerId)
      return entries.filter(e => !(e.id === id && e.computerId === computerId))
    })
    return removed
  }

  async revokeComputer(computerId: string): Promise<void> {
    await this.save(entries => entries.filter(e => e.computerId !== computerId))
  }

  /** Resolves once every write already started has finished. */
  async settled(): Promise<void> { await this.pending }

  /** The phone a bearer token signs in, if any. Its last use is kept, written at most once a minute. */
  resolve(token: string, now = Date.now()): PhoneSignIn | undefined {
    if (!token.startsWith(TOKEN_PREFIX)) return undefined
    const candidate = Buffer.from(digest(token), 'hex')
    const entry = this.entries.find(e => timingSafeEqual(Buffer.from(e.hash, 'hex'), candidate))
    if (!entry) return undefined
    entry.lastUsedAt = new Date(now).toISOString()
    if (now - (this.lastPersisted.get(entry.id) ?? 0) >= USE_PERSIST_MS) {
      this.lastPersisted.set(entry.id, now)
      const { id, lastUsedAt } = entry
      void this.save(entries => entries.map(e => e.id === id ? { ...e, lastUsedAt } : e)).catch(error => console.error('Could not record a phone sign-in:', error))
    }
    return { phoneId: entry.id, computerId: entry.computerId, personId: entry.personId }
  }
}

/**
 * Single-use pairing codes, for one computer or (`computerId` null) for the host. The console
 * shows one as a link and a QR code; the phone trades it through `POST /v1/pair` for its own
 * sign-in token, so no token is ever shown. Codes live
 * in memory for ten minutes, and a burst of wrong codes pauses pairing for everyone briefly,
 * which keeps guessing one hopeless.
 */
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTVWXYZ23456789'
const CODE_LENGTH = 8
const FAILURE_WINDOW_MS = 60_000
const MAX_FAILURES = 20

export class PairingRateLimitError extends Error {}

/** A computer, or the host (`computerId` null) and the person whose account issued the code. */
export interface PairingGrant { computerId: string | null; personId: string | null }

export class PairingCodes {
  private codes = new Map<string, PairingGrant & { expiresAt: number }>()
  private failures: number[] = []

  constructor(private readonly ttlMs = 10 * 60_000, private readonly now: () => number = Date.now) {}

  issue(computerId: string | null, personId: string | null = null): { code: string; expiresAt: string } {
    this.sweep()
    let code: string
    do code = Array.from({ length: CODE_LENGTH }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('')
    while (this.codes.has(code))
    const expiresAt = this.now() + this.ttlMs
    this.codes.set(code, { computerId, personId: computerId ? null : personId, expiresAt })
    return { code, expiresAt: new Date(expiresAt).toISOString() }
  }

  /** What a code pairs with, once; spaces, dashes and case are forgiven. */
  redeem(input: unknown): PairingGrant | undefined {
    const now = this.now()
    this.failures = this.failures.filter(at => now - at < FAILURE_WINDOW_MS)
    if (this.failures.length >= MAX_FAILURES) throw new PairingRateLimitError('Too many wrong pairing codes; try again in a minute')
    this.sweep()
    const code = typeof input === 'string' ? input.toUpperCase().replace(/[\s-]/g, '') : ''
    const entry = this.codes.get(code)
    if (!entry) {
      this.failures.push(now)
      return undefined
    }
    this.codes.delete(code)
    return { computerId: entry.computerId, personId: entry.personId }
  }

  revokeComputer(computerId: string): void {
    for (const [code, entry] of this.codes) if (entry.computerId === computerId) this.codes.delete(code)
  }

  private sweep(): void {
    const now = this.now()
    for (const [code, entry] of this.codes) if (entry.expiresAt <= now) this.codes.delete(code)
  }
}
