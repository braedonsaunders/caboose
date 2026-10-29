import { existsSync, statSync } from 'node:fs'
import type { ComputerLifecycle } from './lifecycle.js'
import type { SnapshotObjectStore } from './snapshot-archive.js'
import { SnapshotTier } from './snapshot-tier.js'
import type { Controller, Session } from './server.js'

export interface SnapshotTierOptions {
  snapshot: string
  store: SnapshotObjectStore
  key: Uint8Array
  /** Time a computer remains parked before tiering. */
  delayMs: number
}

/** Wraps the driver's destructive transitions; attach after constructing its lifecycle. */
export function tieredController(controller: Controller, snapshot: string, options?: SnapshotTierOptions) {
  const wrapped = Object.create(controller) as Controller
  let tier: SnapshotTier | undefined
  let disposed = false
  let timer: ReturnType<typeof setTimeout> | undefined
  let upload: Promise<void> | undefined
  const pointer = `${snapshot}.cold.json`, tombstone = `${snapshot}.cold-discard`
  const hasColdState = () => existsSync(pointer) || existsSync(tombstone)
  const requireTier = () => {
    if (hasColdState() && !tier) throw new Error('This computer has cold memory; configure snapshot storage and its key before waking, restarting, or deleting it')
  }
  wrapped.wake = async mode => {
    requireTier()
    await tier?.restoreForWake()
    return controller.wake(mode)
  }
  if (controller.restart) wrapped.restart = async () => {
    requireTier()
    await tier?.discard()
    return controller.restart!()
  }
  if (controller.destroy) wrapped.destroy = async () => {
    disposed = true
    tier?.cancel()
    clearTimer()
    requireTier()
    await tier?.discard()
    return controller.destroy!()
  }
  wrapped.hasSavedState = () => hasColdState() || controller.hasSavedState()
  function clearTimer() { if (timer) clearTimeout(timer); timer = undefined }
  function attach(lifecycle: ComputerLifecycle<Session>): void {
    if (!options) return
    if (!Number.isSafeInteger(options.delayMs) || options.delayMs < 1 || options.delayMs > 2_147_483_647) throw new Error('Invalid snapshot tier delay')
    tier = new SnapshotTier(snapshot, options.store, options.key, work => lifecycle.parkedExclusive(work), generation => lifecycle.isParkedGenerationCurrent(generation))
    const schedule = (retry = false) => {
      clearTimer()
      if (disposed || lifecycle.state !== 'parked' || hasColdState() || !existsSync(snapshot)) return
      let delay = options.delayMs
      if (!retry) {
        try { delay = Math.max(1, options.delayMs - Math.max(0, Date.now() - statSync(snapshot).mtimeMs)) } catch { return }
      }
      timer = setTimeout(() => {
        timer = undefined
        upload = tier!.archive().then(() => undefined).catch(error => {
          if (!disposed && lifecycle.state === 'parked') {
            console.error('Could not archive parked memory:', error)
            schedule(true)
          }
        }).finally(() => { upload = undefined })
      }, delay)
      timer.unref()
    }
    lifecycle.setParkedWorkCanceller(() => { clearTimer(); tier!.cancel() })
    lifecycle.subscribe(() => schedule())
    schedule()
  }
  async function close(): Promise<void> {
    disposed = true
    clearTimer()
    tier?.cancel()
    await upload
    tier?.cancelCleanup()
    await tier?.waitForCleanup().catch(() => undefined)
  }
  return { controller: wrapped, attach, close }
}
