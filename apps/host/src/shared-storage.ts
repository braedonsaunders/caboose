import { createHash } from 'node:crypto'
import { lstat, readFile } from 'node:fs/promises'
import { writePrivateJson } from './settings.js'
import type { DedupeHelper, DedupeResult } from './disk-helper.js'
import type { ComputerLifecycle, ComputerState } from './lifecycle.js'

/**
 * Shared storage: identical blocks across computer disks occupy the host's disk once.
 *
 * A parked computer's disk is passed to `caboose-disk` after it has stayed parked for a while
 * and changed since its last pass. While a pass runs it holds the computer, and every computer
 * whose disk it may share from, in parked-exclusive work; a wake, restart or delete of any of
 * them cancels the pass between kernel calls and then proceeds.
 */

type ParkedLifecycle = Pick<ComputerLifecycle<unknown>, 'state' | 'subscribe' | 'parkedExclusive' | 'addParkedWorkCanceller'>

export interface StorageComputer {
  id: string
  lifecycle: ParkedLifecycle
  /** The base image the computer's disk was cloned from, if it is on this host. */
  base(): Promise<string | null>
  /** The disk and the clones that track it; called only while the computer is held parked. */
  files(): Promise<{ disk: string; clones: string[] }>
}

export interface SharedStorageStatus {
  /** Bytes of computer disks that now share storage with another disk or a base image. */
  sharedBytes: number
  /** Bytes of zeros no longer allocated. */
  punchedBytes: number
  passes: number
  lastPassAt: string | null
  lastError: string | null
}

interface DiskStamp { ino: number; size: number; mtimeMs: number }
interface State extends SharedStorageStatus { version: 1; disks: Record<string, DiskStamp> }

interface Hold { signal: AbortSignal; release(): void }

/** Parked-exclusive work held until released; null when the computer is busy or not parked. */
export function holdParked(lifecycle: ParkedLifecycle, timeoutMs: number): Promise<Hold | null> {
  return new Promise(resolve => {
    let settled = false
    const abort = new AbortController()
    const remove = lifecycle.addParkedWorkCanceller(() => abort.abort(new Error('The computer is waking')))
    let finish!: () => void
    const done = new Promise<void>(resolveDone => { finish = resolveDone })
    const give = (hold: Hold | null) => {
      if (settled) return false
      settled = true
      clearTimeout(timer)
      if (!hold) remove()
      resolve(hold)
      return true
    }
    const timer = setTimeout(() => give(null), timeoutMs)
    timer.unref()
    lifecycle.parkedExclusive(async () => {
      // Abandoned after the timeout: let whatever is queued behind proceed.
      if (!give({ signal: abort.signal, release: () => { remove(); finish() } })) return
      await done
    }).catch(() => give(null))
  })
}

async function stamp(path: string): Promise<DiskStamp | null> {
  try {
    const info = await lstat(path)
    return info.isFile() ? { ino: info.ino, size: info.size, mtimeMs: info.mtimeMs } : null
  } catch { return null }
}

export function baseKey(path: string): string {
  return `base:${createHash('sha256').update(path).digest('hex').slice(0, 40)}`
}

export class SharedStorage {
  private readonly computers = new Map<string, { computer: StorageComputer; unsubscribe: () => void; timer?: ReturnType<typeof setTimeout> }>()
  private readonly queue: string[] = []
  private working: Promise<void> | undefined
  private state: State = { version: 1, sharedBytes: 0, punchedBytes: 0, passes: 0, lastPassAt: null, lastError: null, disks: {} }
  private readonly closing = new AbortController()
  private unsupported = false
  private lastTrim = 0
  private trimTimer: ReturnType<typeof setTimeout> | undefined

  constructor(private readonly helper: Pick<DedupeHelper, 'run' | 'forget'>, private readonly options: {
    statePath: string
    /** How long a computer stays parked before its disk is deduplicated. */
    delayMs: number
    /** Return freed blocks to the device below the image root (fstrim). */
    trim?: () => Promise<void>
    holdTimeoutMs?: number
    now?: () => number
  }) {}

  async open(): Promise<void> {
    try {
      const saved = JSON.parse(await readFile(this.options.statePath, 'utf8')) as State
      if (saved?.version === 1 && typeof saved.disks === 'object') this.state = { ...this.state, ...saved }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') console.error('Shared storage state is unreadable; starting fresh:', error)
    }
  }

  status(): SharedStorageStatus {
    const { sharedBytes, punchedBytes, passes, lastPassAt, lastError } = this.state
    return { sharedBytes, punchedBytes, passes, lastPassAt, lastError }
  }

  attach(computer: StorageComputer): void {
    this.detach(computer.id)
    const unsubscribe = computer.lifecycle.subscribe(state => this.observe(computer.id, state))
    this.computers.set(computer.id, { computer, unsubscribe })
    this.observe(computer.id, computer.lifecycle.state)
  }

  private detach(id: string): void {
    const entry = this.computers.get(id)
    if (!entry) return
    entry.unsubscribe()
    if (entry.timer) clearTimeout(entry.timer)
    this.computers.delete(id)
    this.dequeue(id)
  }

  /** The computer is deleted: drop it and its index record. */
  async forget(id: string): Promise<void> {
    this.detach(id)
    delete this.state.disks[id]
    await this.save()
    await this.helper.forget(`computer:${id}`)
  }

  private dequeue(id: string): void {
    const at = this.queue.indexOf(id)
    if (at >= 0) this.queue.splice(at, 1)
  }

  private observe(id: string, state: ComputerState): void {
    const entry = this.computers.get(id)
    if (!entry) return
    if (entry.timer) clearTimeout(entry.timer)
    entry.timer = undefined
    if (state !== 'parked') { this.dequeue(id); return }
    this.schedule(id, this.options.delayMs)
  }

  private schedule(id: string, delayMs: number): void {
    const entry = this.computers.get(id)
    if (!entry || this.unsupported || this.closing.signal.aborted) return
    if (entry.timer) clearTimeout(entry.timer)
    entry.timer = setTimeout(() => {
      entry.timer = undefined
      if (!this.queue.includes(id)) this.queue.push(id)
      this.drain()
    }, delayMs)
    entry.timer.unref()
  }

  private drain(): void {
    if (this.working) return
    this.working = (async () => {
      for (let id = this.queue.shift(); id !== undefined; id = this.queue.shift()) {
        if (this.closing.signal.aborted || this.unsupported) break
        try { await this.pass(id) } catch (error) {
          this.state.lastError = error instanceof Error ? error.message : String(error)
          console.error(`Shared storage pass for ${id} failed:`, error)
          await this.save().catch(() => {})
        }
      }
    })().finally(() => { this.working = undefined })
  }

  /** Wait for the pass in progress, if any (tests and shutdown). */
  async idle(): Promise<void> { await this.working }

  private async pass(id: string): Promise<void> {
    const entry = this.computers.get(id)
    if (!entry || entry.computer.lifecycle.state !== 'parked') return
    const timeout = this.options.holdTimeoutMs ?? 5_000
    const primary = await holdParked(entry.computer.lifecycle, timeout)
    if (!primary) {
      // Other parked work (such as tiering memory) holds it; try again later.
      if (entry.computer.lifecycle.state === 'parked') this.schedule(id, this.options.delayMs)
      return
    }
    const holds: Array<{ id: string; hold: Hold }> = []
    try {
      const files = await entry.computer.files()
      const before = await stamp(files.disk)
      const previous = this.state.disks[id]
      if (!before || (previous && previous.ino === before.ino && previous.size === before.size && previous.mtimeMs === before.mtimeMs)) return
      const others = [...this.computers.values()].filter(other => other.computer.id !== id && other.computer.lifecycle.state === 'parked')
      for (const held of await Promise.all(others.map(async other => ({ id: other.computer.id, hold: await holdParked(other.computer.lifecycle, Math.min(timeout, 2_000)) })))) {
        if (held.hold) holds.push({ id: held.id, hold: held.hold })
      }
      const bases = new Map<string, string>()
      for (const { computer } of this.computers.values()) {
        const base = await computer.base().catch(() => null)
        if (base) bases.set(baseKey(base), base)
      }
      const sources = [
        ...[...bases].map(([key, path]) => ({ key, path, immutable: true })),
        ...await Promise.all(holds.map(async ({ id: other }) => ({ key: `computer:${other}`, path: (await this.computers.get(other)!.computer.files()).disk }))),
      ]
      const signal = AbortSignal.any([primary.signal, this.closing.signal, ...holds.map(({ hold }) => hold.signal)])
      const result = await this.helper.run({
        key: `computer:${id}`, files: [files.disk, ...files.clones], sources,
        live: [...[...this.computers.keys()].map(key => `computer:${key}`), ...bases.keys()],
      }, signal)
      await this.record(id, files.disk, result)
    } finally {
      for (const { hold } of holds) hold.release()
      primary.release()
    }
  }

  private async record(id: string, disk: string, result: DedupeResult): Promise<void> {
    const report = result.ok ? result.report : result.report
    if (report) {
      this.state.sharedBytes += report.sharedBytes
      this.state.punchedBytes += report.punchedBytes
    }
    if (result.ok) {
      this.state.passes++
      this.state.lastPassAt = new Date(this.options.now?.() ?? Date.now()).toISOString()
      this.state.lastError = null
      const after = await stamp(disk)
      if (after) this.state.disks[id] = after
      if (result.report.sharedBytes + result.report.punchedBytes > 0) this.requestTrim()
    } else if (result.error === 'unsupported') {
      this.unsupported = true
      this.state.lastError = `Shared storage is unavailable on this filesystem: ${result.message ?? 'blocks cannot be shared'}`
      console.error(this.state.lastError)
    } else if (result.error === 'io' || result.error === 'invalid') {
      this.state.lastError = result.message ?? result.error
      console.error(`Shared storage pass for ${id} failed: ${this.state.lastError}`)
    }
    // busy, missing and cancelled: the next time the computer parks it is tried again.
    await this.save()
  }

  private requestTrim(): void {
    const trim = this.options.trim
    if (!trim || this.trimTimer) return
    const now = this.options.now?.() ?? Date.now()
    this.trimTimer = setTimeout(() => {
      this.trimTimer = undefined
      this.lastTrim = this.options.now?.() ?? Date.now()
      trim().catch(error => console.error('Could not return freed blocks to the device:', error))
    }, Math.max(0, this.lastTrim + 3_600_000 - now))
    this.trimTimer.unref()
  }

  private async save(): Promise<void> {
    await writePrivateJson(this.options.statePath, this.state)
  }

  async close(): Promise<void> {
    this.closing.abort(new Error('The host is stopping'))
    if (this.trimTimer) clearTimeout(this.trimTimer)
    for (const id of [...this.computers.keys()]) this.detach(id)
    await this.working
  }
}
