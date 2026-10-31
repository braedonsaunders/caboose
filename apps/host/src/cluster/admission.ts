import { ComputerConflictError } from '../lifecycle.js'

/** Local execution exclusion, never a distributed ownership lease. */
export class ComputerAdmission {
  private readonly active = new Map<string, Set<{ cancel: () => void; settled: Promise<void> }>>()
  private readonly exclusive = new Set<string>()
  constructor(private readonly drainMs = 5000) {}

  enter(id: string, cancel: () => void): () => void {
    if (this.exclusive.has(id)) throw new ComputerConflictError('Computer maintenance is in progress')
    let resolve!: () => void
    const entry = { cancel, settled: new Promise<void>(done => { resolve = done }) }
    const entries = this.active.get(id) ?? new Set()
    this.active.set(id, entries); entries.add(entry)
    return () => {
      if (!entries.delete(entry)) return
      if (!entries.size) this.active.delete(id)
      resolve()
    }
  }

  async runExclusive<T>(id: string, work: () => Promise<T>): Promise<T> {
    if (this.exclusive.has(id)) throw new ComputerConflictError('Computer maintenance is in progress')
    this.exclusive.add(id)
    const entries = [...(this.active.get(id) ?? [])]
    // Cancel transports, then wait for their handlers too. A disconnected request
    // may still be writing; closing its socket is not proof that it has stopped.
    for (const entry of entries) entry.cancel()
    const drained = Promise.all(entries.map(entry => entry.settled))
    let timer: ReturnType<typeof setTimeout> | undefined
    let complete = false
    try {
      await Promise.race([drained, new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new ComputerConflictError('Computer work did not stop before the maintenance deadline')), this.drainMs)
      })])
      clearTimeout(timer)
      complete = true
      return await work()
    } finally {
      clearTimeout(timer)
      if (complete) this.exclusive.delete(id)
      else void drained.then(() => this.exclusive.delete(id))
      // On timeout keep this computer fenced until the actual handlers settle.
    }
  }
}
