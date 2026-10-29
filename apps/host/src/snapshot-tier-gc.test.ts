import { randomBytes } from 'node:crypto'
import { mkdtemp, mkdir, readFile, readdir, readlink, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it, vi } from 'vitest'
import { SnapshotTier } from './snapshot-tier.js'
import { collectSnapshotObjects, startSnapshotGc } from './snapshot-tier-gc.js'
import type { SnapshotObjectStore } from './snapshot-archive.js'

async function processReceipt(pid: number) {
  const { hostname } = await import('node:os')
  if (process.platform !== 'linux') return { ownerPid: pid, ownerHost: hostname() }
  const [boot, stat, namespace] = await Promise.all([readFile('/proc/sys/kernel/random/boot_id', 'utf8'), readFile(`/proc/${pid}/stat`, 'utf8'), readlink(`/proc/${pid}/ns/pid`)])
  return { ownerPid: pid, ownerHost: hostname(), ownerBoot: boot.trim(), ownerStart: stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19], ownerNamespace: namespace }
}

it('retries deleted computers object cleanup after a host restart', async () => {
  const root = await mkdtemp(join(tmpdir(), 'snapshot-gc-')), snapshot = join(root, 'deleted.snapshot')
  const objects = new Map<string, Buffer>(), key = randomBytes(32)
  let offline = false
  const store: SnapshotObjectStore = {
    async putStream({ key, body }) { const chunks: Buffer[] = []; for await (const chunk of body) chunks.push(Buffer.from(chunk)); objects.set(key, Buffer.concat(chunks)) },
    async getStream(key) { const data = objects.get(key); if (!data) throw new Error('missing'); return { stream: new ReadableStream({ start(c) { c.enqueue(data); c.close() } }) } },
    async delete(key) { if (offline) throw new Error('offline'); objects.delete(key) },
  }
  const log = vi.spyOn(console, 'error').mockImplementation(() => {})
  try {
    await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
    const tier = new SnapshotTier(snapshot, store, key, async work => work(1), () => true)
    await tier.archive(); await tier.drainCleanup()
    expect(objects.size).toBe(1)
    offline = true
    await tier.discard()
    await expect(tier.drainCleanup()).rejects.toThrow('offline')
    expect((await readdir(tier.cleanupDirectory)).length).toBe(1)
    // No computer runtime is recreated: the host scans only the overlays directory.
    offline = false
    await collectSnapshotObjects(root, store, key)
    expect(objects.size).toBe(0)
    expect(await readdir(tier.cleanupDirectory)).toEqual([])
  } finally { log.mockRestore(); await rm(root, { recursive: true, force: true }) }
})

it('does not delete an object belonging to an active upload', async () => {
  const root = await mkdtemp(join(tmpdir(), 'snapshot-gc-')), snapshot = join(root, 'active.snapshot')
  const objects = new Map<string, Buffer>(), key = randomBytes(32)
  let started!: () => void
  const ready = new Promise<void>(resolve => { started = resolve })
  const store: SnapshotObjectStore = {
    async putStream({ key, body, signal }) {
      const chunks: Buffer[] = []; for await (const chunk of body) chunks.push(Buffer.from(chunk))
      objects.set(key, Buffer.concat(chunks)); started()
      await new Promise<void>((_resolve, reject) => signal?.addEventListener('abort', () => reject(signal.reason), { once: true }))
    },
    async getStream() { throw new Error('not needed') },
    async delete(key) { objects.delete(key) },
  }
  try {
    await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
    const tier = new SnapshotTier(snapshot, store, key, async work => work(1), () => true)
    const upload = tier.archive()
    await ready
    await collectSnapshotObjects(root, store, key)
    expect(objects.size).toBe(1)
    tier.cancel()
    await expect(upload).rejects.toThrow()
    await tier.drainCleanup()
    expect(objects.size).toBe(0)
  } finally { await rm(root, { recursive: true, force: true }) }
})

it('does not collect a receipt owned by another live process', async () => {
  const { createHash } = await import('node:crypto')
  const root = await mkdtemp(join(tmpdir(), 'snapshot-gc-')), snapshot = join(root, 'other.snapshot')
  const key = 'snapshots/00000000-0000-4000-8000-000000000000/memory-ranges'
  const store: SnapshotObjectStore = { async putStream() {}, async getStream() { throw new Error('unused') }, delete: vi.fn(async () => {}) }
  try {
    const receipts = `${snapshot}.cold-gc`
    await mkdir(receipts)
    await writeFile(join(receipts, `${createHash('sha256').update(key).digest('hex')}.json`), JSON.stringify({ key, ...await processReceipt(process.ppid) }))
    await collectSnapshotObjects(root, store, randomBytes(32))
    expect(store.delete).not.toHaveBeenCalled()
    expect((await readdir(receipts)).length).toBe(1)
  } finally { await rm(root, { recursive: true, force: true }) }
})


it('shutdown cancels a stalled remote deletion and retains its receipt', async () => {
  const { createHash } = await import('node:crypto')
  const root = await mkdtemp(join(tmpdir(), 'snapshot-gc-')), snapshot = join(root, 'gone.snapshot')
  const key = 'snapshots/00000000-0000-4000-8000-000000000000/memory-ranges'
  const receipts = `${snapshot}.cold-gc`
  let started!: () => void
  const ready = new Promise<void>(resolve => { started = resolve })
  const store: SnapshotObjectStore = {
    async putStream() {}, async getStream() { throw new Error('unused') },
    async delete(_key, options) {
      started()
      await new Promise<void>((_resolve, reject) => options?.signal?.addEventListener('abort', () => reject(options.signal!.reason), { once: true }))
    },
  }
  try {
    await mkdir(receipts)
    await writeFile(join(receipts, `${createHash('sha256').update(key).digest('hex')}.json`), JSON.stringify({ key, ...await processReceipt(process.pid) }))
    const gc = startSnapshotGc(root, store, randomBytes(32))
    await ready
    await gc.close()
    expect((await readdir(receipts)).length).toBe(1)
  } finally { await rm(root, { recursive: true, force: true }) }
})
