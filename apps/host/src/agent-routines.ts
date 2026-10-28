import { randomUUID } from 'node:crypto'
import { mkdir, open, rename, unlink } from 'node:fs/promises'
import { dirname } from 'node:path'
import { advanceRecurrence, nextOccurrence, parseRecurrenceSchedule, type RecurrenceSchedule } from '@braedonsaunders/appkit-jobs/recurrence'
import { AgentConflictError, AgentInputError, AgentNotFoundError } from './agents.js'

export interface RoutineSnapshot { revision: string; input: Record<string, unknown> }
export interface RoutineTask { status: 'active' | 'succeeded' | 'failed'; detail?: string }
export interface RoutineRuntime {
  snapshot(profileId: string, prompt: string): Promise<RoutineSnapshot | null>
  /** Wake and acquire the existing computer lease, before durable lookup. */
  acquire(): Promise<() => void>
  /** Null means definitively absent after task restoration, never unknown. */
  lookup(taskId: string): Promise<RoutineTask | null>
  /** Idempotent admission using the exact persisted input and UUID. */
  start(input: Record<string, unknown>, taskId: string): Promise<RoutineTask>
}
export interface RoutineClock { now(): number; setTimeout(fn: () => void, ms: number): unknown; clearTimeout(timer: unknown): void }
export interface AgentRoutine {
  id: string; name: string; profileId: string; prompt: string; schedule: RecurrenceSchedule
  paused: boolean; missed: 'skip' | 'coalesce'; overlap: 'skip'; deliveryGraceMs: number
  revision: number; profileRevision: string | null; nextAt: string | null; createdAt: string; updatedAt: string
}
export interface AgentRoutineRun {
  id: string; routineId: string; profileId: string; routineRevision: number; profileRevision: string
  scheduledAt: string; createdAt: string; finishedAt: string | null
  trigger: 'schedule' | 'manual'; status: 'reserved' | 'active' | 'succeeded' | 'failed' | 'skipped'
  input: Record<string, unknown>; detail?: string
}
export interface RoutineState { version: 1; routines: AgentRoutine[]; runs: AgentRoutineRun[] }
export interface RoutinePersistence { load(): Promise<unknown>; save(state: RoutineState): Promise<void> }
export interface RoutineOptions { runtime: RoutineRuntime; clock?: RoutineClock; onChange?: () => void; onError?: (error: unknown) => void }
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const MAX_ROUTINES = 100, HISTORY = 100, MAX_INPUT = 512_000
const realClock: RoutineClock = { now: Date.now, setTimeout: (fn, ms) => setTimeout(fn, ms), clearTimeout: timer => clearTimeout(timer as ReturnType<typeof setTimeout>) }
function obj(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new AgentInputError('Expected an object')
  return value as Record<string, unknown>
}
function text(value: unknown, name: string, max: number): string {
  if (typeof value !== 'string' || !value.trim() || value.length > max || value.includes('\0')) throw new AgentInputError(`Invalid ${name}`)
  return value.trim()
}
function uuid(value: unknown): string {
  if (typeof value !== 'string' || !UUID.test(value)) throw new AgentInputError('Invalid UUID')
  return value
}
function instant(value: unknown): string {
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value)) || new Date(value).toISOString() !== value) throw new AgentInputError('Invalid timestamp')
  return value
}
function integer(value: unknown, min: number, max: number): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < min || value > max) throw new AgentInputError('Invalid routine number')
  return value
}
function payload(value: unknown): Record<string, unknown> {
  const input = obj(value)
  const encoded = JSON.stringify(input)
  if (Buffer.byteLength(encoded) > MAX_INPUT) throw new AgentInputError('Routine launch input is too large')
  return JSON.parse(encoded) as Record<string, unknown>
}
function fields(value: unknown, previous?: AgentRoutine) {
  const p = obj(value)
  for (const key of Object.keys(p)) if (!['name', 'profileId', 'prompt', 'schedule', 'paused', 'missed', 'overlap', 'deliveryGraceMs'].includes(key)) throw new AgentInputError(`Unknown field: ${key}`)
  const paused = p.paused ?? previous?.paused ?? false
  const missed = p.missed ?? previous?.missed ?? 'skip'
  const overlap = p.overlap ?? previous?.overlap ?? 'skip'
  if (typeof paused !== 'boolean' || (missed !== 'skip' && missed !== 'coalesce') || overlap !== 'skip') throw new AgentInputError('Invalid routine policy')
  let schedule: RecurrenceSchedule
  try { schedule = parseRecurrenceSchedule(p.schedule ?? previous?.schedule) } catch (error) { throw new AgentInputError(String(error)) }
  return { name: text(p.name ?? previous?.name, 'name', 80), profileId: uuid(p.profileId ?? previous?.profileId), prompt: text(p.prompt ?? previous?.prompt, 'prompt', 16_000), schedule, paused, missed, overlap, deliveryGraceMs: integer(p.deliveryGraceMs ?? previous?.deliveryGraceMs ?? 30_000, 0, 300_000) } as const
}
function pending(run: AgentRoutineRun) { return run.status === 'reserved' || run.status === 'active' }
function prune(state: RoutineState) {
  // Terminal launch envelopes are no longer needed for recovery.
  for (const run of state.runs) if (!pending(run)) run.input = {}
  state.runs = [...state.runs.filter(pending), ...state.runs.filter(r => !pending(r)).slice(-HISTORY)]
}
function decode(value: unknown): RoutineState {
  if (value === undefined) return { version: 1, routines: [], runs: [] }
  const state = obj(value)
  if (state.version !== 1 || !Array.isArray(state.routines) || state.routines.length > MAX_ROUTINES || !Array.isArray(state.runs) || state.runs.length > MAX_ROUTINES + HISTORY) throw new Error('Invalid routine store')
  const routines = state.routines.map(raw => {
    const r = obj(raw)
    const { id, revision, profileRevision, nextAt, createdAt, updatedAt, ...input } = r
    const routine = { id: uuid(id), ...fields(input), revision: integer(revision, 1, Number.MAX_SAFE_INTEGER), profileRevision: profileRevision === null ? null : text(profileRevision, 'profile revision', 256), nextAt: nextAt === null ? null : instant(nextAt), createdAt: instant(createdAt), updatedAt: instant(updatedAt) }
    if (routine.nextAt !== null) advanceRecurrence(routine.schedule, { nextAt: routine.nextAt }, routine.nextAt, 'skip')
    return routine
  })
  const runs = state.runs.map(raw => {
    const r = obj(raw)
    if (!['reserved', 'active', 'succeeded', 'failed', 'skipped'].includes(String(r.status)) || !['schedule', 'manual'].includes(String(r.trigger))) throw new Error('Invalid routine run')
    return { id: uuid(r.id), routineId: uuid(r.routineId), profileId: uuid(r.profileId), routineRevision: integer(r.routineRevision, 1, Number.MAX_SAFE_INTEGER), profileRevision: text(r.profileRevision, 'profile revision', 256), scheduledAt: instant(r.scheduledAt), createdAt: instant(r.createdAt), finishedAt: r.finishedAt === null ? null : instant(r.finishedAt), status: r.status as AgentRoutineRun['status'], trigger: r.trigger as AgentRoutineRun['trigger'], input: payload(r.input), ...(r.detail === undefined ? {} : { detail: text(r.detail, 'detail', 2000) }) }
  })
  if (new Set(routines.map(r => r.id)).size !== routines.length || new Set(runs.map(r => r.id)).size !== runs.length || new Set(runs.filter(pending).map(r => r.routineId)).size !== runs.filter(pending).length) throw new Error('Duplicate routine or active run')
  return { version: 1, routines, runs }
}

/** One instance per computer/state file. The host must not share the file across processes. */
export class AgentRoutines {
  private sequence: Promise<unknown> = Promise.resolve()
  private flight: Promise<void> | undefined
  private closed = false
  private fault: unknown
  private timer: unknown
  private readonly clock: RoutineClock
  private constructor(private state: RoutineState, private persistence: RoutinePersistence, private options: RoutineOptions) { this.clock = options.clock ?? realClock }
  static async create(persistence: RoutinePersistence, options: RoutineOptions): Promise<AgentRoutines> {
    return new AgentRoutines(decode(await persistence.load()), persistence, options)
  }
  static async open(path: string, options: RoutineOptions): Promise<AgentRoutines> {
    return AgentRoutines.create({
      load: async () => { try { const file = await open(path, 'r'); try { if ((await file.stat()).size > 64_000_000) throw new Error('Routine store too large'); return JSON.parse(await file.readFile('utf8')) } finally { await file.close() } } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined; throw error } },
      save: async state => {
        await mkdir(dirname(path), { recursive: true })
        const temporary = `${path}.${randomUUID()}.tmp`
        try {
          const file = await open(temporary, 'wx', 0o600)
          try { await file.writeFile(JSON.stringify(state)); await file.sync() } finally { await file.close() }
          await rename(temporary, path)
          const directory = await open(dirname(path), 'r')
          try { await directory.sync() } finally { await directory.close() }
        } finally { await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error }) }
      },
    }, options)
  }
  private now() { return new Date(this.clock.now()).toISOString() }
  private serial<T>(fn: () => Promise<T>): Promise<T> {
    if (this.closed) return Promise.reject(new Error('Routine scheduler is closed'))
    const operation = this.sequence.then(() => {
      if (this.fault) throw new Error('Routine persistence failed; reopen scheduler before continuing', { cause: this.fault })
      return fn()
    })
    this.sequence = operation.catch(() => {})
    return operation
  }
  private async commit(state: RoutineState) {
    prune(state)
    try { await this.persistence.save(structuredClone(state)) } catch (error) { this.fault = error; throw error }
    this.state = state
    try { this.options.onChange?.() } catch (error) { this.report(error) }
  }
  private report(error: unknown) { try { this.options.onError?.(error) } catch {} }
  list(): AgentRoutine[] { return structuredClone(this.state.routines) }
  get(id: string, expectedProfileId?: string): AgentRoutine {
    const r = this.state.routines.find(r => r.id === id)
    if (!r) throw new AgentNotFoundError('Routine not found')
    if (expectedProfileId !== undefined && r.profileId !== expectedProfileId) throw new AgentInputError('Routine does not belong to this profile')
    return structuredClone(r)
  }
  history(id?: string): AgentRoutineRun[] { return structuredClone(this.state.runs.filter(r => !id || r.routineId === id).map(r => ({ ...r, input: {} })).reverse()) }
  async create(value: unknown): Promise<AgentRoutine> {
    const input = fields(value)
    return this.serial(async () => {
      if (this.state.routines.length >= MAX_ROUTINES) throw new AgentConflictError('Routine limit reached')
      const snapshot = await this.options.runtime.snapshot(input.profileId, input.prompt)
      if (!snapshot) throw new AgentInputError('Profile missing or archived')
      const now = this.now(), r = { id: randomUUID(), ...input, revision: 1, profileRevision: text(snapshot.revision, 'profile revision', 256), nextAt: nextOccurrence(input.schedule, now), createdAt: now, updatedAt: now }
      const next = structuredClone(this.state); next.routines.push(r); await this.commit(next); return structuredClone(r)
    })
  }
  update(id: string, value: unknown, expectedProfileId?: string): Promise<AgentRoutine> {
    return this.serial(async () => {
      const previous = this.get(id, expectedProfileId), input = fields(value, previous), now = this.now()
      if (expectedProfileId !== undefined && input.profileId !== expectedProfileId) throw new AgentInputError('Routine does not belong to this profile')
      const next = structuredClone(this.state), r = next.routines.find(r => r.id === id)!
      const snapshot = await this.options.runtime.snapshot(input.profileId, input.prompt)
      if (expectedProfileId !== undefined && !snapshot) throw new AgentInputError('Profile missing or archived')
      Object.assign(r, input, { profileRevision: snapshot?.revision ?? null, revision: r.revision + 1, updatedAt: now, nextAt: nextOccurrence(input.schedule, now) })
      await this.commit(next); return structuredClone(r)
    })
  }
  delete(id: string, expectedProfileId?: string): Promise<void> {
    return this.serial(async () => {
      const routine = this.get(id, expectedProfileId)
      if (expectedProfileId !== undefined && !await this.options.runtime.snapshot(routine.profileId, routine.prompt)) throw new AgentInputError('Profile missing or archived')
      const next = structuredClone(this.state); next.routines = next.routines.filter(r => r.id !== id); await this.commit(next)
    })
  }
  /** Await after every profile mutation, including archive/restore, before acknowledging it. */
  profileChanged(profileId: string): Promise<void> {
    return this.serial(async () => {
      const next = structuredClone(this.state), now = this.now()
      for (const r of next.routines.filter(r => r.profileId === profileId)) {
        r.profileRevision = (await this.options.runtime.snapshot(r.profileId, r.prompt))?.revision ?? null
        r.revision++; r.updatedAt = now; r.nextAt = nextOccurrence(r.schedule, now)
      }
      await this.commit(next)
    })
  }
  async runNow(id: string, expectedProfileId?: string): Promise<AgentRoutineRun> {
    const run = await this.serial(async () => {
      this.get(id, expectedProfileId)
      const next = structuredClone(this.state), routine = next.routines.find(r => r.id === id)!
      if (routine.paused || next.runs.some(r => r.routineId === id && pending(r))) throw new AgentConflictError('Routine paused or already active')
      const run = await this.reserve(next, routine, this.now(), 'manual')
      if (!run) throw new AgentConflictError('Profile missing or archived')
      await this.commit(next); return structuredClone(run)
    })
    // Host polling dispatches reservations, including this one, without an HTTP lifetime.
    return run
  }
  private async reserve(state: RoutineState, r: AgentRoutine, due: string, trigger: 'manual' | 'schedule') {
    if (state.runs.some(run => run.routineId === r.id && pending(run))) return null
    if (state.runs.filter(pending).length >= MAX_ROUTINES) throw new AgentConflictError('Active routine run limit reached')
    const snapshot = await this.options.runtime.snapshot(r.profileId, r.prompt)
    if (!snapshot) return null
    const revision = text(snapshot.revision, 'profile revision', 256)
    if (r.profileRevision !== revision) {
      r.profileRevision = revision; r.revision++; r.updatedAt = this.now()
      r.nextAt = nextOccurrence(r.schedule, r.updatedAt)
    }
    const run: AgentRoutineRun = { id: randomUUID(), routineId: r.id, profileId: r.profileId, routineRevision: r.revision, profileRevision: revision, scheduledAt: due, createdAt: this.now(), finishedAt: null, trigger, status: 'reserved', input: payload(snapshot.input) }
    state.runs.push(run); return run
  }
  tick(): Promise<void> {
    if (this.closed) return Promise.reject(new Error('Routine scheduler is closed'))
    if (this.flight) return this.flight
    const work = this.cycle(); this.flight = work
    void work.finally(() => { if (this.flight === work) this.flight = undefined }).catch(() => {})
    return work
  }
  private async cycle() {
    await this.serial(async () => {
      const next = structuredClone(this.state), now = this.now()
      let changed = false
      for (const r of next.routines) {
        const snapshot = await this.options.runtime.snapshot(r.profileId, r.prompt)
        const revision = snapshot ? text(snapshot.revision, 'profile revision', 256) : null
        if (revision !== r.profileRevision) {
          changed = true
          r.profileRevision = revision; r.revision++; r.updatedAt = now
          r.nextAt = nextOccurrence(r.schedule, now)
          continue
        }
        if (!snapshot) {
          const nextAt = nextOccurrence(r.schedule, now)
          if (r.nextAt !== nextAt) { r.nextAt = nextAt; changed = true }
          continue
        }
        if (r.paused || r.nextAt === null || r.nextAt > now) continue
        // AppKit skip is strict. Explicit grace admits the persisted tick during normal polling.
        const policy = r.missed === 'coalesce' || Date.parse(now) - Date.parse(r.nextAt) <= r.deliveryGraceMs ? 'coalesce' : 'skip'
        const advance = advanceRecurrence(r.schedule, { nextAt: r.nextAt }, now, policy)
        r.nextAt = advance.nextAt
        changed = true
        if (advance.dueAt) await this.reserve(next, r, advance.dueAt, 'schedule')
      }
      if (changed) await this.commit(next)
    })
    for (const run of this.state.runs.filter(pending)) {
      if (this.closed || this.fault) break
      await this.dispatch(run.id)
    }
  }
  private async dispatch(id: string) {
    let release: (() => void) | undefined
    try {
      release = await this.options.runtime.acquire()
      if (this.closed) return
      const task = await this.options.runtime.lookup(id)
      await this.serial(async () => {
        const next = structuredClone(this.state), run = next.runs.find(r => r.id === id)
        if (!run || !pending(run)) return
        if (task) {
          const detail = task.detail ? task.detail.slice(0, 2000) : undefined
          if (task.status === 'active' && run.status === 'active' && run.detail === detail) return
          this.apply(run, task); await this.commit(next); return
        }
        if (run.status === 'active') { run.status = 'failed'; run.detail = 'Previously admitted task is missing; effects are not retried.'; run.finishedAt = this.now(); await this.commit(next); return }
        const routine = next.routines.find(r => r.id === run.routineId)
        const snapshot = routine ? await this.options.runtime.snapshot(routine.profileId, routine.prompt) : null
        if (this.closed) return
        const expired = routine && run.trigger === 'schedule' && routine.missed === 'skip' && this.clock.now() - Date.parse(run.scheduledAt) > routine.deliveryGraceMs
        if (expired || !routine || routine.paused || routine.revision !== run.routineRevision || !snapshot || snapshot.revision !== run.profileRevision) {
          run.status = 'skipped'; run.detail = 'Routine or profile changed, paused, archived, deleted, or delivery grace expired before dispatch.'; run.finishedAt = this.now(); await this.commit(next); return
        }
        // Reservation is already durable. A thrown admission remains reserved for same-ID lookup.
        this.apply(run, await this.options.runtime.start(structuredClone(run.input), id))
        await this.commit(next)
      })
    } catch (error) {
      this.report(error)
      // Persist diagnostic only; never turn ambiguous admission into a new task.
      if (!this.closed && !this.fault) await this.serial(async () => {
        const next = structuredClone(this.state), run = next.runs.find(r => r.id === id)
        if (run && pending(run)) {
          const detail = String(error).slice(0, 2000) || 'Dispatch failed'
          if (run.detail !== detail) { run.detail = detail; await this.commit(next) }
        }
      })
    } finally { release?.() }
  }
  private apply(run: AgentRoutineRun, task: RoutineTask) {
    if (!['active', 'succeeded', 'failed'].includes(task.status)) throw new Error('Invalid task status')
    run.status = task.status
    delete run.detail
    if (task.detail) run.detail = task.detail.slice(0, 2000)
    if (task.status !== 'active') run.finishedAt = this.now()
  }
  start(pollMs = 1000): void {
    integer(pollMs, 100, 60_000)
    if (this.closed) throw new Error('Routine scheduler is closed')
    if (this.timer !== undefined) return
    const poll = async () => {
      try { await this.tick() } catch (error) { this.report(error) }
      if (!this.closed) this.timer = this.clock.setTimeout(() => { void poll() }, pollMs)
    }
    this.timer = this.clock.setTimeout(() => { void poll() }, 0)
  }
  async close(): Promise<void> {
    this.closed = true
    if (this.timer !== undefined) this.clock.clearTimeout(this.timer)
    this.timer = undefined
    await this.flight?.catch(() => {})
    await this.sequence
  }
}
