/** Revalidate account sockets after auth changes and periodically for expiry. */
export class AccountSocketFence {
  private readonly entries = new Set<{ valid: () => Promise<boolean>; close: () => void }>()
  private readonly timer: ReturnType<typeof setInterval>
  private checking: Promise<void> | undefined
  private dirty = false
  constructor(intervalMs = 30_000) {
    this.timer = setInterval(() => { void this.revalidate() }, intervalMs)
    this.timer.unref()
  }
  add(valid: () => Promise<boolean>, close: () => void): () => void {
    const entry = { valid, close }
    this.entries.add(entry)
    return () => { this.entries.delete(entry) }
  }
  revalidate(): Promise<void> {
    this.dirty = true
    if (this.checking) return this.checking
    this.checking = (async () => {
      while (this.dirty) {
        this.dirty = false
        // Serial database reads keep expiry checks bounded on small hosts.
        for (const entry of [...this.entries]) {
          const valid = await entry.valid().catch(() => false)
          if (!valid && this.entries.delete(entry)) entry.close()
        }
      }
    })().finally(() => { this.checking = undefined })
    return this.checking
  }
  dispose(): void {
    clearInterval(this.timer)
    for (const entry of this.entries) entry.close()
    this.entries.clear()
  }
}
