import { mkdtemp, rm, utimes, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ComputerLifecycle } from './lifecycle.js'
import { SharedStorage, baseKey, holdParked, type StorageComputer } from './shared-storage.js'
import type { DedupeJob, DedupeResult } from './disk-helper.js'

const report = { hashedBytes: 4096, sharedBytes: 8192, punchedBytes: 4096, skippedSources: [] }

function computer(id: string, root: string): StorageComputer & { lifecycle: ComputerLifecycle<string> } {
  const lifecycle = new ComputerLifecycle<string>({ wake: async () => 'session', park: async () => {} }, 600_000)
  return {
    id, lifecycle,
    base: async () => join(root, 'base.raw'),
    files: async () => ({ disk: join(root, `${id}.raw`), clones: [join(root, `${id}.view.raw`)] }),
  }
}

class FakeHelper {
  jobs: Array<{ job: DedupeJob; signal: AbortSignal }> = []
  forgotten: string[] = []
  next: (job: DedupeJob, signal: AbortSignal) => Promise<DedupeResult> = async () => ({ ok: true, report })
  async run(job: DedupeJob, signal: AbortSignal): Promise<DedupeResult> {
    this.jobs.push({ job, signal })
    return this.next(job, signal)
  }
  async forget(key: string): Promise<void> { this.forgotten.push(key) }
}

const settle = () => new Promise(resolve => setTimeout(resolve, 20))

describe('shared storage', () => {
  let root: string
  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'caboose-shared-'))
    for (const name of ['a.raw', 'b.raw', 'base.raw']) await writeFile(join(root, name), 'disk')
  })
  afterEach(async () => { await rm(root, { recursive: true, force: true }) })

  it('deduplicates a parked disk against its base and the other parked disks, once per change', async () => {
    const helper = new FakeHelper()
    let trims = 0
    const storage = new SharedStorage(helper, { statePath: join(root, 'state.json'), delayMs: 1, trim: async () => { trims++ } })
    await storage.open()
    const a = computer('a', root), b = computer('b', root)
    storage.attach(a)
    await settle()
    await storage.idle()
    storage.attach(b)
    await settle()
    await storage.idle()
    expect(helper.jobs).toHaveLength(2)
    const second = helper.jobs[1]!.job
    expect(second.key).toBe('computer:b')
    expect(second.files).toEqual([join(root, 'b.raw'), join(root, 'b.view.raw')])
    expect(second.sources).toEqual([
      { key: baseKey(join(root, 'base.raw')), path: join(root, 'base.raw'), immutable: true },
      { key: 'computer:a', path: join(root, 'a.raw') },
    ])
    expect(second.live).toEqual(['computer:a', 'computer:b', baseKey(join(root, 'base.raw'))])
    expect(storage.status()).toMatchObject({ sharedBytes: 16384, punchedBytes: 8192, passes: 2, lastError: null })
    // Freed blocks are returned to the device at most once an hour.
    expect(trims).toBe(1)

    // Parking again without the disk changing does nothing; a changed disk is passed again.
    await b.lifecycle.wake()
    await b.lifecycle.park()
    await settle()
    await storage.idle()
    expect(helper.jobs).toHaveLength(2)
    await utimes(join(root, 'b.raw'), new Date(), new Date(Date.now() + 5000))
    await b.lifecycle.wake()
    await b.lifecycle.park()
    await settle()
    await storage.idle()
    expect(helper.jobs).toHaveLength(3)
    await storage.close()
  })

  it('cancels a pass when the computer wakes, and wakes once the pass has stopped', async () => {
    const helper = new FakeHelper()
    let stop!: (result: DedupeResult) => void
    helper.next = (_, signal) => new Promise(resolve => {
      stop = resolve
      signal.addEventListener('abort', () => setTimeout(() => resolve({ ok: false, error: 'cancelled', report: { ...report, sharedBytes: 0, punchedBytes: 0 } }), 10))
    })
    const storage = new SharedStorage(helper, { statePath: join(root, 'state.json'), delayMs: 1 })
    await storage.open()
    const a = computer('a', root)
    storage.attach(a)
    await settle()
    expect(helper.jobs).toHaveLength(1)
    const order: string[] = []
    helper.jobs[0]!.signal.addEventListener('abort', () => order.push('aborted'))
    const woken = a.lifecycle.wake().then(() => order.push('woken'))
    await woken
    expect(order).toEqual(['aborted', 'woken'])
    expect(stop).toBeTypeOf('function')
    await storage.idle()
    // A cancelled pass is not recorded as done: the next park tries again.
    expect(storage.status().passes).toBe(0)
    await storage.close()
  })

  it('a wake of a source disk also cancels the pass', async () => {
    const helper = new FakeHelper()
    const storage = new SharedStorage(helper, { statePath: join(root, 'state.json'), delayMs: 60_000 })
    await storage.open()
    const a = computer('a', root), b = computer('b', root)
    storage.attach(a)
    storage.attach(b)
    helper.next = (_, signal) => new Promise(resolve => signal.addEventListener('abort', () => resolve({ ok: false, error: 'cancelled' })))
    // Run b's pass now rather than after the delay.
    ;(storage as unknown as { queue: string[] }).queue.push('b')
    ;(storage as unknown as { drain(): void }).drain()
    await settle()
    expect(helper.jobs[0]!.job.sources.map(source => source.key)).toContain('computer:a')
    await a.lifecycle.wake()
    expect(helper.jobs[0]!.signal.aborted).toBe(true)
    await storage.close()
  })

  it('stops for good on a filesystem that cannot share blocks, and forgets deleted computers', async () => {
    const helper = new FakeHelper()
    helper.next = async () => ({ ok: false, error: 'unsupported', message: 'EOPNOTSUPP' })
    const storage = new SharedStorage(helper, { statePath: join(root, 'state.json'), delayMs: 1 })
    await storage.open()
    const a = computer('a', root), b = computer('b', root)
    storage.attach(a)
    await settle()
    await storage.idle()
    storage.attach(b)
    await settle()
    await storage.idle()
    expect(helper.jobs).toHaveLength(1)
    expect(storage.status().lastError).toMatch(/unavailable on this filesystem/)
    await storage.forget('a')
    expect(helper.forgotten).toEqual(['computer:a'])
    await storage.close()
  })
})

describe('holdParked', () => {
  it('gives up on a computer that is not parked, and releases the lifecycle when done', async () => {
    const lifecycle = new ComputerLifecycle<string>({ wake: async () => 'session', park: async () => {} }, 600_000)
    await lifecycle.wake()
    expect(await holdParked(lifecycle, 100)).toBeNull()
    await lifecycle.park()
    const hold = await holdParked(lifecycle, 100)
    expect(hold).not.toBeNull()
    let woke = false
    const waking = lifecycle.wake().then(() => { woke = true })
    await settle()
    expect(hold!.signal.aborted).toBe(true)
    expect(woke).toBe(false)
    hold!.release()
    await waking
    expect(woke).toBe(true)
  })
})
