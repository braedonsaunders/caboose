#!/usr/bin/env node
// Only for a dedicated disposable computer and host configured with parked Files.
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'

const base = process.env.CABOOSE_URL?.replace(/\/$/, '')
const token = process.env.CABOOSE_OWNER_TOKEN
if (!base || !token || process.env.CABOOSE_DISPOSABLE_CHECK !== 'yes') throw new Error('Set CABOOSE_URL, CABOOSE_OWNER_TOKEN and CABOOSE_DISPOSABLE_CHECK=yes for a dedicated disposable computer')
const timeout = Number(process.env.CABOOSE_CHECK_TIMEOUT_MS ?? 180000)
if (!Number.isSafeInteger(timeout) || timeout < 10000 || timeout > 600000) throw new Error('CABOOSE_CHECK_TIMEOUT_MS must be 10000–600000')
const prefix = `parked-check-${randomUUID()}`
const payload = Buffer.from('parked files range and thaw verification\n')
const streamedPayload = Buffer.alloc(16 * 1024 * 1024, 0x61)
const headers = { authorization: `Bearer ${token}` }
async function call(path, options = {}) {
  const response = await fetch(base + path, { ...options, headers: { ...headers, ...options.headers }, signal: options.signal ?? AbortSignal.timeout(timeout) })
  if (!response.ok) throw new Error(`${options.method ?? 'GET'} ${path}: ${response.status} ${await response.text()}`)
  return response
}
function file(operation, path) { return `/v1/fs/${operation}?path=${encodeURIComponent(path)}` }
async function state() { return (await (await call('/v1/computer')).json()).state }
async function expectState(expected) { assert.equal(await state(), expected, `computer should remain ${expected}`) }
async function park() {
  await call('/v1/session/park', { method: 'POST' })
  await expectState('parked')
}
async function readStat(path) { return (await call(file('stat', path))).json() }

// The check creates only a unique directory in the dedicated computer's home.
let created = false
try {
  await call('/v1/session', { method: 'POST' })
  await call(file('mkdir', prefix), { method: 'POST' }); created = true
  await call(file('content', `${prefix}/note.txt`), { method: 'PUT', headers: { 'if-none-match': '*' }, body: payload })
  await call(file('content', `${prefix}/stream.bin`), { method: 'PUT', headers: { 'if-none-match': '*' }, body: streamedPayload })
  const before = await readStat(`${prefix}/note.txt`)
  await park()
  const listing = await (await call(file('list', prefix))).json()
  assert(listing.items.some(item => item.name === 'note.txt' && item.etag === before.etag), 'parked list differs from running guest')
  await expectState('parked')
  const stat = await readStat(`${prefix}/note.txt`)
  assert.deepEqual(stat, before, 'parked stat differs from guest stat')
  await expectState('parked')
  const response = await call(file('content', `${prefix}/note.txt`), { headers: { range: 'bytes=2-8', 'if-match': before.etag } })
  assert.equal(response.status, 206)
  assert.equal(response.headers.get('content-range'), `bytes 2-8/${payload.length}`)
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), payload.subarray(2, 9))
  await expectState('parked')
  const mismatch = await fetch(base + file('content', `${prefix}/note.txt`), { headers: { ...headers, 'if-match': '"definitely-not-the-version"' }, signal: AbortSignal.timeout(timeout) })
  assert.equal(mismatch.status, 412, 'a stale conditional read must fail')
  await mismatch.arrayBuffer()
  await expectState('parked')

  // A cancelled reader must not strand the lifecycle queue or corrupt its view.
  const abort = new AbortController()
  const cancelled = fetch(base + file('content', `${prefix}/note.txt`), { headers, signal: abort.signal }).catch(() => undefined)
  abort.abort(); await cancelled
  assert.deepEqual(await readStat(`${prefix}/note.txt`), before)
  await expectState('parked')

  // Response headers are sent only after the appliance has opened and read the
  // first content chunk. Disconnect here rather than only before request dispatch.
  const streamAbort = new AbortController()
  const stream = await call(file('content', `${prefix}/stream.bin`), { signal: streamAbort.signal })
  assert.equal(stream.headers.get('content-length'), String(streamedPayload.length))
  streamAbort.abort()
  await assert.rejects(stream.arrayBuffer(), error => error.name === 'AbortError')
  assert.deepEqual(await readStat(`${prefix}/note.txt`), before)
  await expectState('parked')

  // Unsupported change-feed and mutation operations must wake and thaw safely.
  await call('/v1/fs/changes')
  await expectState('running')
  await park()
  const edited = Buffer.from('edited after thaw\n')
  await call(file('content', `${prefix}/note.txt`), { method: 'PUT', headers: { 'if-match': before.etag }, body: edited })
  await expectState('running')
  assert.deepEqual(Buffer.from(await (await call(file('content', `${prefix}/note.txt`))).arrayBuffer()), edited)
  console.log('Parked list/stat/range, cancellation, change fallback and mutation thaw passed')
} finally {
  if (created) await call(file('item', prefix), { method: 'DELETE' }).catch(error => console.error('Could not move check directory to Trash:', error.message))
}
