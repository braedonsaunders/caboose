import { readdir } from 'node:fs/promises'
import { join } from 'node:path'
import type { SnapshotObjectStore } from './snapshot-archive.js'
import { SnapshotTier } from './snapshot-tier.js'

/** Drain receipts for every computer, including computers removed from the registry. */
export async function collectSnapshotObjects(overlays: string, store: SnapshotObjectStore, key: Uint8Array, signal?: AbortSignal): Promise<void> {
  let entries
  try { entries = await readdir(overlays, { withFileTypes: true }) } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return
    throw error
  }
  const failures: unknown[] = []
  for (const entry of entries) {
    signal?.throwIfAborted()
    if (!entry.isDirectory() || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.snapshot\.cold-gc$/.test(entry.name)) continue
    const snapshot = join(overlays, entry.name.slice(0, -'.cold-gc'.length))
    const tier = new SnapshotTier(snapshot, store, key, async () => { throw new Error('GC cannot start parked work') }, () => false)
    try { await tier.drainCleanup(signal) } catch (error) { failures.push(error) }
  }
  if (failures.length) throw new AggregateError(failures, 'Some snapshot objects could not be cleaned')
}

/** Periodically retry orphaned receipts without depending on a computer runtime. */
export function startSnapshotGc(overlays: string, store: SnapshotObjectStore, key: Uint8Array) {
  let pending: Promise<void> | undefined
  let closed = false
  const abort = new AbortController()
  const run = () => {
    if (closed || pending) return
    pending = collectSnapshotObjects(overlays, store, key, abort.signal).catch(error => {
      if (!closed) console.error('Snapshot cleanup failed:', error)
    }).finally(() => { pending = undefined })
  }
  run()
  const timer = setInterval(run, 60 * 60_000)
  timer.unref()
  return { async close() { closed = true; clearInterval(timer); abort.abort(); await pending } }
}
