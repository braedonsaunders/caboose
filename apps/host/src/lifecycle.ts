/** Serializes a computer's transitions and keeps it resident while clients hold leases. */
export type ComputerState = 'parked' | 'waking' | 'running' | 'frozen' | 'parking' | 'restarting' | 'error'
export type WakeMode = 'interactive' | 'headless'

export interface ComputerDriver<T> {
  wake(mode?: WakeMode): Promise<T>
  promote?(): Promise<T>
  canFreeze?(): boolean
  reclaimMemory?(mode?: 'freeze' | 'pressure'): Promise<void>
  freeze?(): Promise<void>
  thaw?(): Promise<void>
  park(): Promise<void>
  restart?(): Promise<T>
}

export class ComputerConflictError extends Error {}

/** How often a computer kept awake by something holding no lease is checked again. */
export const BUSY_RECHECK_MS = 60_000

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
  private beforePark: (() => Promise<void>) | undefined
  private freezeAllowed: () => boolean = () => true
  private busy: () => Promise<boolean> = async () => false
  /** Since when the computer has had no lease and nothing has kept it busy. */
  private idleSince = Date.now()
  private parkedGeneration = 0
  private cancelParkedWork: () => void = () => {}
  private parkedWorkCancellers = new Set<() => void>()

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
  setBeforePark(work: () => Promise<void>): void { this.beforePark = work }
  setFreezeAllowed(check: () => boolean): void { this.freezeAllowed = check }
  /**
   * Work that holds no lease but keeps the computer in use: a server it runs, a managed
   * service. While it answers true the computer neither freezes nor parks; it parks only
   * after a full idle timeout since it last answered true. A check that fails counts as idle.
   */
  setBusyCheck(check: () => Promise<boolean>): void { this.busy = check }

  private async isBusy(): Promise<boolean> {
    let busy = false
    try { busy = await this.busy() } catch (error) { console.error('Could not check whether the computer is in use:', error instanceof Error ? error.message : error) }
    if (busy) this.idleSince = Date.now()
    return busy
  }

  private async reclaimBeforeSuspend(): Promise<void> {
    if (this.beforePark) try { await this.beforePark() } catch {}
    if (this.driver.reclaimMemory) try { await this.driver.reclaimMemory() } catch {}
  }

  /** Cancel external parked work synchronously before a state-changing admission is queued. */
  setParkedWorkCanceller(cancel: () => void): void { this.cancelParkedWork = cancel }

  /** Another canceller for other parked work; returns its removal. */
  addParkedWorkCanceller(cancel: () => void): () => void {
    this.parkedWorkCancellers.add(cancel)
    return () => { this.parkedWorkCancellers.delete(cancel) }
  }

  private invalidateParkedWork(): void {
    this.parkedGeneration++
    this.cancelParkedWork()
    for (const cancel of [...this.parkedWorkCancellers]) cancel()
  }

  /** Recheck after asynchronous work, including while holding parkedExclusive. */
  isParkedGenerationCurrent(generation: number): boolean {
    return !this.retired && !this.restartPending && this.current === 'parked' && this.parkedGeneration === generation
  }

  /** Capture a park attempt before asynchronous sidecar work starts. A wake,
   * restart or delete invalidates it synchronously, including during a park. */
  parkingGenerationGuard(): () => boolean {
    const generation = this.parkedGeneration
    return () => !this.retired && !this.restartPending && this.current === 'parking' && this.parkedGeneration === generation
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

  /**
   * Waits for the computer to be idle. A retry keeps counting from the same start; anything
   * else (a lease released, a wake, a new setting) starts the count again. A running computer
   * that could park is checked every minute (or sooner) while it waits, so a busy spell is
   * seen even when the check before the deadline happens to fall in a short gap.
   */
  private armIdle(retryMs?: number): void {
    this.clearIdle()
    if (retryMs === undefined) this.idleSince = Date.now()
    if (this.leases || !['running', 'frozen'].includes(this.current) || this.retired) return
    const freezing = this.current === 'running' && this.idleMs > 3000 && this.freezeAllowed() && this.driver.canFreeze?.() && this.driver.freeze && this.driver.thaw
    const delay = this.current === 'frozen' ? Math.min(this.idleMs - 3000, this.freezeParkMs) : freezing ? 3000 : Math.min(this.idleMs, BUSY_RECHECK_MS)
    this.idleTimer = setTimeout(() => {
      this.idleTimer = undefined
      void this.serialize(async () => {
        if (this.leases !== 0) return
        if (freezing && !this.freezeAllowed()) { this.armIdle(); return }
        if (this.current === 'running') {
          if (await this.isBusy()) { this.armIdle(Math.min(this.idleMs, BUSY_RECHECK_MS)); return }
          const quiet = Date.now() - this.idleSince
          if (!freezing && quiet < this.idleMs) { this.armIdle(Math.min(this.idleMs - quiet, BUSY_RECHECK_MS)); return }
        }
        if (freezing && this.current === 'running') {
          // Publish the fence before awaiting the VMM so new work queues behind pause.
          this.setState('frozen')
          try {
            if (!await this.beforeFreeze()) {
              this.setState('running')
              this.armIdle(30_000)
              return
            }
            if (this.beforePark || this.driver.reclaimMemory) await this.reclaimBeforeSuspend()
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
    const wasRunning = this.current === 'running'
    this.clearIdle()
    this.setState('parking')
    try {
      if (wasRunning && (this.beforePark || this.driver.reclaimMemory)) await this.reclaimBeforeSuspend()
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

  /** Whether something holding no lease keeps the computer in use now (setBusyCheck); false unless it is running. */
  busyNow(): Promise<boolean> {
    return this.serialize(async () => this.current === 'running' && !this.retired && await this.isBusy())
  }

  /**
   * Lets go of a running computer without parking it, when the host stops and the computer
   * outlives it (a container): `before` closes the caller's sockets, and nothing is accepted
   * afterwards. The next host adopts it again.
   */
  leave(before: () => void = () => {}): Promise<void> {
    this.clearIdle()
    this.retired = true
    return this.serialize(async () => { before(); this.clearIdle() })
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
