import type pg from 'pg'
import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto'
import { join } from 'node:path'
import { MAX_SLOTS } from './network.js'
import { readJsonFile, SettingsInputError, writePrivateJson } from './settings.js'
import { ComputerStore } from './identity/computer-store.js'
import type { IdentityDatabase } from './identity/database.js'

/**
 * The computers a host runs. The owner's computer is always there: it has id `owner` and
 * slot 0, and keeps the files a host had before it ran several (`caboose.json`,
 * `push-devices.json` and `activities.json` at the image root). Every other computer keeps its
 * own under `computers/<id>/`. A slot names a computer's network; it is
 * the lowest one free when the computer is made, and freed when it is deleted.
 */
export const OWNER_COMPUTER = 'owner'
export const COMPUTER_ID_PATTERN = /^(?:owner|c-[0-9a-f]{10})$/

/**
 * `createdAt` is null for an owner's computer made before the host recorded it. `tenantId` is
 * the tenant the computer belongs to, null until the host is set up; `person` is the name of
 * the one person whose computer it is, who uses it from their phone.
 */
export interface ComputerRecord { id: string; slot: number; createdAt: string | null; tenantId: string | null; person: string | null; personId?: string | null }

/** What the registry keeps about a computer besides its identity. */
export type ComputerAssignment = Pick<ComputerRecord, 'tenantId' | 'person' | 'personId'>

export class ComputerCapacityError extends Error {}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

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

function record(value: unknown): ComputerRecord {
  const v = value as Record<string, unknown> | null
  if (!v || typeof v !== 'object' || typeof v.id !== 'string' || !COMPUTER_ID_PATTERN.test(v.id) || v.id === OWNER_COMPUTER
    || typeof v.slot !== 'number' || !Number.isSafeInteger(v.slot) || v.slot < 1 || v.slot >= MAX_SLOTS || typeof v.createdAt !== 'string') {
    throw new Error('Invalid computer record')
  }
  return { id: v.id, slot: v.slot, createdAt: v.createdAt, ...assignment(v) }
}

interface OwnerMeta extends ComputerAssignment { createdAt: string | null }

export class ComputerRegistry {
  private pending: Promise<void> = Promise.resolve()
  private failure: unknown
  private constructor(readonly root: string, private path: string, private others: ComputerRecord[], private owner: OwnerMeta, private store?: ComputerStore) {}

  static async open(root: string, database?: IdentityDatabase): Promise<ComputerRegistry> {
    const path = join(root, 'computers.json')
    const store = database ? new ComputerStore(database.pool) : undefined
    const persisted = store ? await store.load() : []
    if (persisted.length) {
      const registry = new ComputerRegistry(root, path, [], { createdAt: null, tenantId: null, person: null }, store)
      registry.install(persisted)
      return registry
    }
    const value = await readJsonFile(path)
    if (value !== undefined && (!value || typeof value !== 'object' || !Array.isArray((value as { computers?: unknown }).computers))) throw new Error('Invalid computer registry')
    const stored = value as { computers: unknown[]; owner?: Record<string, unknown>; ownerCreatedAt?: unknown } | undefined
    const others = (stored?.computers ?? []).map(record)
    if (new Set(others.map(c => c.id)).size !== others.length || new Set(others.map(c => c.slot)).size !== others.length) throw new Error('Duplicate computer in the registry')
    // Registries from before tenants kept only the owner's computer's creation time.
    const meta = stored?.owner ?? {}
    const createdAt = typeof meta.createdAt === 'string' ? meta.createdAt : typeof stored?.ownerCreatedAt === 'string' ? stored.ownerCreatedAt : null
    const registry = new ComputerRegistry(root, path, others, { createdAt, ...assignment(meta) }, store)
    if (registry.store) registry.install(await registry.store.initialize(registry.list()))
    return registry
  }

  private install(records: ComputerRecord[]) {
    const owner = records.find(record => record.id === OWNER_COMPUTER)
    if (!owner) throw new Error('Computer database has no owner computer')
    const { id: _id, slot: _slot, ...meta } = owner
    this.owner = meta
    this.others = records.filter(record => record.id !== OWNER_COMPUTER)
  }

  /** Serialize changes made by identity setup/people with registry writes, then refresh. */
  async synchronize<T>(work: () => Promise<T>): Promise<T> {
    const next = this.pending.then(async () => {
      try { return await work() } finally {
        if (this.store) {
          try { this.install(await this.store.load()); this.failure = undefined }
          catch (error) { this.failure = error; throw error }
        }
      }
    })
    this.pending = next.then(() => {}, () => {})
    return next
  }

  list(): ComputerRecord[] {
    if (this.failure) throw new Error('Computer ownership is unavailable; restart the host to reload it', { cause: this.failure })
    return [{ id: OWNER_COMPUTER, slot: 0, ...this.owner }, ...this.others.map(c => ({ ...c }))]
  }

  get(id: string): ComputerRecord | undefined { return this.list().find(c => c.id === id) }

  /** Where a computer's own files live: the image root for the owner's, `computers/<id>` otherwise. */
  dataDir(id: string): string { return id === OWNER_COMPUTER ? this.root : join(this.root, 'computers', id) }

  private save(change: (others: ComputerRecord[], owner: OwnerMeta) => { others: ComputerRecord[]; owner: OwnerMeta }): Promise<void> {
    const work = this.pending.then(async () => {
      const next = change(this.others.map(c => ({ ...c })), { ...this.owner })
      if (this.store) {
        try { this.install(await this.store.save(this.list(), [{ id: OWNER_COMPUTER, slot: 0, ...next.owner }, ...next.others])) }
        catch (error) {
          // A lost commit acknowledgement must never leave old authorization cached.
          if (!(error instanceof SettingsInputError)) this.failure = error
          throw error
        }
      } else {
        await writePrivateJson(this.path, { owner: next.owner, computers: next.others })
        this.others = next.others
        this.owner = next.owner
      }
    })
    this.pending = work.catch(() => {})
    return work
  }

  async create(assigned: ComputerAssignment = { tenantId: null, person: null }, now = new Date()): Promise<ComputerRecord> {
    let made: ComputerRecord | undefined
    await this.save((others, owner) => {
      const taken = new Set([0, ...others.map(c => c.slot)])
      let slot = 1
      while (taken.has(slot)) slot++
      if (slot >= MAX_SLOTS) throw new ComputerCapacityError(`A host runs at most ${MAX_SLOTS} computers`)
      let id: string
      do id = `c-${randomBytes(5).toString('hex')}`; while (others.some(c => c.id === id))
      made = { id, slot, createdAt: now.toISOString(), ...assigned, person: personName(assigned.person) }
      return { others: [...others, made], owner }
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
    await this.save((others, owner) => {
      if (id === OWNER_COMPUTER) return { others, owner: { ...owner, ...update(owner) } }
      if (!others.some(c => c.id === id)) throw new SettingsInputError('computer not found')
      return { others: others.map(c => c.id === id ? { ...c, ...update(c) } : c), owner }
    })
    return this.get(id)!
  }

  /** Puts every computer that has no tenant yet in this one, as setting the host up does. */
  async adoptUnassigned(tenantId: string): Promise<void> {
    await this.save((others, owner) => ({
      others: others.map(c => c.tenantId ? c : { ...c, tenantId }),
      owner: owner.tenantId ? owner : { ...owner, tenantId },
    }))
  }

  async remove(id: string): Promise<void> {
    if (id === OWNER_COMPUTER) throw new SettingsInputError("The owner's computer cannot be deleted")
    await this.save((others, owner) => ({ others: others.filter(c => c.id !== id), owner }))
  }
}

/**
 * Sign-in tokens for phones, each bound to one computer. The host keeps only a SHA-256 of
 * each token, so a token is shown once, when it is made; revoking one signs that phone out.
 */
export interface PhoneSummary { id: string; name: string; createdAt: string; lastUsedAt: string | null }
interface PhoneEntry extends PhoneSummary { computerId: string; hash: string }

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
  if (!v || typeof v !== 'object' || typeof v.id !== 'string' || !PHONE_ID.test(v.id) || typeof v.computerId !== 'string' || !COMPUTER_ID_PATTERN.test(v.computerId)
    || typeof v.hash !== 'string' || !HASH.test(v.hash) || typeof v.createdAt !== 'string' || (v.lastUsedAt !== null && typeof v.lastUsedAt !== 'string')) {
    throw new Error('Invalid phone sign-in')
  }
  return { id: v.id, computerId: v.computerId, name: phoneName(v.name), hash: v.hash, createdAt: v.createdAt, lastUsedAt: v.lastUsedAt as string | null }
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

  list(computerId: string): PhoneSummary[] {
    return this.entries.filter(e => e.computerId === computerId).map(({ id, name, createdAt, lastUsedAt }) => ({ id, name, createdAt, lastUsedAt }))
  }

  async mint(computerId: string, name: unknown, now = new Date()): Promise<{ phone: PhoneSummary; token: string }> {
    const entry: PhoneEntry = { id: `p-${randomBytes(6).toString('hex')}`, computerId, name: phoneName(name), hash: '', createdAt: now.toISOString(), lastUsedAt: null }
    const token = `${TOKEN_PREFIX}${randomBytes(32).toString('base64url')}`
    entry.hash = digest(token)
    await this.save(entries => [...entries, entry])
    const { id, name: label, createdAt, lastUsedAt } = entry
    return { phone: { id, name: label, createdAt, lastUsedAt }, token }
  }

  /** False when the phone is not signed in to this computer. */
  async revoke(computerId: string, id: string): Promise<boolean> {
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
  resolve(token: string, now = Date.now()): { phoneId: string; computerId: string } | undefined {
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
    return { phoneId: entry.id, computerId: entry.computerId }
  }
}

/**
 * Single-use pairing codes. The console shows one as a link and a QR code; the phone trades it
 * through `POST /v1/pair` for its own sign-in token, so no token is ever shown. Codes live
 * in memory for ten minutes, and a burst of wrong codes pauses pairing for everyone briefly,
 * which keeps guessing one hopeless.
 */
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTVWXYZ23456789'
const CODE_LENGTH = 8
const FAILURE_WINDOW_MS = 60_000
const MAX_FAILURES = 20

export class PairingRateLimitError extends Error {}

export class PairingCodes {
  private codes = new Map<string, { computerId: string; expiresAt: number }>()
  private failures: number[] = []

  constructor(private readonly ttlMs = 10 * 60_000, private readonly now: () => number = Date.now) {}

  issue(computerId: string): { code: string; expiresAt: string } {
    this.sweep()
    let code: string
    do code = Array.from({ length: CODE_LENGTH }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('')
    while (this.codes.has(code))
    const expiresAt = this.now() + this.ttlMs
    this.codes.set(code, { computerId, expiresAt })
    return { code, expiresAt: new Date(expiresAt).toISOString() }
  }

  /** The computer a code pairs with, once; spaces, dashes and case are forgiven. */
  redeem(input: unknown): string | undefined {
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
    return entry.computerId
  }

  revokeComputer(computerId: string): void {
    for (const [code, entry] of this.codes) if (entry.computerId === computerId) this.codes.delete(code)
  }

  private sweep(): void {
    const now = this.now()
    for (const [code, entry] of this.codes) if (entry.expiresAt <= now) this.codes.delete(code)
  }
}
