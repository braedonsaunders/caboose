#!/usr/bin/env node
// Run against a real configured host. Makes a throwaway computer, wakes it, pairs a phone with
// it, checks the phone reaches only that computer, signs the phone out and deletes the
// computer with its disk. The owner's computer is only read. --fence also checks, as root or
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
  assert.equal(response.status, expect, `${method} ${path}: HTTP ${response.status}`)
  return response.headers.get('content-type')?.includes('json') ? response.json() : undefined
}

const before = await call('/v1/computers')
assert.equal(before.computers[0].id, 'owner')
assert.equal(before.canCreate, true, 'This host was started without room for more computers')
const owner = before.computers[0]

const made = await call('/v1/computers', { method: 'POST', body: { name: 'Caboose check', memoryMb: 2048, vcpus: 2 }, expect: 201 })
console.log(`Made ${made.id}.`)
try {
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
} finally {
  // The host waits for a components upgrade itself; waiting here too keeps the check's timing honest.
  for (let waited = 0; waited < 300_000; waited += 2_000) {
    const state = (await call(`/v1/computers/${made.id}`)).upgrade?.state
    if (state !== 'checking' && state !== 'updating') break
    await new Promise(resolve => setTimeout(resolve, 2_000))
  }
  await call(`/v1/computers/${made.id}`, { method: 'DELETE', body: { confirm: true } })
  await call(`/v1/computers/${made.id}`, { expect: 404 })
  console.log(`Deleted ${made.id} with its disk.`)
}
const after = await call('/v1/computers')
assert.deepEqual(after.computers.map(computer => computer.id), before.computers.map(computer => computer.id))
assert.equal(after.computers[0].state === 'running', owner.state === 'running', "The owner's computer was left as it was")
console.log('Computers check passed.')
