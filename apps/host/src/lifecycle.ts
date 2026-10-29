/** Serializes a computer's transitions and keeps it resident while clients hold leases. */
export type ComputerState = 'parked' | 'waking' | 'running' | 'frozen' | 'parking' | 'restarting' | 'error'
export type WakeMode = 'interactive' | 'headless'

export interface ComputerDriver<T> {
  wake(mode?: WakeMode): Promise<T>
  promote?(): Promise<T>
  canFreeze?(): boolean
  freeze?(): Promise<void>
  thaw?(): Promise<void>
  park(): Promise<void>
  restart?(): Promise<T>
}

export class ComputerConflictError extends Error {}

export class ComputerLifecycle<T> {
  private current: ComputerState = 'parked'
  private value: T | undefined
  private leases = 0
  private idleTimer: ReturnType<typeof setTimeout> | undefined
  private sequence: Promise<void> = Promise.resolve()
  private listeners = new Set<(state: ComputerState) => void>()
  private restartPending = false
  private retired = false
  private failure: string | null = null
  private mode: WakeMode = 'interactive'
  private beforeFreeze: () => Promise<boolean> = async () => true
  private freezeAllowed: () => boolean = () => true
  private parkedGeneration = 0
  private cancelParkedWork: () => void = () => {}

  constructor(private readonly driver: ComputerDriver<T>, private idleMs: number, private readonly freezeParkMs = 60_000) {
    if (!Number.isSafeInteger(idleMs) || idleMs < 1 || idleMs > 2_147_483_647) {
      throw new Error('idleMs must be an integer between 1 and 2147483647')
    }
    if (!Number.isSafeInteger(freezeParkMs) || freezeParkMs < 1 || freezeParkMs > 2_147_483_647) throw new Error('Invalid freeze park timeout')
  }

  get state(): ComputerState { return this.current }
  get acceptsConnections(): boolean { return (this.current === 'running' || this.current === 'frozen') && !this.restartPending }
  get lastError(): string | null { return this.failure }
  setBeforeFreeze(work: () => Promise<boolean>): void { this.beforeFreeze = work }
  setFreezeAllowed(check: () => boolean): void { this.freezeAllowed = check }

  /** Cancel external parked work synchronously before a state-changing admission is queued. */
  setParkedWorkCanceller(cancel: () => void): void { this.cancelParkedWork = cancel }

  private invalidateParkedWork(): void {
    this.parkedGeneration++
    this.cancelParkedWork()
  }

  /** Recheck after asynchronous work, including while holding parkedExclusive. */
  isParkedGenerationCurrent(generation: number): boolean {
    return !this.retired && !this.restartPending && this.current === 'parked' && this.parkedGeneration === generation
  }

  /** Serialize a parked-only action with wake, restart, park and deletion. */
  parkedExclusive<R>(work: (generation: number) => Promise<R>): Promise<R> {
    const generation = this.parkedGeneration
    return this.serialize(async () => {
      if (!this.isParkedGenerationCurrent(generation)) {
        throw new ComputerConflictError('Computer is not available for parked work')
      }
      return work(generation)
    })
  }

  setIdleMs(value: number): void {
    if (!Number.isSafeInteger(value) || value < 1 || value > 2_147_483_647) throw new Error('Invalid idle timeout')
    this.idleMs = value
    this.armIdle()
  }

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

  private armIdle(retryMs?: number): void {
    this.clearIdle()
    if (this.leases || !['running', 'frozen'].includes(this.current) || this.retired) return
    const freezing = this.current === 'running' && this.idleMs > 3000 && this.freezeAllowed() && this.driver.canFreeze?.() && this.driver.freeze && this.driver.thaw
    const delay = this.current === 'frozen' ? Math.min(this.idleMs - 3000, this.freezeParkMs) : freezing ? 3000 : this.idleMs
    this.idleTimer = setTimeout(() => {
      this.idleTimer = undefined
      void this.serialize(async () => {
        if (this.leases !== 0) return
        if (freezing && !this.freezeAllowed()) { this.armIdle(); return }
        if (freezing && this.current === 'running') {
          // Publish the fence before awaiting the VMM so new work queues behind pause.
          this.setState('frozen')
          try {
            if (!await this.beforeFreeze()) {
              this.setState('running')
              this.armIdle(30_000)
              return
            }
            await this.driver.freeze!()
            this.failure = null
          }
          catch (error) { this.failure = error instanceof Error ? error.message : String(error) }
          // A failed pause can have reached the VMM. Keep all guest access fenced until thaw.
          this.armIdle()
        } else if (this.current === 'running' || this.current === 'frozen') await this.parkNow()
      }).catch(() => {})
    }, Math.max(1, retryMs ?? delay))
    this.idleTimer.unref()
  }

  wake(mode: WakeMode = 'interactive'): Promise<T> {
    if (this.retired) return Promise.reject(new ComputerConflictError('Computer is being deleted'))
    this.invalidateParkedWork()
    this.clearIdle()
    return this.serialize(() => this.wakeNow(mode))
  }

  private async wakeNow(mode: WakeMode = 'interactive'): Promise<T> {
    const thawing = this.current === 'frozen'
    if (thawing) {
      try {
        await this.driver.thaw!()
        this.failure = null
      } catch (error) {
        this.failure = error instanceof Error ? error.message : String(error)
        this.armIdle()
        throw error
      }
    }
    if ((this.current === 'running' || thawing) && this.value !== undefined) {
      if (mode === 'interactive' && this.mode === 'headless' && this.driver.promote) {
        try {
          this.value = await this.driver.promote()
          this.mode = 'interactive'
          this.failure = null
        } catch (error) {
          this.failure = error instanceof Error ? error.message : String(error)
          // The VM resumed successfully; retain headless mode so the next
          // interactive request retries promotion without resuming it twice.
          if (thawing) this.setState('running')
          this.armIdle()
          throw error
        }
      }
      if (thawing) this.setState('running')
      this.armIdle()
      return this.value
    }
    this.setState('waking')
    try {
      this.value = await this.driver.wake(mode)
      this.mode = mode
      this.failure = null
      this.setState('running')
      this.armIdle()
      return this.value
    } catch (error) {
      this.failure = error instanceof Error ? error.message : String(error)
      this.setState('error')
      throw error
    }
  }

  /** Wake and perform an operation in the same lifecycle turn, holding a lease throughout. */
  wakeAndRun<R>(work: () => Promise<R>, mode: WakeMode = 'interactive'): Promise<R> {
    if (this.retired) return Promise.reject(new ComputerConflictError('Computer is being deleted'))
    if (this.restartPending) return Promise.reject(new ComputerConflictError('Computer is restarting'))
    this.invalidateParkedWork()
    const release = this.acquire()
    return this.serialize(async () => {
      await this.wakeNow(mode)
      return work()
    }).finally(release)
  }

  /** Guest operations complete before a park/restart can close their transport. */
  run<R>(work: () => Promise<R>): Promise<R> {
    if (this.retired) return Promise.reject(new ComputerConflictError('Computer is being deleted'))
    if (this.restartPending) return Promise.reject(new ComputerConflictError('Computer is restarting'))
    const release = this.acquire()
    return this.serialize(async () => {
      if (this.current === 'frozen') await this.wakeNow('headless')
      if (this.current !== 'running') throw new ComputerConflictError('Computer is not running')
      return work()
    }).finally(release)
  }

  restart(before: () => Promise<void> = async () => {}): Promise<T> {
    if (this.retired) return Promise.reject(new ComputerConflictError('Computer is being deleted'))
    if (this.restartPending) return Promise.reject(new ComputerConflictError('Computer is already restarting'))
    if (!this.driver.restart) return Promise.reject(new ComputerConflictError('Restart is unavailable'))
    this.invalidateParkedWork()
    this.restartPending = true
    this.clearIdle()
    return this.serialize(async () => {
      const frozen = this.current === 'frozen'
      this.setState('restarting')
      try {
        if (frozen) await this.driver.thaw!()
        await before()
        this.value = await this.driver.restart!()
        this.mode = 'interactive'
        this.failure = null
        this.setState('running')
        this.armIdle()
        return this.value
      } catch (error) {
        this.value = undefined
        this.failure = error instanceof Error ? error.message : String(error)
        this.setState('error')
        throw error
      }
    }).finally(() => { this.restartPending = false })
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
    if (this.current !== 'running' && this.current !== 'frozen') return
    this.clearIdle()
    this.setState('parking')
    try {
      await this.driver.park()
      this.value = undefined
      this.failure = null
      this.setState('parked')
    } catch (error) {
      this.failure = error instanceof Error ? error.message : String(error)
      this.setState('error')
      throw error
    }
  }

  /** Explicit park ignores leases; the caller must first close its sockets. */
  park(before: () => void = () => {}): Promise<void> {
    this.clearIdle()
    return this.serialize(async () => { before(); await this.parkNow() })
  }

  /**
   * Ends the computer for good, when it is deleted: nothing new is accepted, and `work` runs
   * once whatever is already queued has finished. The computer is not parked first, since its
   * memory is about to be thrown away with its disk.
   */
  retire(work: () => Promise<void>): Promise<void> {
    this.invalidateParkedWork()
    this.retired = true
    this.clearIdle()
    return this.serialize(async () => {
      await work()
      this.value = undefined
      this.setState('parked')
    })
  }
}
