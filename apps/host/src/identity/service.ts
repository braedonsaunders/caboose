import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { rm } from 'node:fs/promises'
import { and, asc, eq, gt, inArray, isNull } from 'drizzle-orm'
import { createAppkitAuth, type AppkitAuth } from '@braedonsaunders/appkit-auth'
import { memberships, tenants, users } from '@braedonsaunders/appkit-db/schema'
import { secretFile } from '../owner-token.js'
import type { IdentityDatabase } from './database.js'
import { invites } from './schema.js'

/**
 * Accounts, tenants and invitations. Accounts belong to administrators, who use the web
 * console; the people whose computers they run use only their phones, which pair with a
 * computer and need no account. The first account is made by claiming the host and is its
 * operator, who sees every tenant. Invitations are links an administrator copies and sends
 * however they like; this host sends no email.
 */

/** Limits on what a tenant's computers are given between them; null is no limit. */
export interface Quotas { memoryMb: number | null; vcpus: number | null; diskGb: number | null }
export const UNLIMITED: Quotas = { memoryMb: null, vcpus: null, diskGb: null }

export interface Tenant { id: string; name: string; quotas: Quotas; createdAt: string }
export interface Administrator { userId: string; name: string; email: string; operator: boolean; joinedAt: string | null }
export interface PendingInvite { id: string; email: string; createdAt: string; expiresAt: string }
export interface InviteDetails { tenantName: string; email: string; expiresAt: string; accountExists: boolean }

/** An administrator signed in to the console. */
export interface AdminPrincipal { kind: 'admin'; userId: string; name: string; email: string; operator: boolean; tenantIds: string[] }

export class IdentityInputError extends Error {}
export class IdentityConflictError extends Error {}
export class IdentityNotFoundError extends Error {}

const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000
const MIN_PASSWORD = 8
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

function digest(value: string): string { return createHash('sha256').update(value, 'utf8').digest('hex') }

function label(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value.trim() || value.trim().length > 80 || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new IdentityInputError(`${field} must be 1–80 characters without control characters`)
  }
  return value.trim()
}

function email(value: unknown): string {
  if (typeof value !== 'string' || value.length > 254 || !EMAIL.test(value.trim())) throw new IdentityInputError('email must be an email address')
  return value.trim().toLowerCase()
}

function password(value: unknown): string {
  if (typeof value !== 'string' || value.length < MIN_PASSWORD || value.length > 256) {
    throw new IdentityInputError(`password must be ${MIN_PASSWORD} to 256 characters`)
  }
  return value
}

export function parseQuotas(value: unknown, current: Quotas = UNLIMITED): Quotas {
  if (value === undefined) return current
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new IdentityInputError('quotas must be an object')
  const input = value as Record<string, unknown>
  const bounds: Record<keyof Quotas, number> = { memoryMb: 1_048_576, vcpus: 1024, diskGb: 1_000_000 }
  const next = { ...current }
  for (const key of Object.keys(input)) {
    if (!(key in bounds)) throw new IdentityInputError(`Unknown quota: ${key}`)
    const field = key as keyof Quotas
    const limit = input[field]
    if (limit !== null && (typeof limit !== 'number' || !Number.isSafeInteger(limit) || limit < 1 || limit > bounds[field])) {
      throw new IdentityInputError(`${field} must be an integer from 1 to ${bounds[field]}, or null for no limit`)
    }
    next[field] = limit as number | null
  }
  return next
}

function quotasOf(settings: Record<string, unknown> | null | undefined): Quotas {
  try { return parseQuotas((settings ?? {}).quotas ?? {}) } catch { return UNLIMITED }
}

function slugFor(name: string): string {
  const base = name.toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'tenant'
  return `${base}-${randomBytes(3).toString('hex')}`
}

export class Identity {
  private claimedOnce = false
  private claiming: Promise<unknown> | undefined

  private constructor(readonly database: IdentityDatabase, readonly auth: AppkitAuth, private readonly setupCodePath: string) {}

  /**
   * `baseURL` is where the console is usually reached; sign-in also accepts requests from
   * whatever origin a browser used to reach this host, since a home server answers on its LAN
   * address, its Tailscale name and loopback alike.
   */
  static create(options: { database: IdentityDatabase; baseURL: string; secret: string; setupCodePath: string }): Identity {
    const auth = createAppkitAuth({
      database: options.database.pool,
      baseURL: options.baseURL,
      secret: options.secret,
      appName: 'Caboose',
      sendEmail: async () => { throw new Error('This host sends no email') },
      trustedOrigins: request => {
        const host = request?.headers.get('host')
        const proto = request?.headers.get('x-forwarded-proto') ?? new URL(request?.url ?? options.baseURL).protocol.replace(':', '')
        return host ? [options.baseURL, `${proto}://${host}`] : [options.baseURL]
      },
      extend: { basePath: '/v1/auth' },
    })
    return new Identity(options.database, auth, options.setupCodePath)
  }

  private get db() { return this.database.db }

  // --- Claiming the host -----------------------------------------------------

  async claimed(): Promise<boolean> {
    if (this.claimedOnce) return true
    const [row] = await this.db.select({ id: users.id }).from(users).limit(1)
    this.claimedOnce = Boolean(row)
    return this.claimedOnce
  }

  /** The one-time code that sets an unclaimed host up, kept in a file the installers read. Null once claimed. */
  async setupCode(): Promise<string | null> {
    if (await this.claimed()) {
      await rm(this.setupCodePath, { force: true })
      return null
    }
    return (await secretFile(this.setupCodePath, 'setup code')).token
  }

  async setupCodeMatches(candidate: unknown): Promise<boolean> {
    const code = await this.setupCode()
    if (!code || typeof candidate !== 'string' || candidate.length !== code.length) return false
    return timingSafeEqual(Buffer.from(candidate), Buffer.from(code))
  }

  /**
   * Makes the operator's account and the first tenant, and gives it every computer the host
   * already runs. Allowed once: with the setup code, or from the host itself.
   */
  async claim(input: Record<string, unknown>, fromLoopback: boolean): Promise<{ userId: string; tenantId: string; email: string }> {
    if (this.claiming) throw new IdentityConflictError('This host is already being set up')
    const work = (async () => {
      if (await this.claimed()) throw new IdentityConflictError('This host is already set up')
      if (!fromLoopback && !await this.setupCodeMatches(input.code)) throw new IdentityInputError('The setup code is missing or wrong')
      const name = label(input.name, 'name')
      const address = email(input.email)
      const secret = password(input.password)
      const tenantName = label(input.tenantName, 'tenantName')
      const userId = await this.createAccount(name, address, secret)
      await this.db.update(users).set({ isSuperAdmin: true, emailVerified: true }).where(eq(users.id, userId))
      const tenant = await this.createTenant({ name: tenantName })
      await this.addMembership(tenant.id, userId, name)
      this.claimedOnce = true
      await rm(this.setupCodePath, { force: true })
      return { userId, tenantId: tenant.id, email: address }
    })()
    this.claiming = work
    try { return await work } finally { this.claiming = undefined }
  }

  private async createAccount(name: string, address: string, secret: string): Promise<string> {
    const context = await this.auth.$context
    if (await context.internalAdapter.findUserByEmail(address)) throw new IdentityConflictError('An account with that email already exists')
    const user = await context.internalAdapter.createUser({ name, email: address, emailVerified: true }, { method: 'email-password' })
    await context.internalAdapter.linkAccount({ userId: user.id, providerId: 'credential', accountId: user.id, password: await context.password.hash(secret) })
    return user.id
  }

  private async addMembership(tenantId: string, userId: string, displayName: string): Promise<void> {
    const now = new Date()
    await this.db.insert(memberships).values({ tenantId, userId, displayName, status: 'active', joinedAt: now })
      .onConflictDoUpdate({ target: [memberships.tenantId, memberships.userId], set: { status: 'active', joinedAt: now, updatedAt: now } })
  }

  /** Signs an account in, answering with Better Auth's response so its session cookie reaches the browser. */
  signIn(address: string, secret: string, headers: Headers): Promise<Response> {
    return this.auth.api.signInEmail({ body: { email: address, password: secret }, headers, asResponse: true })
  }

  // --- Sessions ---------------------------------------------------------------

  async principal(headers: Headers): Promise<AdminPrincipal | undefined> {
    if (!headers.get('cookie')) return undefined
    const session = await this.auth.api.getSession({ headers }).catch(() => null)
    const user = session?.user as { id: string; name: string; email: string; isActive?: boolean; isSuperAdmin?: boolean } | undefined
    if (!user || user.isActive === false) return undefined
    const rows = await this.db.select({ tenantId: memberships.tenantId }).from(memberships)
      .where(and(eq(memberships.userId, user.id), eq(memberships.status, 'active')))
    return { kind: 'admin', userId: user.id, name: user.name, email: user.email, operator: Boolean(user.isSuperAdmin), tenantIds: rows.map(row => row.tenantId) }
  }

  // --- Tenants ----------------------------------------------------------------

  async tenants(ids?: string[]): Promise<Tenant[]> {
    if (ids && !ids.length) return []
    const rows = await this.db.select().from(tenants).where(ids ? inArray(tenants.id, ids) : undefined).orderBy(asc(tenants.createdAt))
    return rows.map(row => ({ id: row.id, name: row.name, quotas: quotasOf(row.settings), createdAt: row.createdAt.toISOString() }))
  }

  async tenant(id: string): Promise<Tenant> {
    const [found] = await this.tenants([id]).catch(() => [])
    if (!found) throw new IdentityNotFoundError('tenant not found')
    return found
  }

  async createTenant(input: Record<string, unknown>): Promise<Tenant> {
    const name = label(input.name, 'name')
    const quotas = parseQuotas(input.quotas)
    const [row] = await this.db.insert(tenants).values({ name, slug: slugFor(name), settings: { quotas } }).returning()
    return { id: row!.id, name: row!.name, quotas, createdAt: row!.createdAt.toISOString() }
  }

  async updateTenant(id: string, input: Record<string, unknown>): Promise<Tenant> {
    for (const key of Object.keys(input)) if (key !== 'name' && key !== 'quotas') throw new IdentityInputError(`Unknown field: ${key}`)
    const current = await this.tenant(id)
    const name = input.name === undefined ? current.name : label(input.name, 'name')
    const quotas = parseQuotas(input.quotas, current.quotas)
    await this.db.update(tenants).set({ name, settings: { quotas }, updatedAt: new Date() }).where(eq(tenants.id, id))
    return { ...current, name, quotas }
  }

  /** The caller makes sure the tenant has no computers left. */
  async deleteTenant(id: string): Promise<void> {
    await this.tenant(id)
    await this.db.delete(memberships).where(eq(memberships.tenantId, id))
    await this.db.delete(tenants).where(eq(tenants.id, id))
  }

  // --- Administrators -----------------------------------------------------------

  async administrators(tenantId: string): Promise<Administrator[]> {
    const rows = await this.db.select({ userId: users.id, name: users.name, email: users.email, operator: users.isSuperAdmin, joinedAt: memberships.joinedAt })
      .from(memberships).innerJoin(users, eq(users.id, memberships.userId))
      .where(and(eq(memberships.tenantId, tenantId), eq(memberships.status, 'active')))
      .orderBy(asc(memberships.createdAt))
    return rows.map(row => ({ ...row, joinedAt: row.joinedAt?.toISOString() ?? null }))
  }

  /** Takes an administrator off a tenant; a tenant always keeps at least one. */
  async removeAdministrator(tenantId: string, userId: string): Promise<void> {
    const current = await this.administrators(tenantId)
    if (!current.some(admin => admin.userId === userId)) throw new IdentityNotFoundError('administrator not found')
    if (current.length === 1) throw new IdentityConflictError('A tenant keeps at least one administrator')
    await this.db.delete(memberships).where(and(eq(memberships.tenantId, tenantId), eq(memberships.userId, userId)))
  }

  // --- Invitations --------------------------------------------------------------

  async invite(tenantId: string, input: Record<string, unknown>, createdBy: string | null, now = new Date()): Promise<{ token: string; invite: PendingInvite }> {
    await this.tenant(tenantId)
    const address = email(input.email)
    const token = randomBytes(32).toString('base64url')
    const [row] = await this.db.insert(invites).values({ tenantId, email: address, tokenHash: digest(token), createdBy, expiresAt: new Date(now.getTime() + INVITE_TTL_MS) }).returning()
    return { token, invite: { id: row!.id, email: row!.email, createdAt: row!.createdAt.toISOString(), expiresAt: row!.expiresAt.toISOString() } }
  }

  async pendingInvites(tenantId: string): Promise<PendingInvite[]> {
    const rows = await this.db.select().from(invites)
      .where(and(eq(invites.tenantId, tenantId), isNull(invites.acceptedAt), gt(invites.expiresAt, new Date())))
      .orderBy(asc(invites.createdAt))
    return rows.map(row => ({ id: row.id, email: row.email, createdAt: row.createdAt.toISOString(), expiresAt: row.expiresAt.toISOString() }))
  }

  async revokeInvite(tenantId: string, id: string): Promise<void> {
    const removed = await this.db.delete(invites).where(and(eq(invites.tenantId, tenantId), eq(invites.id, id), isNull(invites.acceptedAt))).returning({ id: invites.id })
    if (!removed.length) throw new IdentityNotFoundError('invitation not found')
  }

  private async openInvite(token: unknown) {
    if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(token)) throw new IdentityNotFoundError('This invitation is not valid')
    const [row] = await this.db.select({ invite: invites, tenantName: tenants.name }).from(invites)
      .innerJoin(tenants, eq(tenants.id, invites.tenantId))
      .where(eq(invites.tokenHash, digest(token))).limit(1)
    if (!row || row.invite.acceptedAt || row.invite.expiresAt <= new Date()) throw new IdentityNotFoundError('This invitation has expired or was already used')
    return row
  }

  async inspectInvite(token: unknown): Promise<InviteDetails> {
    const { invite, tenantName } = await this.openInvite(token)
    const context = await this.auth.$context
    return { tenantName, email: invite.email, expiresAt: invite.expiresAt.toISOString(), accountExists: Boolean(await context.internalAdapter.findUserByEmail(invite.email)) }
  }

  /**
   * Accepts an invitation: a new administrator chooses a name and password; one who already
   * has an account confirms it with their password. Either way they join the tenant.
   */
  async acceptInvite(token: unknown, input: Record<string, unknown>): Promise<{ email: string; password: string }> {
    const { invite } = await this.openInvite(token)
    const secret = password(input.password)
    const context = await this.auth.$context
    const existing = await context.internalAdapter.findUserByEmail(invite.email, { includeAccounts: true })
    let userId: string
    let displayName: string
    if (existing) {
      const credential = existing.accounts.find(account => account.providerId === 'credential')
      if (!credential?.password || !await context.password.verify({ hash: credential.password, password: secret })) {
        throw new IdentityInputError('That is not the password for this account')
      }
      userId = existing.user.id
      displayName = existing.user.name
    } else {
      displayName = label(input.name, 'name')
      userId = await this.createAccount(displayName, invite.email, secret)
    }
    const accepted = await this.db.update(invites).set({ acceptedAt: new Date(), acceptedBy: userId })
      .where(and(eq(invites.id, invite.id), isNull(invites.acceptedAt))).returning({ id: invites.id })
    if (!accepted.length) throw new IdentityNotFoundError('This invitation has expired or was already used')
    await this.addMembership(invite.tenantId, userId, displayName)
    return { email: invite.email, password: secret }
  }
}
