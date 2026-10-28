import type { IncomingMessage, ServerResponse } from 'node:http'
import { NOT_FOUND, json, readJson } from '../http.js'
import type { ComputerRecord } from '../computers.js'
import type { ComputerSettings } from '../settings.js'
import { IdentityConflictError, IdentityInputError, type AdminPrincipal, type Identity, type Tenant } from './service.js'

/** Who is asking, as far as tenancy cares: the owner token, an administrator, or a phone. */
export type TenancyPrincipal = { kind: 'owner' } | AdminPrincipal | { kind: 'phone' }

/** The owner token and the operator's account reach every tenant. */
export function isOperator(principal: TenancyPrincipal): boolean {
  return principal.kind === 'owner' || (principal.kind === 'admin' && principal.operator)
}

/** Whether a principal administers a tenant (the operator administers them all). */
export function administers(principal: TenancyPrincipal, tenantId: string | null): boolean {
  if (isOperator(principal)) return true
  return principal.kind === 'admin' && tenantId !== null && principal.tenantIds.includes(tenantId)
}

/** What a tenant's computers are given between them, and the disk they use. */
export interface TenantUsage { computers: number; memoryMb: number; vcpus: number; diskBytes: number | null }

export interface TenancyContext {
  identity: Identity
  /** Every computer, with what it is set to be given. */
  computers(): Array<{ record: ComputerRecord; settings: ComputerSettings }>
  /** Bytes a computer's disk uses on the host, or null when the runtime cannot tell. */
  diskBytes(id: string): Promise<number | null>
  /** Gives a newly set-up host's computers to its first tenant. */
  adoptUnassigned(tenantId: string): Promise<void>
}

/**
 * A request from the machine itself rather than through a proxy: the setup page and claim are
 * open to it without the setup code.
 */
export function fromLoopback(request: IncomingMessage): boolean {
  const address = request.socket.remoteAddress ?? ''
  const loopback = address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1'
  return loopback && !request.headers['x-forwarded-for'] && !request.headers.forwarded
}

/** Copies a Better Auth answer's session cookie onto ours. */
function passCookies(from: Response, to: ServerResponse): void {
  const cookies = from.headers.getSetCookie()
  if (cookies.length) to.setHeader('set-cookie', cookies)
}

export function webHeaders(request: IncomingMessage): Headers {
  const headers = new Headers()
  for (const [name, value] of Object.entries(request.headers)) {
    if (Array.isArray(value)) for (const item of value) headers.append(name, item)
    else if (value !== undefined) headers.set(name, value)
  }
  return headers
}

export async function tenantUsage(context: TenancyContext, tenantId: string): Promise<TenantUsage> {
  const owned = context.computers().filter(computer => computer.record.tenantId === tenantId)
  const disks = await Promise.all(owned.map(computer => context.diskBytes(computer.record.id)))
  return {
    computers: owned.length,
    memoryMb: owned.reduce((total, computer) => total + computer.settings.memoryMb, 0),
    vcpus: owned.reduce((total, computer) => total + computer.settings.vcpus, 0),
    diskBytes: disks.some(bytes => bytes === null) ? null : disks.reduce<number>((total, bytes) => total + (bytes ?? 0), 0),
  }
}

/**
 * The routes for setup, sign-in state, tenants, their administrators and invitations.
 * Answers NOT_FOUND for any other path.
 */
export async function tenancyRoute(context: TenancyContext, request: IncomingMessage, response: ServerResponse, path: string, principal: TenancyPrincipal | undefined): Promise<unknown> {
  const { identity } = context
  const method = request.method ?? 'GET'

  // --- Without an account: setting the host up, and accepting an invitation ---
  if (path === '/v1/setup' && method === 'GET') {
    const claimed = await identity.claimed()
    return json(response, 200, { claimed, codeRequired: !claimed && !fromLoopback(request) })
  }
  if (path === '/v1/setup' && method === 'POST') {
    const input = await readJson(request)
    const claimed = await identity.claim(input, fromLoopback(request))
    await context.adoptUnassigned(claimed.tenantId)
    const signedIn = await identity.signIn(claimed.email, input.password as string, webHeaders(request))
    passCookies(signedIn, response)
    return json(response, 201, { claimed: true })
  }
  const invite = /^\/v1\/invites\/([A-Za-z0-9_-]+)(\/accept)?$/.exec(path)
  if (invite?.[1]) {
    if (method === 'GET' && !invite[2]) return json(response, 200, await identity.inspectInvite(invite[1]))
    if (method === 'POST' && invite[2]) {
      const accepted = await identity.acceptInvite(invite[1], await readJson(request))
      passCookies(await identity.signIn(accepted.email, accepted.password, webHeaders(request)), response)
      return json(response, 200, { accepted: true })
    }
    return json(response, 404, { error: 'not found' })
  }

  if (!path.startsWith('/v1/me') && !path.startsWith('/v1/tenants')) return NOT_FOUND
  if (!principal) return json(response, 401, { error: 'unauthorized' })
  if (principal.kind === 'phone') return json(response, 403, { error: 'forbidden' })
  const operator = isOperator(principal)
  const visible = (): Promise<Tenant[]> => operator ? identity.tenants() : identity.tenants(principal.kind === 'admin' ? principal.tenantIds : [])

  if (path === '/v1/me' && method === 'GET') {
    return json(response, 200, {
      kind: principal.kind,
      user: principal.kind === 'admin' ? { id: principal.userId, name: principal.name, email: principal.email } : null,
      operator,
      tenants: await visible(),
    })
  }
  if (path === '/v1/tenants' && method === 'GET') {
    const tenants = await visible()
    return json(response, 200, { tenants: await Promise.all(tenants.map(async tenant => ({ ...tenant, usage: await tenantUsage(context, tenant.id) }))) })
  }
  if (path === '/v1/tenants' && method === 'POST') {
    if (!operator) return json(response, 403, { error: 'Only the operator makes tenants' })
    const tenant = await identity.createTenant(await readJson(request))
    return json(response, 201, { ...tenant, usage: await tenantUsage(context, tenant.id) })
  }

  const scoped = /^\/v1\/tenants\/([0-9a-f-]{36})(\/administrators|\/invites)?(?:\/([^/]+))?$/.exec(path)
  if (!scoped?.[1]) return json(response, 404, { error: 'not found' })
  const tenantId = scoped[1]
  if (!administers(principal, tenantId)) return json(response, 404, { error: 'tenant not found' })
  const section = scoped[2]
  const item = scoped[3] ? decodeURIComponent(scoped[3]) : undefined

  if (!section && !item) {
    if (method === 'GET') return json(response, 200, { ...await identity.tenant(tenantId), usage: await tenantUsage(context, tenantId) })
    if (method === 'PATCH') {
      const input = await readJson(request)
      if ('quotas' in input && !operator) return json(response, 403, { error: 'Only the operator sets quotas' })
      const tenant = await identity.updateTenant(tenantId, input)
      return json(response, 200, { ...tenant, usage: await tenantUsage(context, tenantId) })
    }
    if (method === 'DELETE') {
      if (!operator) return json(response, 403, { error: 'Only the operator deletes tenants' })
      if (context.computers().some(computer => computer.record.tenantId === tenantId)) {
        throw new IdentityConflictError('Delete or move the tenant’s computers first')
      }
      await identity.deleteTenant(tenantId)
      return json(response, 200, { deleted: true })
    }
  }
  if (section === '/administrators') {
    if (!item && method === 'GET') return json(response, 200, { administrators: await identity.administrators(tenantId) })
    if (item && method === 'DELETE') {
      await identity.removeAdministrator(tenantId, item)
      return json(response, 200, { removed: true })
    }
  }
  if (section === '/invites') {
    if (!item && method === 'GET') return json(response, 200, { invites: await identity.pendingInvites(tenantId) })
    if (!item && method === 'POST') {
      const { token, invite: made } = await identity.invite(tenantId, await readJson(request), principal.kind === 'admin' ? principal.userId : null)
      return json(response, 201, { invite: made, token })
    }
    if (item && method === 'DELETE') {
      await identity.revokeInvite(tenantId, item)
      return json(response, 200, { revoked: true })
    }
  }
  if (method === 'GET' || method === 'POST' || method === 'PATCH' || method === 'DELETE') return json(response, 404, { error: 'not found' })
  throw new IdentityInputError(`Unsupported method ${method}`)
}

/**
 * Attempts to sign in (and to set up or accept an invitation, which sign in too), counted per
 * client address: twenty in ten minutes, then 429 until the window moves on. Better Auth's
 * own limiter needs a client address it cannot see behind Node's server, so the host keeps
 * this one.
 */
export class SignInThrottle {
  private attempts = new Map<string, number[]>()

  constructor(private readonly limit = 20, private readonly windowMs = 10 * 60_000, private readonly now: () => number = Date.now) {}

  /** True when this attempt may go ahead. */
  allow(request: IncomingMessage): boolean {
    // A forwarded address counts only from a proxy on this machine; anyone else could invent one.
    const peer = request.socket.remoteAddress ?? 'unknown'
    const local = peer === '127.0.0.1' || peer === '::1' || peer === '::ffff:127.0.0.1'
    const forwarded = local ? String(request.headers['x-forwarded-for'] ?? '').split(',').pop()?.trim() : undefined
    const client = forwarded || peer
    const now = this.now()
    const recent = (this.attempts.get(client) ?? []).filter(at => now - at < this.windowMs)
    if (recent.length >= this.limit) {
      this.attempts.set(client, recent)
      return false
    }
    recent.push(now)
    this.attempts.set(client, recent)
    if (this.attempts.size > 10_000) for (const [key, times] of this.attempts) if (!times.some(at => now - at < this.windowMs)) this.attempts.delete(key)
    return true
  }
}

/** The routes that try a password or a one-time secret. */
export function isSignInAttempt(method: string | undefined, path: string): boolean {
  return method === 'POST' && (path.startsWith('/v1/auth/sign-in/') || path === '/v1/auth/change-password' || path === '/v1/setup' || /^\/v1\/invites\/[^/]+\/accept$/.test(path))
}
