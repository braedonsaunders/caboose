#!/usr/bin/env node
// Run against a real configured host. --restart explicitly discards guest application memory.
import assert from 'node:assert/strict'

const base = (process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310').replace(/\/$/, '')
const token = process.env.CABOOSE_OWNER_TOKEN
if (!token) throw new Error('Set CABOOSE_OWNER_TOKEN in the environment')
const args = process.argv.slice(2)
if (args.some(value => value !== '--write' && value !== '--restart')) throw new Error('Usage: check-management.mjs [--write] [--restart]')

async function request(path, method = 'GET', body) {
  const response = await fetch(base + path, {
    method, signal: AbortSignal.timeout(300_000),
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  assert.equal(response.status, 200, `${method} ${path}: HTTP ${response.status}`)
  return response.json()
}

assert.equal((await fetch(base + '/v1/computer')).status, 401, 'Management requires authentication')
const before = await request('/v1/computer')
assert.ok(['parked', 'waking', 'running', 'parking', 'restarting', 'error'].includes(before.state))
assert.equal(typeof before.settings.name, 'string')
assert.equal(typeof before.restartRequired, 'boolean')
assert.equal(typeof before.capabilities.restart, 'boolean')
for (const field of ['memoryMb', 'vcpus', 'idleMs']) {
  assert.ok(Number.isSafeInteger(before.settings[field]))
  assert.ok(before.limits[field].min <= before.limits[field].max)
}
console.log('Authenticated status and configuration contract passed.')

if (args.includes('--write')) {
  // Save the same name to exercise persistence without changing the operator's preferences.
  const updated = await request('/v1/computer/settings', 'PATCH', { name: before.settings.name })
  assert.deepEqual(updated.settings, before.settings)
  assert.deepEqual((await request('/v1/computer')).settings, before.settings)
  console.log('Settings write/read passed.')
}
if (args.includes('--restart')) {
  assert.equal(before.capabilities.restart, true, 'Restart must be supported')
  const restarted = await request('/v1/computer/restart', 'POST', { confirm: true })
  assert.equal(restarted.state, 'running')
  assert.equal(restarted.restartRequired, false)
  assert.deepEqual(restarted.activeResources, { memoryMb: restarted.settings.memoryMb, vcpus: restarted.settings.vcpus })
  const session = await request('/v1/session', 'POST')
  assert.equal(session.state, 'running')
  assert.equal(session.computer.name, restarted.settings.name)
  assert.equal(session.computer.memoryMb, restarted.settings.memoryMb)
  assert.equal(session.computer.vcpus, restarted.settings.vcpus)
  console.log('Cold restart, applied resources, and ready display session passed.')
}
