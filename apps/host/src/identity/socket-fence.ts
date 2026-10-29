interface Entry {
  valid: () => Promise<boolean>
  close: () => void
  cancel?: () => void
}

/** Revalidate account sockets after auth changes and periodically for expiry. */
export class AccountSocketFence {
  private readonly entries = new Set<Entry>()
  private readonly timer: ReturnType<typeof setInterval>
  private checking: Promise<void> | undefined
  private dirty = false
  private disposed = false
  constructor(intervalMs = 30_000, private readonly deadlineMs = 5_000) {
    this.timer = setInterval(() => { void this.revalidate() }, intervalMs)
    this.timer.unref()
  }
  add(valid: () => Promise<boolean>, close: () => void): () => void {
    if (this.disposed) { close(); return () => {} }
    const entry: Entry = { valid, close }
    this.entries.add(entry)
    return () => { this.entries.delete(entry); entry.cancel?.() }
  }
  private async check(entry: Entry, budget: number): Promise<boolean> {
    if (budget <= 0) return false
    let timeout: ReturnType<typeof setTimeout> | undefined
    const cancelled = new Promise<boolean>(resolve => {
      entry.cancel = () => resolve(false)
      timeout = setTimeout(entry.cancel, budget)
    })
    try {
      // A timed-out entry is removed, so its unresolved read is never scheduled again.
      // Observe late rejection without retaining a timer or delaying shutdown.
      return await Promise.race([Promise.resolve().then(entry.valid).catch(() => false), cancelled])
    } finally {
      clearTimeout(timeout)
      entry.cancel = undefined
    }
  }
  revalidate(): Promise<void> {
    if (this.disposed) return Promise.resolve()
    this.dirty = true
    if (this.checking) return this.checking
    this.checking = (async () => {
      const deadline = Date.now() + this.deadlineMs
      while (this.dirty && !this.disposed) {
        this.dirty = false
        // One sweep has one deadline; unavailable storage cannot stall revocation.
        for (const entry of [...this.entries]) {
          if (this.disposed) break
          const valid = await this.check(entry, deadline - Date.now())
          if (!valid && this.entries.delete(entry)) entry.close()
        }
      }
    })().finally(() => { this.checking = undefined })
    return this.checking
  }
  dispose(): void {
    this.disposed = true
    this.dirty = false
    clearInterval(this.timer)
    for (const entry of this.entries) { entry.cancel?.(); entry.close() }
    this.entries.clear()
  }
}
