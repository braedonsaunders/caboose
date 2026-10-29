import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, expect, it } from 'vitest'
import { openIdentityDatabase, type IdentityDatabase } from './database.js'
import { Identity } from './service.js'

let root: string
let database: IdentityDatabase
let identity: Identity
const cookies = new Map<string, string>()
const headers = () => new Headers({ cookie: [...cookies].map(([name, value]) => `${name}=${value}`).join('; '), origin: 'http://127.0.0.1:7310', 'content-type': 'application/json' })
async function request(path: string, body?: unknown) {
  const response = await identity.handleAuthentication(new Request(`http://127.0.0.1:7310/v1/auth/${path}`, { method: body === undefined ? 'GET' : 'POST', headers: headers(), body: body === undefined ? undefined : JSON.stringify(body) }))
  for (const header of response.headers.getSetCookie()) {
    const pair = header.split(';')[0]!
    const at = pair.indexOf('='); cookies.set(pair.slice(0, at), pair.slice(at + 1))
  }
  return response
}
beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), 'caboose-security-'))
  database = await openIdentityDatabase({ dataDir: join(root, 'identity') })
  identity = Identity.create({ database, baseURL: 'http://127.0.0.1:7310', secret: 's'.repeat(40), setupCodePath: join(root, 'setup-code') })
  await identity.claim({ code: await identity.setupCode(), name: 'Admin', email: 'admin@example.test', password: 'initial password', tenantName: 'Home' })
}, 60_000)
afterAll(async () => { await database?.close(); await rm(root, { recursive: true, force: true }) })

it('requires completed MFA before granting an existing administrator invitation; redacts and revokes sessions', async () => {
  expect((await request('sign-up/email', { email: 'stranger@example.test', password: 'some password', name: 'Stranger' })).status).toBe(404)
  expect((await request('sign-in/magic-link', { email: 'admin@example.test' })).status).toBe(404)
  expect((await request('request-password-reset', { email: 'admin@example.test' })).status).toBe(503)
  expect((await request('sign-in/email', { email: 'admin@example.test', password: 'initial password' })).status).toBe(200)
  const enabled = await request('two-factor/enable', { password: 'initial password' })
  expect(enabled.status).toBe(200)
  const enrollment = await enabled.json()
  const secret = new URL(enrollment.totpURI).searchParams.get('secret')!
  const code = await identity.auth.api.generateTOTP({ body: { secret } })
  expect((await request('two-factor/verify-totp', code)).status).toBe(200)
  await request('sign-out', {})
  const challenge = await request('sign-in/email', { email: 'admin@example.test', password: 'initial password' })
  expect(await challenge.json()).toMatchObject({ twoFactorRedirect: true })
  expect(await identity.principal(headers())).toBeUndefined()
  const team = await identity.createTenant({ name: 'Invited team' })
  const invite = await identity.invite(team.id, { email: 'admin@example.test' }, null)
  await expect(identity.acceptInvite(invite.token, { password: 'initial password' }, headers())).rejects.toThrow(/Sign in/)
  expect(await identity.administrators(team.id)).toEqual([])
  expect((await identity.inspectInvite(invite.token)).accountExists).toBe(true)
  expect((await request('two-factor/verify-backup-code', { code: enrollment.backupCodes[0] })).status).toBe(200)
  await identity.acceptInvite(invite.token, {}, headers())
  expect(await identity.administrators(team.id)).toHaveLength(1)
  const current = await (await request('get-session')).json()
  expect(current.session.token).toBeUndefined()
  const sessions = await (await request('list-sessions')).json()
  expect(sessions.length).toBeGreaterThan(0)
  expect(sessions.every((session: Record<string, unknown>) => !('token' in session))).toBe(true)
  expect((await request('revoke-session', { id: 'other-account-session' })).status).toBe(404)
  const changes: string[] = []
  const unsubscribe = identity.onAuthorizationChange(async () => { changes.push('checked') })
  expect((await request('revoke-session', { id: current.session.id })).status).toBe(200)
  expect(changes).toEqual(['checked'])
  expect(await identity.principal(headers())).toBeUndefined()
  unsubscribe()
}, 60_000)
