import type { Controller } from '../server.js'
import type { Coordinator, Ownership } from './coordinator.js'
import { OwnershipError } from './coordinator.js'

/** Fail closed on any failed renewal. Recovery still requires the external provider fence. */
export class ExecutionGuard {
  private failed = false
  private timer?: ReturnType<typeof setInterval>
  private renewing = false
  constructor(readonly coordinator: Coordinator, readonly ownership: Ownership, private stop: () => Promise<void>, private disconnect: () => void) {}
  start() {
    this.timer = setInterval(() => {
      if (this.renewing || this.failed) return
      this.renewing = true
      void this.bounded(this.coordinator.renew(this.ownership.id, this.ownership.generation)).catch(() => this.fence()).catch(error => console.error('Local execution stop failed:', error)).finally(() => { this.renewing = false })
    }, Math.floor(this.coordinator.ttlMs / 3))
    this.timer.unref()
  }
  private async bounded<T>(work: Promise<T>): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined
    try { return await Promise.race([work, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new OwnershipError('Coordinator deadline exceeded')), Math.min(5000, this.coordinator.ttlMs / 3)) })]) }
    finally { clearTimeout(timer) }
  }
  async assert() {
    if (this.failed) throw new OwnershipError('Local execution fenced')
    try { await this.bounded(this.coordinator.assertOwner(this.ownership.id, this.ownership.generation)) }
    catch (error) { await this.fence(); throw error }
    if (this.failed) throw new OwnershipError('Local execution fenced')
  }
  async fence() {
    this.failed = true
    clearInterval(this.timer)
    this.disconnect()
    await this.stop()
  }
  close() { clearInterval(this.timer) }
  wrap(controller: Controller): Controller {
    const guard = this
    // Gate every asynchronous runtime operation, including background agent command channels.
    return new Proxy(controller, { get(target, key) {
      const value = Reflect.get(target, key, target)
      if (key === 'guest') return () => {
        if (guard.failed) return undefined
        const guest = target.guest()
        return guest && { ...guest, run: async (...args: Parameters<typeof guest.run>) => { await guard.assert(); return guest.run(...args) } }
      }
      if (['wake','promote','thaw','restart','launch','apps','ensureAgentSeat','parkedFilesView'].includes(String(key)) && typeof value === 'function') {
        return async (...args: unknown[]) => { await guard.assert(); const result = await value.apply(target, args); await guard.assert(); return result }
      }
      return typeof value === 'function' ? value.bind(target) : value
    } })
  }
}
