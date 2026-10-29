import { createHash, randomUUID } from 'node:crypto'
import { constants, existsSync } from 'node:fs'
import { mkdir, mkdtemp, open, readFile, readdir, readlink, rename, rm, unlink } from 'node:fs/promises'
import { basename, dirname, join } from 'node:path'
import { hostname } from 'node:os'
import { downloadSnapshotArchive, uploadSnapshotArchive, validateSnapshotArchive, type SnapshotArchive, type SnapshotObjectStore } from './snapshot-archive.js'

// Shared across per-computer and host-wide cleanup workers in this process.
const activeObjects = new Set<string>()

/** Runs only while parked, serialized with wake, restart, and deletion. */
export type ParkedExclusive = <T>(work: (generation: number) => Promise<T>) => Promise<T>


async function linuxProcessIdentity(pid: number): Promise<{ boot: string; start: string; namespace: string } | undefined> {
  if (process.platform !== 'linux') return undefined
  try {
    const [boot, stat, namespace] = await Promise.all([readFile('/proc/sys/kernel/random/boot_id', 'utf8'), readFile(`/proc/${pid}/stat`, 'utf8'), readlink(`/proc/${pid}/ns/pid`)])
    const end = stat.lastIndexOf(')')
    const start = end < 0 ? undefined : stat.slice(end + 2).split(' ')[19]
    if (!start || !/^\d+$/.test(start)) return undefined
    return { boot: boot.trim(), start, namespace }
  } catch { return undefined }
}

async function syncDirectory(path: string): Promise<void> {
  const dir = await open(path, 'r')
  try { await dir.sync() } finally { await dir.close() }
}
async function writePointer(path: string, archive: unknown, onRename: () => void, beforeRename?: () => void): Promise<void> {
  const temporary = `${path}.${randomUUID()}.tmp`
  try {
    const file = await open(temporary, 'wx', 0o600)
    try { await file.writeFile(JSON.stringify(archive)); await file.sync() } finally { await file.close() }
    beforeRename?.()
    await rename(temporary, path)
    onRename()
    await syncDirectory(dirname(path))
  } catch (error) {
    await rm(temporary, { force: true })
    throw error
  }
}
async function matchesSnapshot(directory: string, archive: SnapshotArchive, signal: AbortSignal): Promise<boolean> {
  signal.throwIfAborted()
  const files = await readdir(directory, { withFileTypes: true })
  if (files.length !== archive.entries.length || files.some(file => !file.isFile())) return false
  const entries = new Map(archive.entries.map(entry => [entry.name, entry]))
  for (const file of files) {
    signal.throwIfAborted()
    const entry = entries.get(file.name)
    if (!entry) return false
    const handle = await open(join(directory, file.name), constants.O_RDONLY | constants.O_NOFOLLOW)
    try {
      const stat = await handle.stat()
      if (!stat.isFile() || stat.size !== entry.size) return false
      const hash = createHash('sha256')
      for await (const chunk of handle.createReadStream({ autoClose: false, signal })) hash.update(chunk as Buffer)
      if (hash.digest('hex') !== entry.sourceSha256) return false
    } finally { await handle.close() }
  }
  return true
}

/** Cold-tier one computer. Call cancel before queueing wake/restart/delete. */
export class SnapshotTier {
  private active: AbortController | undefined
  private cleaning: Promise<void> | undefined
  private cleanupAbort: AbortController | undefined
  readonly pointer: string
  readonly tombstone: string
  readonly cleanupDirectory: string
  constructor(private readonly snapshot: string, private readonly store: SnapshotObjectStore, private readonly key: Uint8Array, private readonly exclusive: ParkedExclusive, private readonly isCurrent: (generation: number) => boolean) {
    this.pointer = `${snapshot}.cold.json`
    this.tombstone = `${snapshot}.cold-discard`
    this.cleanupDirectory = `${snapshot}.cold-gc`
  }
  cancel(): void { this.active?.abort() }
  async waitForCleanup(): Promise<void> { await this.cleaning }
  cancelCleanup(): void { this.cleanupAbort?.abort() }

  private async recordCleanup(key: string): Promise<void> {
    await mkdir(this.cleanupDirectory, { recursive: true, mode: 0o700 })
    await syncDirectory(dirname(this.cleanupDirectory))
    const name = createHash('sha256').update(key).digest('hex')
    const identity = await linuxProcessIdentity(process.pid)
    if (process.platform === 'linux' && !identity) throw new Error('Cannot identify the snapshot uploader process')
    await writePointer(join(this.cleanupDirectory, `${name}.json`), { key, ownerPid: process.pid, ownerHost: hostname(), ...(identity ? { ownerBoot: identity.boot, ownerStart: identity.start, ownerNamespace: identity.namespace } : {}) }, () => {})
  }

  /** Retry object deletion; keys of the authoritative cold pointer stay protected. */
  async drainCleanup(signal?: AbortSignal): Promise<void> {
    if (this.cleaning) return this.cleaning
    const abort = new AbortController()
    this.cleanupAbort = abort
    const cleanupSignal = signal ? AbortSignal.any([signal, abort.signal]) : abort.signal
    const run = async () => {
      cleanupSignal.throwIfAborted()
      if (this.active || existsSync(this.tombstone)) return
      let protectedKeys = new Set<string>()
      try {
        const pointer = JSON.parse(await readFile(this.pointer, 'utf8')) as SnapshotArchive
        validateSnapshotArchive(pointer)
        protectedKeys = new Set(pointer.entries.map(entry => entry.key))
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
      }
      let receipts: string[]
      try { receipts = await readdir(this.cleanupDirectory) } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return
        throw error
      }
      for (const receipt of receipts) {
        cleanupSignal.throwIfAborted()
        if (!/^[a-f0-9]{64}\.json$/.test(receipt)) continue
        const path = join(this.cleanupDirectory, receipt)
        let receiptText: string
        try { receiptText = await readFile(path, 'utf8') } catch (error) {
          if ((error as NodeJS.ErrnoException).code === 'ENOENT') continue
          throw error
        }
        const parsed = JSON.parse(receiptText) as { key?: unknown; ownerPid?: unknown; ownerHost?: unknown; ownerBoot?: unknown; ownerStart?: unknown; ownerNamespace?: unknown }
        if (typeof parsed.key !== 'string' || !Number.isSafeInteger(parsed.ownerPid) || (parsed.ownerPid as number) < 1 || typeof parsed.ownerHost !== 'string' || !/^snapshots\/[a-f0-9-]{36}\/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(parsed.key) || `${createHash('sha256').update(parsed.key).digest('hex')}.json` !== receipt) throw new Error('Invalid snapshot cleanup receipt')
        // Do not clean another live host process's upload, even when this
        // collector does not share its in-memory active-object set. Unknown
        // hosts or inaccessible PIDs are conservatively retained.
        if (activeObjects.has(parsed.key)) continue
        if (parsed.ownerHost !== hostname()) continue
        if (process.platform === 'linux') {
          const self = await linuxProcessIdentity(process.pid)
          if (!self || typeof parsed.ownerBoot !== 'string' || typeof parsed.ownerStart !== 'string' || typeof parsed.ownerNamespace !== 'string') continue
          // A PID in another live namespace cannot be checked through this
          // namespace. After a host reboot the old process is necessarily gone.
          if (self.boot === parsed.ownerBoot && self.namespace !== parsed.ownerNamespace) continue
        }
        if (parsed.ownerPid !== process.pid) {
          let alive = false
          try { process.kill(parsed.ownerPid as number, 0); alive = true } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== 'ESRCH') continue
          }
          if (alive) {
            const identity = await linuxProcessIdentity(parsed.ownerPid as number)
            if (!identity || typeof parsed.ownerBoot !== 'string' || typeof parsed.ownerStart !== 'string' || typeof parsed.ownerNamespace !== 'string' || (identity.boot === parsed.ownerBoot && identity.namespace === parsed.ownerNamespace && identity.start === parsed.ownerStart)) continue
          }
        }
        if (this.active || existsSync(this.tombstone)) return
        // Re-read after awaits: an archive may have published while this scan
        // was reading receipts. Never delete a currently authoritative object.
        try {
          const current = JSON.parse(await readFile(this.pointer, 'utf8')) as SnapshotArchive
          validateSnapshotArchive(current)
          protectedKeys = new Set(current.entries.map(entry => entry.key))
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
          protectedKeys.clear()
        }
        if (this.active || activeObjects.has(parsed.key) || protectedKeys.has(parsed.key)) continue
        await this.store.delete(parsed.key, { signal: cleanupSignal })
        await rm(path, { force: true })
        await syncDirectory(this.cleanupDirectory)
      }
    }
    this.cleaning = run().finally(() => { this.cleaning = undefined; this.cleanupAbort = undefined })
    return this.cleaning
  }

  private retryCleanup(): void {
    void this.drainCleanup().catch(error => { if (!(error instanceof Error && error.name === 'AbortError')) console.error('Snapshot object cleanup failed:', error) })
  }

  /** Upload outside the lifecycle lock; commit only if the same parked snapshot remains. */
  async archive(): Promise<boolean> {
    if (this.active) return false
    const abort = new AbortController()
    this.active = abort
    let archive: SnapshotArchive | undefined
    let published = false
    let verification: string | undefined
    const ownedKeys: string[] = []
    try {
      const generation = await this.exclusive(async generation => {
        if (!existsSync(this.snapshot) || existsSync(this.pointer) || existsSync(this.tombstone)) throw new Error('No exclusively local parked snapshot')
        return generation
      })
      const trackedStore: SnapshotObjectStore = {
        putStream: async input => { activeObjects.add(input.key); ownedKeys.push(input.key); await this.recordCleanup(input.key); await this.store.putStream(input) },
        getStream: (key, options) => this.store.getStream(key, options),
        delete: (key, options) => this.store.delete(key, options),
      }
      archive = await uploadSnapshotArchive(this.snapshot, trackedStore, this.key, abort.signal)
      // Verify the remote objects, authentication, and full plaintext before
      // committing the pointer and removing the only local copy.
      verification = await mkdtemp(join(dirname(this.snapshot), `.${basename(this.snapshot)}-verify-`))
      await downloadSnapshotArchive(join(verification, 'snapshot'), this.store, this.key, archive, abort.signal)
      await rm(verification, { recursive: true, force: true }); verification = undefined
      await this.exclusive(async current => {
        abort.signal.throwIfAborted()
        if (current !== generation || !this.isCurrent(generation) || existsSync(this.pointer) || existsSync(this.tombstone) || !await matchesSnapshot(this.snapshot, archive!, abort.signal)) throw new Error('Parked snapshot changed during upload')
        abort.signal.throwIfAborted()
        if (!this.isCurrent(generation)) throw new Error('Parked snapshot changed during upload')
        await writePointer(this.pointer, archive!, () => { published = true }, () => {
          abort.signal.throwIfAborted()
          if (!this.isCurrent(generation)) throw new Error('Parked snapshot changed during publication')
        })
        // Admission can invalidate the generation while fsync is in flight.
        // Preserve both copies and let the queued wake restore from the pointer.
        abort.signal.throwIfAborted()
        if (!this.isCurrent(generation)) throw new Error('Parked snapshot changed during publication')
        await rm(this.snapshot, { recursive: true, force: true })
        await syncDirectory(dirname(this.snapshot))
      })
      return true
    } finally {
      try { if (verification) await rm(verification, { recursive: true, force: true }) }
      finally {
        if (archive && !published) await Promise.allSettled(archive.entries.map(entry => this.store.delete(entry.key, { signal: AbortSignal.timeout(1000) })))
        if (this.active === abort) this.active = undefined
        for (const key of ownedKeys) activeObjects.delete(key)
        this.retryCleanup()
      }
    }
  }

  /** Call within a serialized restart or deletion; retry after any failure. */
  async discard(): Promise<void> {
    this.cancel()
    // The tombstone is durable before either copy is touched. A crash during
    // discard therefore cannot make a prior memory image bootable again.
    const marker = await open(this.tombstone, 'w', 0o600)
    try { await marker.writeFile('discard\n'); await marker.sync() } finally { await marker.close() }
    await syncDirectory(dirname(this.snapshot))
    await rm(this.pointer, { force: true })
    await rm(this.snapshot, { recursive: true, force: true })
    await syncDirectory(dirname(this.snapshot))
    await rm(this.tombstone, { force: true })
    await syncDirectory(dirname(this.snapshot))
    this.retryCleanup()
  }

  /** Call within the lifecycle transition, before a guest may resume or write. */
  async restoreForWake(): Promise<void> {
    this.cancel()
    if (existsSync(this.tombstone)) throw new Error('Snapshot discard was interrupted; retry discard before waking')
    let data: string
    try { data = await readFile(this.pointer, 'utf8') } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return
      throw error
    }
    const archive = JSON.parse(data) as SnapshotArchive
    const staging = await mkdtemp(join(dirname(this.snapshot), `.${basename(this.snapshot)}-restore-`))
    const restored = join(staging, 'snapshot')
    try {
      await downloadSnapshotArchive(restored, this.store, this.key, archive)
      // A crash during a previous local deletion may have left a partial dir.
      // The pointer remains authoritative until the verified replacement is durable.
      await rm(this.snapshot, { recursive: true, force: true })
      await rename(restored, this.snapshot)
      await syncDirectory(dirname(this.snapshot))
      await unlink(this.pointer)
      await syncDirectory(dirname(this.pointer))
      this.retryCleanup()
    } finally { await rm(staging, { recursive: true, force: true }) }
  }
}
