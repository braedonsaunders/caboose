#!/usr/bin/env node
// Wakes an actual computer, waits for its automatic component check, and exercises Files.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
const base = (process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310').replace(/\/$/, '')
const token = process.env.CABOOSE_OWNER_TOKEN
if (!token) throw new Error('Set CABOOSE_OWNER_TOKEN in the environment')
async function request(path, method = 'GET') {
  const r = await fetch(base + path, { method, headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(300_000) })
  assert.equal(r.status, 200, `${path}: HTTP ${r.status}`)
  return r.json()
}
assert.equal((await request('/v1/session', 'POST')).state, 'running')
const deadline = Date.now() + 900_000
let upgrade
while (Date.now() < deadline) {
  upgrade = (await request('/v1/computer')).upgrade
  if (upgrade?.state === 'succeeded' || upgrade?.state === 'failed') break
  await new Promise(resolve => setTimeout(resolve, 2000))
}
assert.equal(upgrade?.state, 'succeeded', `Upgrade did not succeed: ${JSON.stringify(upgrade)}`)
assert.ok(!upgrade.message, upgrade.message)
const result = spawnSync(process.execPath, [new URL('./check-fs.mjs', import.meta.url).pathname], { stdio: 'inherit', env: process.env })
assert.equal(result.status, 0, 'Files check failed')
console.log('Component status and real-host Files check passed.')
