#!/usr/bin/env node
// Only for a disposable Linux microVM host started with CABOOSE_SHARED_STORAGE=on,
// CABOOSE_SHARED_STORAGE_DELAY_MS=5000 and CABOOSE_PARKED_FILES=on. Makes two throwaway
// computers (and on hosts with accounts a throwaway tenant), all deleted at the end:
//
//  - The same data written into both disks becomes shared storage, and reads back unchanged.
//  - Waking a computer while its pass runs cancels the pass and wakes it intact.
//  - A phone backup of one computer downloads only data chunks, each matching its hash; after
//    the computer changes, restoring that backup (uploading every chunk) brings it back.
import assert from 'node:assert/strict'
import { createHash, randomBytes } from 'node:crypto'

const base = process.env.CABOOSE_URL?.replace(/\/$/, '')
const token = process.env.CABOOSE_OWNER_TOKEN
if (!base || !token || process.env.CABOOSE_DISPOSABLE_CHECK !== 'yes') throw new Error('Set CABOOSE_URL, CABOOSE_OWNER_TOKEN and CABOOSE_DISPOSABLE_CHECK=yes for a disposable host')
const MiB = 1024 * 1024
const sha = data => createHash('sha256').update(data).digest('hex')
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

async function call(path, { method = 'GET', body, raw, bearer = token, expect = [200], timeout = 600_000 } = {}) {
  const response = await fetch(base + path, {
    method, signal: AbortSignal.timeout(timeout),
    headers: { authorization: `Bearer ${bearer}`, ...(raw ? { 'content-type': 'application/octet-stream' } : body === undefined ? {} : { 'content-type': 'application/json' }) },
    ...(raw ? { body: raw } : body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  const bytes = Buffer.from(await response.arrayBuffer())
  assert.ok([expect].flat().includes(response.status), `${method} ${path}: HTTP ${response.status} ${bytes.toString('utf8').slice(0, 300)}`)
  return response.headers.get('content-type')?.includes('json') ? JSON.parse(bytes.toString('utf8')) : bytes
}
const scoped = (id, path) => `/v1/computers/${id}${path.slice(3)}`
const file = (operation, path) => `/v1/fs/${operation}?path=${encodeURIComponent(path)}`
async function until(what, check, ms = 600_000) {
  const end = Date.now() + ms
  for (;;) {
    const value = await check()
    if (value) return value
    if (Date.now() > end) throw new Error(`Timed out waiting for ${what}`)
    await sleep(2000)
  }
}
const health = () => call('/v1/health')
async function write(id, path, data) {
  await call(scoped(id, file('content', path)), { method: 'PUT', raw: data, expect: [200, 201, 204] })
}
async function read(id, path) { return call(scoped(id, file('content', path))) }
async function park(id) { await call(scoped(id, '/v1/session/park'), { method: 'POST' }) }
async function wake(id) { await call(scoped(id, '/v1/session'), { method: 'POST' }) }

let tenant
const made = []
try {
  const tenancy = await call('/v1/tenants', { expect: [200, 404] })
  if (Array.isArray(tenancy?.tenants)) tenant = await call('/v1/tenants', { method: 'POST', body: { name: 'Caboose storage check' }, expect: 201 })
  for (const name of ['Storage check A', 'Storage check B']) {
    made.push((await call('/v1/computers', { method: 'POST', body: { name, memoryMb: 2048, vcpus: 2, ...(tenant ? { tenantId: tenant.id, person: 'Check' } : {}) }, expect: 201 })).id)
  }
  const [a, b] = made
  const shared = randomBytes(64 * MiB)
  const start = (await health()).sharedStorage
  assert.ok(start, 'The host was not started with CABOOSE_SHARED_STORAGE=on')

  // Shared storage: the same 64 MiB in both disks.
  for (const id of made) {
    await wake(id)
    await write(id, 'storage-check.bin', shared)
    await call(scoped(id, '/v1/session/park'), { method: 'POST' })
  }
  const after = await until('both disks to be passed', async () => {
    const status = (await health()).sharedStorage
    return status.passes >= start.passes + 2 && status.sharedBytes - start.sharedBytes >= 60 * MiB ? status : undefined
  })
  assert.equal(after.lastError, null)
  console.log(`OK: ${((after.sharedBytes - start.sharedBytes) / MiB).toFixed(0)} MiB of the two disks now share storage`)
  for (const id of made) {
    await wake(id)
    assert.equal(sha(await read(id, 'storage-check.bin')), sha(shared), 'a shared file changed')
  }
  console.log('OK: both computers read the shared file back unchanged')

  // A wake during a pass: give a's pass plenty to read, then wake it as the pass starts.
  const big = randomBytes(256 * MiB)
  await write(a, 'storage-check-big.bin', big)
  await park(a)
  await park(b)
  const passes = (await health()).sharedStorage.passes
  await sleep(5_500)
  const woke = Date.now()
  await wake(a)
  console.log(`OK: woke during a pass in ${((Date.now() - woke) / 1000).toFixed(1)} s`)
  assert.equal(sha(await read(a, 'storage-check-big.bin')), sha(big), 'a file changed across a cancelled pass')
  assert.equal((await health()).sharedStorage.lastError, null)
  console.log(`OK: the computer is intact (passes before ${passes}, now ${(await health()).sharedStorage.passes})`)
  await park(a)

  // Phone backup of b.
  const { code } = await call(`/v1/computers/${b}/pairing`, { method: 'POST', expect: 201 })
  const phone = (await call('/v1/pair', { method: 'POST', bearer: null, body: { code, deviceName: 'Storage check' }, expect: 201 })).token
  const enabled = await call('/v1/backup/device', { method: 'PUT', bearer: phone, body: { enabled: true } })
  assert.equal(enabled.available, true, enabled.reason)
  const status = await until('a capture', async () => (await call('/v1/backup', { bearer: phone })).capture ?? undefined)
  const { info, manifest } = await call(`/v1/backup/captures/${status.id}`, { bearer: phone })
  const data = [...new Set(manifest.chunks.filter(entry => typeof entry === 'string'))]
  console.log(`OK: captured ${(info.diskBytes / 1024 ** 3).toFixed(1)} GiB disk as ${info.dataChunks} data chunks (${(info.dataBytes / MiB).toFixed(0)} MiB)`)
  const { packs } = await call(`/v1/backup/captures/${info.id}/packs`, { method: 'POST', bearer: phone, body: { chunks: data }, expect: 201 })
  const chunks = new Map()
  for (const pack of packs) {
    const bytes = await call(`/v1/backup/packs/${pack.id}`, { bearer: phone })
    assert.equal(bytes.length, pack.bytes)
    let at = 0
    for (const hash of pack.chunks) {
      // Every chunk is 1 MiB but possibly the disk's last.
      const length = Math.min(info.chunkBytes, bytes.length - at)
      const chunk = bytes.subarray(at, at + length)
      assert.equal(sha(chunk), hash, 'a downloaded chunk does not match its hash')
      chunks.set(hash, Buffer.from(chunk))
      at += length
    }
  }
  await call('/v1/backup/complete', { method: 'POST', bearer: phone, body: { capture: info.id } })
  console.log(`OK: downloaded ${chunks.size} chunks in ${packs.length} packs, each matching its hash`)

  // Change b, then restore the backup, sending every chunk as a host without captures needs.
  await wake(b)
  await write(b, 'storage-check.bin', randomBytes(MiB))
  await park(b)
  const restore = await call('/v1/backup/restores', { method: 'POST', bearer: phone, body: { image: info.image, manifest }, expect: 201 })
  let batch = []
  let batchBytes = 0
  const flush = async () => {
    if (!batch.length) return
    await call(`/v1/backup/restores/${restore.id}/chunks`, { method: 'PUT', bearer: phone, raw: Buffer.concat(batch) })
    batch = []
    batchBytes = 0
  }
  for (const [hash, chunk] of chunks) {
    const header = Buffer.alloc(36)
    Buffer.from(hash, 'hex').copy(header)
    header.writeUInt32BE(chunk.length, 32)
    batch.push(header, chunk)
    batchBytes += 36 + chunk.length
    if (batchBytes > 128 * MiB) await flush()
  }
  await flush()
  await call(`/v1/backup/restores/${restore.id}/apply`, { method: 'POST', bearer: phone, body: { confirm: true }, timeout: 1_200_000 })
  assert.equal(sha(await read(b, 'storage-check.bin')), sha(shared), 'the restored computer does not have the backed-up file')
  console.log('OK: the restored computer restarted with its backed-up disk')
} finally {
  for (const id of made) {
    await call(`/v1/computers/${id}`, { method: 'DELETE', body: { confirm: true } }).catch(error => console.error(`Could not delete ${id}:`, error.message))
  }
  if (tenant) await call(`/v1/tenants/${tenant.id}`, { method: 'DELETE', expect: [200, 204] }).catch(error => console.error('Could not delete the check tenant:', error.message))
}
