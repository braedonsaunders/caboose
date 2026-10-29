import { randomBytes } from 'node:crypto'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { ComputerLifecycle } from './lifecycle.js'
import { withAdmission, type Controller, type Session } from './server.js'
import type { SnapshotObjectStore } from './snapshot-archive.js'
import { SnapshotTier } from './snapshot-tier.js'
import { tieredController } from './snapshot-tier-controller.js'

function memoryStore(): SnapshotObjectStore {
  const objects = new Map<string, Buffer>()
  return {
    async putStream({ key, body }) { const chunks: Buffer[] = []; for await (const chunk of body) chunks.push(Buffer.from(chunk)); objects.set(key, Buffer.concat(chunks)) },
    async getStream(key) { const bytes = objects.get(key); if (!bytes) throw new Error('missing'); return { stream: new ReadableStream({ start(c) { c.enqueue(bytes); c.close() } }) } },
    async delete(key) { objects.delete(key) },
  }
}

describe('cold-tier controller integration', () => {
  it('refuses a cold wake when storage is disabled', async () => {
    const root = await mkdtemp(join(tmpdir(), 'tier-controller-')), snapshot = join(root, 'vm.snapshot')
    try {
      await writeFile(`${snapshot}.cold.json`, '{}')
      const wake = vi.fn(async () => ({}) as Session)
      const original = { wake, hasSavedState: () => false } as unknown as Controller
      const wrapped = tieredController(original, snapshot)
      const lifecycle = new ComputerLifecycle(wrapped.controller, 60_000)
      wrapped.attach(lifecycle)
      await expect(lifecycle.wake()).rejects.toThrow('configure snapshot storage')
      expect(wake).not.toHaveBeenCalled()
      expect(wrapped.controller.hasSavedState()).toBe(true)
    } finally { await rm(root, { recursive: true, force: true }) }
  })
  it('installs verified memory before the driver wakes', async () => {
    const root = await mkdtemp(join(tmpdir(), 'tier-controller-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
      const store = memoryStore(), key = randomBytes(32)
      const source = new SnapshotTier(snapshot, store, key, async work => work(1), () => true)
      await source.archive()
      const wake = vi.fn(async () => { expect(await readFile(join(snapshot, 'memory-ranges'), 'utf8')).toBe('memory'); return {} as Session })
      const original = { wake, hasSavedState: () => false } as unknown as Controller
      const wrapped = tieredController(original, snapshot, { store, key, delayMs: 60_000 })
      const lifecycle = new ComputerLifecycle(wrapped.controller, 60_000)
      wrapped.attach(lifecycle)
      await lifecycle.wake()
      expect(wake).toHaveBeenCalledOnce()
      await source.drainCleanup()
    } finally { await rm(root, { recursive: true, force: true }) }
  })
  it('durably discards cold memory before an explicit restart', async () => {
    const root = await mkdtemp(join(tmpdir(), 'tier-controller-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
      const store = memoryStore(), key = randomBytes(32)
      const source = new SnapshotTier(snapshot, store, key, async work => work(1), () => true)
      await source.archive()
      const restart = vi.fn(async () => {
        await expect(readFile(`${snapshot}.cold.json`)).rejects.toMatchObject({ code: 'ENOENT' })
        await expect(readFile(join(snapshot, 'memory-ranges'))).rejects.toMatchObject({ code: 'ENOENT' })
        return {} as Session
      })
      const original = { wake: async () => ({} as Session), restart, hasSavedState: () => false } as unknown as Controller
      const wrapped = tieredController(original, snapshot, { store, key, delayMs: 60_000 })
      const lifecycle = new ComputerLifecycle(wrapped.controller, 60_000)
      wrapped.attach(lifecycle)
      await lifecycle.restart()
      expect(restart).toHaveBeenCalledOnce()
      await source.drainCleanup()
    } finally { await rm(root, { recursive: true, force: true }) }
  })

  it('shutdown aborts and waits for a pending parked upload', async () => {
    const root = await mkdtemp(join(tmpdir(), 'tier-controller-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
      let started!: () => void
      const ready = new Promise<void>(resolve => { started = resolve })
      let aborted = false
      const store: SnapshotObjectStore = {
        async putStream({ signal }) {
          started()
          await new Promise<void>((_resolve, reject) => signal?.addEventListener('abort', () => { aborted = true; reject(signal.reason) }, { once: true }))
        },
        async getStream() { throw new Error('not needed') }, async delete() {},
      }
      const original = { wake: async () => ({} as Session), hasSavedState: () => false } as unknown as Controller
      const wrapped = tieredController(original, snapshot, { snapshot, store, key: randomBytes(32), delayMs: 1 })
      const lifecycle = new ComputerLifecycle(wrapped.controller, 60_000)
      wrapped.attach(lifecycle)
      await ready
      await wrapped.close()
      expect(aborted).toBe(true)
      expect(await readFile(join(snapshot, 'memory-ranges'), 'utf8')).toBe('memory')
    } finally { await rm(root, { recursive: true, force: true }) }
  })

  it('checks admission before downloading cold memory', async () => {
    const root = await mkdtemp(join(tmpdir(), 'tier-controller-')), snapshot = join(root, 'vm.snapshot')
    try {
      await mkdir(snapshot); await writeFile(join(snapshot, 'memory-ranges'), 'memory')
      const store = memoryStore(), key = randomBytes(32)
      const source = new SnapshotTier(snapshot, store, key, async work => work(1), () => true)
      await source.archive()
      const get = vi.spyOn(store, 'getStream')
      const original = { wake: async () => ({} as Session), hasSavedState: () => false } as unknown as Controller
      const wrapped = tieredController(original, snapshot, { store, key, delayMs: 60_000 })
      const lifecycle = new ComputerLifecycle(withAdmission(wrapped.controller, async () => { throw new Error('quota exceeded') }), 60_000)
      wrapped.attach(lifecycle)
      await expect(lifecycle.wake()).rejects.toThrow('quota exceeded')
      expect(get).not.toHaveBeenCalled()
      expect(await readFile(source.pointer, 'utf8')).toContain('entries')
      await wrapped.close()
      await source.discard(); await source.drainCleanup()
    } finally { await rm(root, { recursive: true, force: true }) }
  })

})
