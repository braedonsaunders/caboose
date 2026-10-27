/** Serializes a computer's transitions and keeps it resident while clients hold leases. */
export type ComputerState = 'parked' | 'waking' | 'running' | 'parking' | 'error'

export interface ComputerDriver<T> {
  wake(): Promise<T>
  park(): Promise<void>
}

export class ComputerLifecycle<T> {
  private current: ComputerState = 'parked'
  private value: T | undefined
  private leases = 0
  private idleTimer: ReturnType<typeof setTimeout> | undefined
  private sequence: Promise<void> = Promise.resolve()
  private listeners = new Set<(state: ComputerState) => void>()

  constructor(private readonly driver: ComputerDriver<T>, private readonly idleMs: number) {
    if (!Number.isSafeInteger(idleMs) || idleMs < 1 || idleMs > 2_147_483_647) {
      throw new Error('idleMs must be an integer between 1 and 2147483647')
    }
  }

  get state(): ComputerState { return this.current }

  subscribe(listener: (state: ComputerState) => void): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  private setState(state: ComputerState): void {
    this.current = state
    for (const listener of this.listeners) listener(state)
  }

  private serialize<R>(work: () => Promise<R>): Promise<R> {
    const result = this.sequence.then(work)
    this.sequence = result.then(() => undefined, () => undefined)
    return result
  }

  private clearIdle(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer)
    this.idleTimer = undefined
  }

  private armIdle(): void {
    this.clearIdle()
    if (this.leases || this.current !== 'running') return
    this.idleTimer = setTimeout(() => {
      this.idleTimer = undefined
      void this.serialize(async () => {
        if (this.leases === 0 && this.current === 'running') await this.parkNow()
      }).catch(() => {})
    }, this.idleMs)
    this.idleTimer.unref()
  }

  wake(): Promise<T> {
    this.clearIdle()
    return this.serialize(async () => {
      if (this.current === 'running' && this.value !== undefined) {
        this.armIdle()
        return this.value
      }
      this.setState('waking')
      try {
        this.value = await this.driver.wake()
        this.setState('running')
        this.armIdle()
        return this.value
      } catch (error) {
        this.setState('error')
        throw error
      }
    })
  }

  /** Acquire before upgrading a socket; release on every close or failed upgrade. */
  acquire(): () => void {
    this.leases++
    this.clearIdle()
    let released = false
    return () => {
      if (released) return
      released = true
      this.leases--
      this.armIdle()
    }
  }

  private async parkNow(): Promise<void> {
    if (this.current !== 'running') return
    this.clearIdle()
    this.setState('parking')
    try {
      await this.driver.park()
      this.value = undefined
      this.setState('parked')
    } catch (error) {
      this.setState('error')
      throw error
    }
  }

  /** Explicit park ignores leases; the caller must first close its sockets. */
  park(): Promise<void> {
    this.clearIdle()
    return this.serialize(() => this.parkNow())
  }
}
