#!/usr/bin/env node
// Run against a real configured host with the owner token. Reads the setup state and the
// owner's view, then makes a throwaway tenant with a memory quota, checks a computer within it
// is made and one beyond it is refused, and deletes both. It makes no accounts: those cannot
// be removed through the API.
import assert from 'node:assert/strict'

const base = (process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310').replace(/\/$/, '')
const token = process.env.CABOOSE_OWNER_TOKEN
if (!token) throw new Error('Set CABOOSE_OWNER_TOKEN in the environment')

async function call(path, { method = 'GET', body, expect = 200, bearer = token } = {}) {
  const response = await fetch(base + path, {
    method, signal: AbortSignal.timeout(300_000),
    headers: { ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}), 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  assert.equal(response.status, expect, `${method} ${path}: HTTP ${response.status}`)
  return response.headers.get('content-type')?.includes('json') ? response.json() : undefined
}

const setup = await call('/v1/setup', { bearer: null })
assert.equal(setup.codeRequired, !setup.claimed)
if (!setup.claimed) {
  await call('/v1/setup', { method: 'POST', bearer: null, body: {}, expect: 400 })
  console.log('An unclaimed host requires its setup code, including on loopback.')
}
console.log(setup.claimed ? 'The host is set up.' : 'The host is not set up yet; its setup link is in the log and setup-code.')
const me = await call('/v1/me')
assert.equal(me.kind, 'owner')
assert.equal(me.operator, true)
await call('/v1/me', { bearer: null, expect: 401 })
await call('/v1/tenants', { method: 'POST', bearer: null, body: { name: 'x' }, expect: 401 })

const tenant = await call('/v1/tenants', { method: 'POST', body: { name: 'Caboose check', quotas: { memoryMb: 2048, vcpus: 2 } }, expect: 201 })
let made
try {
  assert.deepEqual(tenant.usage, { computers: 0, memoryMb: 0, vcpus: 0, diskBytes: 0 })
  made = await call('/v1/computers', { method: 'POST', body: { name: 'Caboose check', tenantId: tenant.id, person: 'Check', memoryMb: 2048, vcpus: 2 }, expect: 201 })
  assert.equal(made.tenantId, tenant.id)
  assert.equal(made.person, 'Check')
  await call('/v1/computers', { method: 'POST', body: { name: 'Over quota', person: 'Check', tenantId: tenant.id, memoryMb: 1024, vcpus: 1 }, expect: 409 })
  await call(`/v1/computers/${made.id}/computer/settings`, { method: 'PATCH', body: { memoryMb: 4096 }, expect: 409 })
  const usage = (await call(`/v1/tenants/${tenant.id}`)).usage
  assert.equal(usage.computers, 1)
  assert.equal(usage.memoryMb, 2048)
  await call(`/v1/tenants/${tenant.id}`, { method: 'DELETE', expect: 409 })
  console.log('A tenant kept its computers within its quota.')
} finally {
  if (made) await call(`/v1/computers/${made.id}`, { method: 'DELETE', body: { confirm: true } })
  await call(`/v1/tenants/${tenant.id}`, { method: 'DELETE' })
}
console.log('Accounts check passed.')
