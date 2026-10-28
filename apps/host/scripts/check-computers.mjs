#!/usr/bin/env node
// Run against a real configured host. Makes a throwaway computer, wakes it, pairs a phone with
// it, checks the phone reaches only that computer, signs the phone out and deletes the
// computer with its disk. Hosts with accounts also get a throwaway tenant, deleted last.
// No accounts are created, and the owner's computer is only read. --fence also checks, as root or
// through `sudo -n`, that the host's fence rejects traffic between computers.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'

const base = (process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310').replace(/\/$/, '')
const token = process.env.CABOOSE_OWNER_TOKEN
if (!token) throw new Error('Set CABOOSE_OWNER_TOKEN in the environment')
const args = process.argv.slice(2)
if (args.some(value => value !== '--fence')) throw new Error('Usage: check-computers.mjs [--fence]')

async function call(path, { method = 'GET', body, bearer = token, expect = 200 } = {}) {
  const response = await fetch(base + path, {
    method, signal: AbortSignal.timeout(300_000),
    headers: { ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}), 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  const expected = Array.isArray(expect) ? expect : [expect]
  assert.ok(expected.includes(response.status), `${method} ${path}: HTTP ${response.status} (expected ${expected.join(' or ')})`)
  if (response.status === 404) { await response.arrayBuffer(); return undefined }
  return response.headers.get('content-type')?.includes('json') ? response.json() : undefined
}

const before = await call('/v1/computers')
assert.equal(before.computers[0].id, 'owner')
assert.equal(before.canCreate, true, 'This host was started without room for more computers')
const owner = before.computers[0]

let tenant
let made
const failures = []
try {
  // Older hosts have no tenancy API. A new tenant avoids changing an existing tenant's quotas.
  const tenancy = await call('/v1/tenants', { expect: [200, 404] })
  if (tenancy !== undefined) {
    assert.ok(Array.isArray(tenancy.tenants), 'The host lists its tenants')
    tenant = await call('/v1/tenants', { method: 'POST', body: { name: 'Caboose computers check' }, expect: 201 })
  }
  made = await call('/v1/computers', { method: 'POST', body: { name: 'Caboose check', memoryMb: 2048, vcpus: 2, ...(tenant ? { tenantId: tenant.id } : {}) }, expect: 201 })
  console.log(`Made ${made.id}.`)
  assert.equal(made.state, 'parked')
  assert.deepEqual([made.settings.memoryMb, made.settings.vcpus], [2048, 2])

  const session = await call(`/v1/computers/${made.id}/session`, { method: 'POST' })
  assert.equal(session.state, 'running')
  assert.equal(session.computer.name, 'Caboose check')
  const listed = await call('/v1/computers')
  assert.equal(listed.computers.find(computer => computer.id === made.id)?.state, 'running')
  assert.equal(listed.computers.find(computer => computer.id === 'owner')?.settings.name, owner.settings.name)
  console.log('The new computer woke on its own disk and network.')

  if (args.includes('--fence')) {
    const sudo = process.getuid?.() === 0 ? [] : ['sudo', '-n']
    const run = (...command) => execFileSync(command[0], command.slice(1), { stdio: 'pipe' })
    const iptables = (...rule) => run(...sudo, 'iptables', ...rule)
    for (const chain of ['CABOOSE-FWD', 'CABOOSE-CFWD']) {
      try { iptables('-S', chain) } catch { continue }
      iptables('-C', chain, '-d', '192.0.2.0/24', '-j', 'REJECT', '--reject-with', 'icmp-net-prohibited')
      console.log(`${chain} rejects traffic between computers.`)
    }
  }

  const { code } = await call(`/v1/computers/${made.id}/pairing`, { method: 'POST', expect: 201 })
  const paired = await call('/v1/pair', { method: 'POST', bearer: null, body: { code, deviceName: 'Caboose check' }, expect: 201 })
  assert.equal(paired.computer.id, made.id)
  await call('/v1/pair', { method: 'POST', bearer: null, body: { code, deviceName: 'Again' }, expect: 404 })
  const phone = paired.token
  assert.equal((await call('/v1/computer', { bearer: phone })).settings.name, 'Caboose check')
  for (const path of ['/v1/health', '/v1/computers', '/v1/computers/owner/computer']) await call(path, { bearer: phone, expect: 403 })
  const { phones } = await call(`/v1/computers/${made.id}/phones`)
  const signedIn = phones.find(entry => entry.name === 'Caboose check')
  assert.ok(signedIn, 'The paired phone is listed')
  await call(`/v1/computers/${made.id}/phones/${signedIn.id}`, { method: 'DELETE' })
  await call('/v1/computer', { bearer: phone, expect: 401 })
  console.log('A paired phone reached only its computer, and signing it out locked it out.')
} catch (error) {
  failures.push(error)
} finally {
  if (made) {
    try {
      // The host waits for an upgrade itself; polling here keeps the check's timing honest.
      for (let waited = 0; waited < 300_000; waited += 2_000) {
        const state = (await call(`/v1/computers/${made.id}`)).upgrade?.state
        if (state !== 'checking' && state !== 'updating') break
        await new Promise(resolve => setTimeout(resolve, 2_000))
      }
    } catch (error) { failures.push(error) }
    // A failed poll must not skip deletion. Always attempt the tenant cleanup after this too.
    try {
      await call(`/v1/computers/${made.id}`, { method: 'DELETE', body: { confirm: true } })
      await call(`/v1/computers/${made.id}`, { expect: 404 })
      console.log(`Deleted ${made.id} with its disk.`)
    } catch (error) { failures.push(error) }
  }
  if (tenant) {
    try {
      await call(`/v1/tenants/${tenant.id}`, { method: 'DELETE' })
      console.log(`Deleted throwaway tenant ${tenant.id}.`)
    } catch (error) { failures.push(error) }
  }
}
if (failures.length === 1) throw failures[0]
if (failures.length > 1) throw new AggregateError(failures, 'The computer check or its cleanup failed')
const after = await call('/v1/computers')
assert.deepEqual(after.computers.map(computer => computer.id), before.computers.map(computer => computer.id))
assert.equal(after.computers[0].state === 'running', owner.state === 'running', "The owner's computer was left as it was")
console.log('Computers check passed.')
