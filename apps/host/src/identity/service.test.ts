import { existsSync, statSync } from 'node:fs'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { openIdentityDatabase, type IdentityDatabase } from './database.js'
import { Identity, parseQuotas } from './service.js'

let root: string
let database: IdentityDatabase
let identity: Identity

beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), 'caboose-identity-'))
  database = await openIdentityDatabase({ dataDir: join(root, 'identity') })
  identity = Identity.create({ database, baseURL: 'http://127.0.0.1:7310', secret: 'x'.repeat(40), setupCodePath: join(root, 'setup-code') })
}, 60_000)
afterAll(async () => {
  await database.close()
  await rm(root, { recursive: true, force: true })
})

/** The session cookie a sign-in answer sets, as a browser would send it back. */
function cookieFrom(response: Response): string {
  return response.headers.getSetCookie().map(cookie => cookie.split(';')[0]).join('; ')
}

describe('claiming the host', () => {
  it('keeps a one-time setup code until the first owner is made, then removes it', async () => {
    expect(await identity.claimed()).toBe(false)
    const code = await identity.setupCode()
    expect(code).toMatch(/^[0-9a-f]{64}$/)
    expect(await identity.setupCode()).toBe(code)
    const path = join(root, 'setup-code')
    expect((await readFile(path, 'utf8')).trim()).toBe(code)
    expect(statSync(path).mode & 0o777).toBe(0o600)
    expect(await identity.setupCodeMatches('nope')).toBe(false)
    expect(await identity.setupCodeMatches(code)).toBe(true)

    const owner = { name: 'Braedon', email: 'Owner@Example.com', password: 'correct horse', tenantName: 'Home' }
    await expect(identity.claim({ ...owner, code: 'wrong' }, false)).rejects.toThrow(/setup code/)
    await expect(identity.claim({ ...owner, code, password: 'short' }, false)).rejects.toThrow(/password/)
    const claimed = await identity.claim({ ...owner, code }, false)
    expect(claimed.email).toBe('owner@example.com')
    expect(existsSync(path)).toBe(false)
    expect(await identity.claimed()).toBe(true)
    expect(await identity.setupCode()).toBeNull()
    await expect(identity.claim({ ...owner, email: 'second@example.com' }, true)).rejects.toThrow(/already set up/)

    const signedIn = await identity.signIn('owner@example.com', 'correct horse', new Headers())
    expect(signedIn.status).toBe(200)
    const principal = await identity.principal(new Headers({ cookie: cookieFrom(signedIn) }))
    expect(principal).toEqual({ kind: 'admin', userId: claimed.userId, name: 'Braedon', email: 'owner@example.com', operator: true, tenantIds: [claimed.tenantId] })
    expect((await identity.signIn('owner@example.com', 'wrong password', new Headers())).status).toBe(401)
    expect(await identity.principal(new Headers({ cookie: 'better-auth.session_token=forged' }))).toBeUndefined()
    expect(await identity.principal(new Headers())).toBeUndefined()
  })
})

describe('tenants, administrators and invitations', () => {
  it('makes tenants with quotas and edits them', async () => {
    const family = await identity.createTenant({ name: 'Family', quotas: { memoryMb: 16384, vcpus: 8 } })
    expect(family.quotas).toEqual({ memoryMb: 16384, vcpus: 8, diskGb: null })
    const renamed = await identity.updateTenant(family.id, { name: 'The Family', quotas: { diskGb: 200, vcpus: null } })
    expect(renamed).toMatchObject({ name: 'The Family', quotas: { memoryMb: 16384, vcpus: null, diskGb: 200 } })
    expect((await identity.tenant(family.id)).quotas).toEqual(renamed.quotas)
    await expect(identity.updateTenant(family.id, { owner: 'x' })).rejects.toThrow(/Unknown field/)
    await expect(identity.createTenant({ name: '' })).rejects.toThrow(/name/)
    expect(() => parseQuotas({ memoryMb: 0 })).toThrow(/memoryMb/)
    expect(() => parseQuotas({ gpu: 1 })).toThrow(/Unknown quota/)
    await identity.deleteTenant(family.id)
    await expect(identity.tenant(family.id)).rejects.toThrow(/not found/)
  })

  it('invites an administrator by link, once, and lets an existing account join with its password', async () => {
    const team = await identity.createTenant({ name: 'Team' })
    const { token, invite } = await identity.invite(team.id, { email: 'Sam@Example.com' }, null)
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/)
    expect(await identity.pendingInvites(team.id)).toEqual([invite])
    expect(await identity.inspectInvite(token)).toMatchObject({ tenantName: 'Team', email: 'sam@example.com', accountExists: false })
    await expect(identity.acceptInvite(token, { name: 'Sam', password: 'short' })).rejects.toThrow(/password/)
    await identity.acceptInvite(token, { name: 'Sam', password: 'sam password' })
    await expect(identity.inspectInvite(token)).rejects.toThrow(/expired or was already used/)
    expect(await identity.pendingInvites(team.id)).toEqual([])
    const signedIn = await identity.signIn('sam@example.com', 'sam password', new Headers())
    const sam = await identity.principal(new Headers({ cookie: cookieFrom(signedIn) }))
    expect(sam).toMatchObject({ name: 'Sam', operator: false, tenantIds: [team.id] })

    // The owner joins too, with the password they already have.
    const second = await identity.invite(team.id, { email: 'owner@example.com' }, sam!.userId)
    expect((await identity.inspectInvite(second.token)).accountExists).toBe(true)
    await expect(identity.acceptInvite(second.token, { password: 'not it at all' })).rejects.toThrow(/not the password/)
    await identity.acceptInvite(second.token, { password: 'correct horse' })
    expect((await identity.administrators(team.id)).map(admin => admin.email)).toEqual(['sam@example.com', 'owner@example.com'])

    const revoked = await identity.invite(team.id, { email: 'late@example.com' }, null)
    await identity.revokeInvite(team.id, revoked.invite.id)
    await expect(identity.inspectInvite(revoked.token)).rejects.toThrow()
    await expect(identity.inspectInvite('x'.repeat(43))).rejects.toThrow()

    await identity.removeAdministrator(team.id, sam!.userId)
    const ownerId = (await identity.administrators(team.id))[0]!.userId
    await expect(identity.removeAdministrator(team.id, ownerId)).rejects.toThrow(/at least one/)
  })
})

describe('sign-in throttling', () => {
  it('lets twenty attempts through in ten minutes from one address, then waits', async () => {
    const { SignInThrottle, isSignInAttempt } = await import('./routes.js')
    let now = 0
    const throttle = new SignInThrottle(20, 600_000, () => now)
    const from = (address: string) => ({ headers: {}, socket: { remoteAddress: address } }) as never
    for (let attempt = 0; attempt < 20; attempt++) expect(throttle.allow(from('203.0.113.1'))).toBe(true)
    expect(throttle.allow(from('203.0.113.1'))).toBe(false)
    expect(throttle.allow(from('203.0.113.2'))).toBe(true)
    // A remote client cannot dodge the count by inventing a forwarded address.
    expect(throttle.allow({ headers: { 'x-forwarded-for': '198.51.100.7' }, socket: { remoteAddress: '203.0.113.1' } } as never)).toBe(false)
    // Behind a proxy on this machine, the address the proxy saw is the client.
    expect(throttle.allow({ headers: { 'x-forwarded-for': '198.51.100.7' }, socket: { remoteAddress: '127.0.0.1' } } as never)).toBe(true)
    now += 600_000
    expect(throttle.allow(from('203.0.113.1'))).toBe(true)
    expect(isSignInAttempt('POST', '/v1/auth/sign-in/email')).toBe(true)
    expect(isSignInAttempt('POST', '/v1/invites/abc/accept')).toBe(true)
    expect(isSignInAttempt('POST', '/v1/setup')).toBe(true)
    expect(isSignInAttempt('GET', '/v1/setup')).toBe(false)
    expect(isSignInAttempt('POST', '/v1/auth/sign-out')).toBe(false)
  })
})
