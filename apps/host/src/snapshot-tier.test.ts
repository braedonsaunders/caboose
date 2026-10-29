import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { randomBytes } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { SnapshotTier } from './snapshot-tier.js'
import type { SnapshotObjectStore } from './snapshot-archive.js'

function storage() {
  const objects = new Map<string, Buffer>()
  const store: SnapshotObjectStore = {
    async putStream({ key, body }) { const chunks: Buffer[] = []; for await (const chunk of body) chunks.push(Buffer.from(chunk)); objects.set(key, Buffer.concat(chunks)) },
    async getStream(key) { const bytes = objects.get(key); if (!bytes) throw new Error('offline'); return { stream: new ReadableStream({ start(controller) { controller.enqueue(bytes); controller.close() } }) } },
    async delete(key) { objects.delete(key) },
  }
  return { store, objects }
}

describe('snapshot cold tier', () => {
  it('publishes only after verification and restores before clearing the pointer', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-tier-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'private memory')
      const { store } = storage(), tier = new SnapshotTier(snapshot, store, randomBytes(32), async work => work(1), () => true)
      expect(await tier.archive()).toBe(true)
      await expect(readdir(snapshot)).rejects.toMatchObject({ code: 'ENOENT' })
      expect(await readFile(tier.pointer, 'utf8')).toContain('sourceSha256')
      await tier.restoreForWake()
      expect(await readFile(join(snapshot, 'memory-ranges'), 'utf8')).toBe('private memory')
      await expect(readFile(tier.pointer)).rejects.toMatchObject({ code: 'ENOENT' })
      await tier.drainCleanup()
    } finally { await rm(root, { recursive: true, force: true }) }
  })
  it('keeps the durable pointer when an object is unavailable', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-tier-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
      const { store, objects } = storage(), tier = new SnapshotTier(snapshot, store, randomBytes(32), async work => work(1), () => true)
      await tier.archive(); objects.clear()
      await expect(tier.restoreForWake()).rejects.toThrow('offline')
      expect(await readFile(tier.pointer, 'utf8')).toContain('sourceSha256')
    } finally { await rm(root, { recursive: true, force: true }) }
  })
  it('does not publish after the parked generation changes', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-tier-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
      const { store, objects } = storage()
      let calls = 0
      const tier = new SnapshotTier(snapshot, store, randomBytes(32), async work => work(++calls), () => true)
      await expect(tier.archive()).rejects.toThrow('changed')
      expect(await readFile(join(snapshot, 'memory-ranges'), 'utf8')).toBe('memory')
      await expect(readFile(tier.pointer)).rejects.toMatchObject({ code: 'ENOENT' })
      await tier.drainCleanup()
      expect(objects.size).toBe(0)
    } finally { await rm(root, { recursive: true, force: true }) }
  })
  it('cancels an in-flight upload before it can publish or delete the snapshot', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-tier-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
      const { store, objects } = storage()
      let started!: () => void
      const ready = new Promise<void>(resolve => { started = resolve })
      store.putStream = async ({ signal }) => {
        started()
        await new Promise<void>((_resolve, reject) => {
          if (signal?.aborted) reject(signal.reason)
          else signal?.addEventListener('abort', () => reject(signal.reason), { once: true })
        })
      }
      const tier = new SnapshotTier(snapshot, store, randomBytes(32), async work => work(1), () => true)
      const upload = tier.archive()
      await ready
      tier.cancel()
      await expect(upload).rejects.toThrow()
      expect(await readFile(join(snapshot, 'memory-ranges'), 'utf8')).toBe('memory')
      await expect(readFile(tier.pointer)).rejects.toMatchObject({ code: 'ENOENT' })
      await tier.drainCleanup()
      expect(objects.size).toBe(0)
    } finally { await rm(root, { recursive: true, force: true }) }
  })

  it('replaces a partial local deletion from the durable cold pointer', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-tier-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'complete')
      const { store } = storage(), tier = new SnapshotTier(snapshot, store, randomBytes(32), async work => work(1), () => true)
      await tier.archive()
      await mkdir(snapshot); await writeFile(join(snapshot, 'partial'), 'incomplete')
      await tier.restoreForWake()
      expect(await readFile(join(snapshot, 'memory-ranges'), 'utf8')).toBe('complete')
      expect(await readdir(snapshot)).toEqual(['memory-ranges'])
      await expect(readFile(tier.pointer)).rejects.toMatchObject({ code: 'ENOENT' })
      await tier.drainCleanup()
    } finally { await rm(root, { recursive: true, force: true }) }
  })

  it('prevents resurrection after interrupted discard and supports a retry', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-tier-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
      const { store } = storage(), tier = new SnapshotTier(snapshot, store, randomBytes(32), async work => work(1), () => true)
      await tier.archive()
      await writeFile(tier.tombstone, 'discard')
      await expect(tier.restoreForWake()).rejects.toThrow('discard was interrupted')
      expect(await readFile(tier.pointer, 'utf8')).toContain('entries')
      await tier.discard()
      await tier.restoreForWake()
      await expect(readFile(tier.pointer)).rejects.toMatchObject({ code: 'ENOENT' })
      await tier.drainCleanup()
      await expect(readdir(snapshot)).rejects.toMatchObject({ code: 'ENOENT' })
    } finally { await rm(root, { recursive: true, force: true }) }
  })

  it('retains durable receipts across remote cleanup failures and retries after restart', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-tier-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
      const { store, objects } = storage(), key = randomBytes(32)
      let failing = false
      const remove = store.delete
      store.delete = async name => { if (failing) throw new Error('offline'); await remove(name) }
      const tier = new SnapshotTier(snapshot, store, key, async work => work(1), () => true)
      await tier.archive()
      await tier.drainCleanup()
      expect(objects.size).toBe(1)
      failing = true
      await tier.restoreForWake()
      await expect(tier.drainCleanup()).rejects.toThrow('offline')
      expect((await readdir(tier.cleanupDirectory)).filter(name => name.endsWith('.json'))).toHaveLength(1)
      failing = false
      const restarted = new SnapshotTier(snapshot, store, key, async work => work(1), () => true)
      await restarted.drainCleanup()
      expect(objects.size).toBe(0)
      expect((await readdir(tier.cleanupDirectory)).filter(name => name.endsWith('.json'))).toHaveLength(0)
    } finally { await rm(root, { recursive: true, force: true }) }
  })

  it('recovers a receipt when upload completion is ambiguous and cleanup initially fails', async () => {
    const root = await mkdtemp(join(tmpdir(), 'snapshot-tier-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
      const { store, objects } = storage(), key = randomBytes(32)
      const put = store.putStream, remove = store.delete
      let offline = true
      store.putStream = async input => { await put(input); throw new Error('response lost') }
      store.delete = async name => { if (offline) throw new Error('offline'); await remove(name) }
      const tier = new SnapshotTier(snapshot, store, key, async work => work(1), () => true)
      await expect(tier.archive()).rejects.toThrow('response lost')
      await expect(tier.drainCleanup()).rejects.toThrow('offline')
      expect(objects.size).toBe(1)
      expect((await readdir(tier.cleanupDirectory)).filter(name => name.endsWith('.json'))).toHaveLength(1)
      offline = false
      const restarted = new SnapshotTier(snapshot, store, key, async work => work(1), () => true)
      await restarted.drainCleanup()
      expect(objects.size).toBe(0)
      expect(await readFile(join(snapshot, 'memory-ranges'), 'utf8')).toBe('memory')
    } finally { await rm(root, { recursive: true, force: true }) }
  })

})
