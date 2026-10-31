import { randomBytes } from 'node:crypto'
import { mkdir, readdir, readFile, unlink, open as openFile } from 'node:fs/promises'
import { join } from 'node:path'
import { AgentConflictError, AgentInputError, AgentNotFoundError, AgentOperationError, AgentUnavailableError, type AgentGuest } from './agents.js'
import type { Job } from './activities.js'
import { readJsonFile, writePrivateJson } from './settings.js'

/** Bounds of `/v1/commands`: request sizes, run time, capture and what the host keeps. */
export const COMMAND_LIMITS = {
  /** The request body; stdin is the large part. */
  bodyBytes: 4 * 1024 * 1024,
  scriptBytes: 64 * 1024,
  stdinBytes: 1024 * 1024,
  /** Kept of each stream: the first bytes of stdout, the last of stderr. */
  outputBytes: 1024 * 1024,
  inputs: 100,
  outputs: 100,
  defaultTimeout: 3600,
  maxTimeout: 86_400,
  maxWait: 60,
  /** Commands running at once on one computer. */
  running: 4,
  /** Finished commands kept, and for how long. */
  kept: 50,
  keptMs: 7 * 86_400_000,
} as const

export const COMMAND_ID = /^[0-9a-f]{32}$/
export type CommandStatus = 'running' | 'succeeded' | 'failed' | 'timed-out' | 'cancelled'
const FINISHED: CommandStatus[] = ['succeeded', 'failed', 'timed-out', 'cancelled']

export interface CommandRequest {
  id?: string
  script: string
  stdin?: string
  inputs: string[]
  /** Home-relative working directory; null runs in the job directory. */
  cwd: string | null
  timeout: number
  wait: number
}

export interface CommandRecord {
  id: string
  title: string
  script: string
  cwd: string | null
  inputs: string[]
  timeout: number
  status: CommandStatus
  exitCode: number | null
  signal: string | null
  error: string | null
  stdout: string
  stderr: string
  truncated: { stdout: boolean; stderr: boolean }
  outputs: string[]
  createdAt: string
  finishedAt: string | null
}

const CONTROL = /[\u0000-\u001f\u007f]/
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/

/** A file name in a job's in/ or out/: one plain component of at most 255 bytes. */
export function plainName(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value !== '.' && value !== '..' && !value.includes('/') &&
    !CONTROL.test(value) && !LONE_SURROGATE.test(value) && !value.startsWith('.caboose-upload-') && Buffer.byteLength(value) <= 255
}

function text(value: unknown, name: string, maxBytes: number): string {
  if (typeof value !== 'string' || LONE_SURROGATE.test(value)) throw new AgentInputError(`${name} must be text`)
  if (Buffer.byteLength(value) > maxBytes) throw new AgentInputError(`${name} is larger than ${maxBytes / 1024} KiB`)
  return value
}

function integer(value: unknown, name: string, min: number, max: number, fallback: number): number {
  if (value === undefined) return fallback
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < min || value > max) throw new AgentInputError(`${name} must be a whole number from ${min} to ${max}`)
  return value
}

/** A `POST /v1/commands` body, checked field by field; unknown fields are refused. */
export function parseCommandRequest(input: Record<string, unknown>): CommandRequest {
  const unknown = Object.keys(input).find(key => !['id', 'script', 'stdin', 'inputs', 'cwd', 'timeout', 'wait'].includes(key))
  if (unknown) throw new AgentInputError(`unknown command field: ${unknown.slice(0, 40)}`)
  if (input.id !== undefined && (typeof input.id !== 'string' || !COMMAND_ID.test(input.id))) throw new AgentInputError('id must be 32 lowercase hex digits')
  const script = text(input.script, 'script', COMMAND_LIMITS.scriptBytes)
  if (!script.trim()) throw new AgentInputError('script is empty')
  if (script.includes('\0')) throw new AgentInputError('script contains a NUL character')
  const stdin = input.stdin === undefined ? undefined : text(input.stdin, 'stdin', COMMAND_LIMITS.stdinBytes)
  const inputs = input.inputs ?? []
  if (!Array.isArray(inputs) || inputs.length > COMMAND_LIMITS.inputs || !inputs.every(plainName) || new Set(inputs).size !== inputs.length) {
    throw new AgentInputError(`inputs must be at most ${COMMAND_LIMITS.inputs} distinct file names`)
  }
  if (inputs.length && input.id === undefined) throw new AgentInputError('inputs need the id whose job directory holds them')
  let cwd: string | null = null
  if (input.cwd !== undefined && input.cwd !== null) {
    if (typeof input.cwd !== 'string' || Buffer.byteLength(input.cwd) > 4096 || (input.cwd !== '' && !input.cwd.split('/').every(part => plainName(part)))) {
      throw new AgentInputError('cwd must be a path relative to the home')
    }
    cwd = input.cwd
  }
  return {
    ...(input.id !== undefined ? { id: input.id as string } : {}),
    script, ...(stdin !== undefined ? { stdin } : {}), inputs: inputs as string[], cwd,
    timeout: integer(input.timeout, 'timeout', 1, COMMAND_LIMITS.maxTimeout, COMMAND_LIMITS.defaultTimeout),
    wait: integer(input.wait, 'wait', 0, COMMAND_LIMITS.maxWait, 0),
  }
}

/** `?wait=` on `GET /v1/commands/:id`: whole seconds up to the maximum, 0 when absent. */
export function parseWait(value: string | null): number {
  if (value === null) return 0
  if (!/^\d{1,2}$/.test(value) || Number(value) > COMMAND_LIMITS.maxWait) throw new AgentInputError(`wait must be a whole number from 0 to ${COMMAND_LIMITS.maxWait}`)
  return Number(value)
}

/** A command's name for lists and notifications: its first nonblank line, shortened. */
export function commandTitle(script: string): string {
  const line = script.split('\n').map(value => value.trim()).find(value => value && !value.startsWith('#!')) ?? 'Command'
  const characters = Array.from(line.replace(/[\u0000-\u001f\u007f]/g, ' '))
  return characters.length > 100 ? characters.slice(0, 99).join('') + '…' : characters.join('')
}

export type GuestOutcome = Pick<CommandRecord, 'status' | 'exitCode' | 'signal' | 'error' | 'truncated' | 'outputs'>

/** The supervisor's result.json, from the guest and so untrusted, checked field by field. */
export function parseGuestResult(value: unknown): GuestOutcome {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('result is not an object')
  const v = value as Record<string, unknown>
  if (!FINISHED.includes(v.status as CommandStatus)) throw new Error('invalid status')
  if (v.exitCode !== null && (typeof v.exitCode !== 'number' || !Number.isSafeInteger(v.exitCode) || v.exitCode < 0 || v.exitCode > 255)) throw new Error('invalid exit code')
  if (v.signal !== null && (typeof v.signal !== 'string' || !/^SIG[A-Z0-9]{1,12}$/.test(v.signal))) throw new Error('invalid signal')
  if (v.error !== null && typeof v.error !== 'string') throw new Error('invalid error')
  const truncated = v.truncated as Record<string, unknown> | undefined
  if (!truncated || typeof truncated !== 'object' || typeof truncated.stdout !== 'boolean' || typeof truncated.stderr !== 'boolean') throw new Error('invalid truncation')
  const outputs = v.outputs
  if (!Array.isArray(outputs) || outputs.length > COMMAND_LIMITS.outputs || !outputs.every(plainName) || new Set(outputs).size !== outputs.length) throw new Error('invalid outputs')
  return {
    status: v.status as CommandStatus, exitCode: v.exitCode as number | null, signal: v.signal as string | null,
    error: typeof v.error === 'string' ? v.error.slice(0, 500) : null,
    truncated: { stdout: truncated.stdout, stderr: truncated.stderr }, outputs: outputs as string[],
  }
}

/** Kept output from the guest's base64, never more than the bound, as text. */
export function decodeStream(value: string): { text: string; truncated: boolean } {
  const trimmed = value.trim()
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(trimmed)) throw new Error('invalid stream encoding')
  const bytes = Buffer.from(trimmed, 'base64')
  const kept = bytes.subarray(0, COMMAND_LIMITS.outputBytes)
  return { text: kept.toString('utf8'), truncated: kept.length < bytes.length }
}

/** The command as a Live Activity and `job.progress` job. */
export function commandJob(record: CommandRecord): Job {
  const status = record.status === 'timed-out' ? 'failed' : record.status
  let detail: string
  switch (record.status) {
    case 'running': detail = 'Running'; break
    case 'succeeded': detail = record.outputs.length ? `Finished with ${record.outputs.length} file${record.outputs.length === 1 ? '' : 's'}` : 'Finished'; break
    case 'timed-out': detail = `Stopped after ${record.timeout} s`; break
    case 'cancelled': detail = 'Cancelled'; break
    default: detail = record.error ?? (record.signal ? `Stopped by ${record.signal}` : `Exited with code ${record.exitCode}`)
  }
  return { id: record.id, kind: 'command', title: record.title, status, detail: detail.slice(0, 500) }
}

/** A command as `GET /v1/commands` lists it. */
export function commandSummary(record: CommandRecord) {
  return { id: record.id, title: record.title, status: record.status, exitCode: record.exitCode, createdAt: record.createdAt, finishedAt: record.finishedAt }
}

/** A command as its routes answer: the record and where its files are. */
export function commandView(record: CommandRecord) {
  return { ...record, directory: `.caboose-jobs/cmd-${record.id}` }
}

function parseRecord(value: unknown): CommandRecord {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('not an object')
  const v = value as CommandRecord
  if (!COMMAND_ID.test(v.id) || typeof v.title !== 'string' || typeof v.script !== 'string' || (v.cwd !== null && typeof v.cwd !== 'string') ||
      !Array.isArray(v.inputs) || !Number.isSafeInteger(v.timeout) || !['running', ...FINISHED].includes(v.status) ||
      typeof v.stdout !== 'string' || typeof v.stderr !== 'string' || typeof v.createdAt !== 'string' || (v.finishedAt !== null && typeof v.finishedAt !== 'string')) throw new Error('invalid record')
  const outcome = v.status === 'running' ? undefined : parseGuestResult({ ...v, error: v.error ?? null })
  return {
    id: v.id, title: v.title, script: v.script, cwd: v.cwd, inputs: v.inputs.filter(plainName), timeout: v.timeout, status: v.status,
    exitCode: outcome?.exitCode ?? null, signal: outcome?.signal ?? null, error: outcome?.error ?? null,
    stdout: v.stdout, stderr: v.stderr, truncated: outcome?.truncated ?? { stdout: false, stderr: false }, outputs: outcome?.outputs ?? [],
    createdAt: v.createdAt, finishedAt: v.finishedAt,
  }
}

/**
 * Commands of one computer, one private JSON file each in the host's state, so their
 * results outlive the phone that asked and the host process. Without a directory (tests)
 * they are kept in memory.
 */
export class CommandStore {
  private records = new Map<string, CommandRecord>()
  private pending: Promise<void> = Promise.resolve()
  private pendingWrites = 0
  private failures = new Map<string, unknown>()
  get persistenceStatus(): { pendingWrites: number; error: unknown } {
    return { pendingWrites: this.pendingWrites, error: this.failures.values().next().value ?? null }
  }

  /** Caller excludes new mutations. Never mistake a swallowed queue rejection for durability. */
  async drain(): Promise<void> {
    let work: Promise<void>
    do { work = this.pending; await work } while (work !== this.pending)
    if (this.failures.size) throw new Error('Command receipts are not durably persisted', { cause: this.persistenceStatus.error })
  }

  private persist(id: string, operation: () => Promise<void>): Promise<void> {
    this.pendingWrites++
    const work = this.pending.then(async () => {
      await operation()
      if (this.dir) {
        const directory = await openFile(this.dir, 'r')
        try { await directory.sync() } finally { await directory.close() }
      }
      this.failures.delete(id)
    }).catch(error => { this.failures.set(id, error); throw error }).finally(() => { this.pendingWrites-- })
    this.pending = work.catch(() => {})
    return work
  }
  private constructor(private readonly dir: string | undefined, private readonly now: () => number) {}

  /** A store that keeps nothing beyond the process, for a host without a state directory. */
  static memory(now: () => number = Date.now): CommandStore { return new CommandStore(undefined, now) }

  static async open(dir?: string, now: () => number = Date.now): Promise<CommandStore> {
    const store = new CommandStore(dir, now)
    if (!dir) return store
    await mkdir(dir, { recursive: true, mode: 0o700 })
    for (const name of await readdir(dir)) {
      const match = /^([0-9a-f]{32})\.json$/.exec(name)
      if (!match) continue
      try {
        const record = parseRecord(await readJsonFile(join(dir, name)))
        if (record.id === match[1]) store.records.set(record.id, record)
      } catch (error) { store.failures.set(match[1]!, error); console.error(`Ignoring unreadable command record ${name}:`, error instanceof Error ? error.message : error) }
    }
    await store.prune()
    return store
  }

  get(id: string): CommandRecord | undefined { return this.records.get(id) }
  /** Newest first. */
  list(): CommandRecord[] { return [...this.records.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt)) }

  save(record: CommandRecord): Promise<void> {
    this.records.set(record.id, record)
    const dir = this.dir
    if (!dir) return Promise.resolve()
    return this.persist(record.id, () => writePrivateJson(join(dir, `${record.id}.json`), record))
  }

  async remove(id: string): Promise<void> {
    this.records.delete(id)
    const dir = this.dir
    if (!dir) return
    const work = this.persist(id, () => unlink(join(dir, `${id}.json`)).catch((error: NodeJS.ErrnoException) => { if (error.code !== 'ENOENT') throw error }))
    await work.catch(error => console.error('Could not remove a command record:', error instanceof Error ? error.message : error))
  }

  /** Keeps every running command and the most recent finished ones within their age. */
  async prune(): Promise<void> {
    const finished = this.list().filter(record => record.status !== 'running')
    const cutoff = this.now() - COMMAND_LIMITS.keptMs
    const removed = finished.filter((record, index) => index >= COMMAND_LIMITS.kept || Date.parse(record.finishedAt ?? record.createdAt) < cutoff)
    for (const record of removed) await this.remove(record.id)
  }
}

export interface CommandHooks {
  guest(): AgentGuest | undefined
  /** Writes a home-relative file through the computer's file service. */
  writeFile(relative: string, data: Buffer): Promise<void>
  /** A lifecycle lease, held while a command runs. */
  acquire(): () => void
  /** Wakes the computer (headless) with its file service ready; to recover commands after a host restart. */
  wake(): Promise<void>
  /**
   * `started` once the command runs, `long` when it is still running after the long-run
   * delay, `finished` when it ends; `waited` says whether a request was waiting for it then.
   */
  progress(record: CommandRecord, phase: 'started' | 'long' | 'finished', details: { waited: boolean; long: boolean }): void
}

let guestScript: Promise<string> | undefined
function script(): Promise<string> {
  guestScript ??= readFile(new URL('./guest-command.py', import.meta.url), 'utf8')
  return guestScript
}

/** The guest runner's refusals become 400 or 409; anything else is a guest failure (502). */
function guestError(error: unknown): Error {
  const message = error instanceof Error ? error.message : String(error)
  const refused = /caboose-command (input|conflict): ([^\n]{1,300})/.exec(message)
  if (refused) return refused[1] === 'conflict' ? new AgentConflictError(refused[2]!) : new AgentInputError(refused[2]!)
  return new AgentOperationError(message.slice(-500))
}

/**
 * Runs owner commands in the computer, detached from the request that started them: a
 * supervisor in the guest keeps going when the phone, the request or the host goes away,
 * and the host collects the result by polling.
 */
export class ComputerCommands {
  private leases = new Map<string, () => void>()
  private longTimers = new Map<string, ReturnType<typeof setTimeout>>()
  private long = new Set<string>()
  private waiters = new Map<string, Set<() => void>>()
  private starting = new Set<string>()
  private collecting = new Set<string>()
  /** Failed attempts to read a finished command's result; it fails after a few. */
  private collectFailures = new Map<string, number>()
  private timer: ReturnType<typeof setInterval> | undefined
  private polling: Promise<void> | undefined
  private checkpointHold = false
  private readonly pollMs: number
  private readonly longMs: number
  private readonly now: () => number

  constructor(private readonly store: CommandStore, private readonly hooks: CommandHooks, options: { pollMs?: number; longMs?: number; now?: () => number } = {}) {
    this.pollMs = options.pollMs ?? 1000
    this.longMs = options.longMs ?? 10_000
    this.now = options.now ?? Date.now
  }

  list(): CommandRecord[] { return this.store.list() }
  get(id: string): CommandRecord {
    const record = COMMAND_ID.test(id) ? this.store.get(id) : undefined
    if (!record) throw new AgentNotFoundError('command not found')
    return record
  }
  /** Commands that are running or starting, for refusing a park or a deletion. */
  get busy(): number { return new Set([...this.running().map(record => record.id), ...this.starting]).size }
  private running(): CommandRecord[] { return this.store.list().filter(record => record.status === 'running') }

  /**
   * After a host restart, commands the store still has as running are leased again and the
   * computer is woken to finish them; their results are collected once it runs.
   */
  recover(): void {
    if (this.checkpointHold) throw new AgentConflictError('Command checkpoint is in progress')
    const running = this.running()
    if (!running.length) return
    for (const record of running) {
      if (!this.leases.has(record.id)) this.leases.set(record.id, this.hooks.acquire())
      // Its Live Activity started long ago; its end still has to reach it.
      if (Date.parse(record.createdAt) <= this.now() - this.longMs) this.long.add(record.id)
    }
    void this.hooks.wake().catch(error => console.error('Could not wake the computer for its commands:', error instanceof Error ? error.message : error))
  }

  /** Starts a command; the computer is running, with its file service ready. */
  async start(input: CommandRequest): Promise<CommandRecord> {
    if (this.checkpointHold) throw new AgentConflictError('Command checkpoint is in progress')
    const id = input.id ?? randomBytes(16).toString('hex')
    if (this.store.get(id) || this.starting.has(id)) throw new AgentConflictError('a command with this id already exists')
    if (this.busy >= COMMAND_LIMITS.running) throw new AgentConflictError(`${COMMAND_LIMITS.running} commands are already running; wait for one to finish or cancel it`)
    const guest = this.hooks.guest()
    if (!guest) throw new AgentUnavailableError()
    this.starting.add(id)
    try {
      const source = await script()
      try { await guest.run('/usr/bin/python3', ['-c', source, 'prepare', JSON.stringify({ id })], 30_000) } catch (error) { throw guestError(error) }
      const directory = `.caboose-jobs/cmd-${id}`
      // The script and its input reach the computer as files, never on a command line.
      await this.hooks.writeFile(`${directory}/command.sh`, Buffer.from(input.script))
      if (input.stdin !== undefined) await this.hooks.writeFile(`${directory}/stdin`, Buffer.from(input.stdin))
      const record: CommandRecord = {
        id, title: commandTitle(input.script), script: input.script, cwd: input.cwd, inputs: input.inputs, timeout: input.timeout,
        status: 'running', exitCode: null, signal: null, error: null, stdout: '', stderr: '', truncated: { stdout: false, stderr: false }, outputs: [],
        createdAt: new Date(this.now()).toISOString(), finishedAt: null,
      }
      // Saved before it starts, so a host that stops in between still looks for it.
      await this.store.save(record)
      this.leases.set(id, this.hooks.acquire())
      try {
        await guest.run('/usr/sbin/runuser', ['-u', 'caboose', '--', '/usr/bin/python3', '-c', source, 'start',
          JSON.stringify({ id, cwd: input.cwd, timeout: input.timeout, stdin: input.stdin !== undefined, inputs: input.inputs })], 60_000)
      } catch (error) {
        const failure = guestError(error)
        if (failure instanceof AgentInputError || failure instanceof AgentConflictError) {
          // Explicit validation refusals precede the guest's fork.
          this.leases.get(id)?.()
          this.leases.delete(id)
          await this.store.remove(id)
          throw failure
        }
        // The supervisor may already be running when its acknowledgement is lost.
        // Keep its durable ID and lease; polling resolves the outcome without replay.
      }
      this.hooks.progress(record, 'started', { waited: false, long: false })
      const timer = setTimeout(() => {
        this.longTimers.delete(id)
        const current = this.store.get(id)
        if (current?.status !== 'running') return
        this.long.add(id)
        this.hooks.progress(current, 'long', { waited: this.waiting(id), long: true })
      }, this.longMs)
      timer.unref?.()
      this.longTimers.set(id, timer)
      this.resume()
      return record
    } finally { this.starting.delete(id) }
  }

  private waiting(id: string): boolean { return (this.waiters.get(id)?.size ?? 0) > 0 }

  /** The command once it finishes, or as it is after `seconds` (or when `signal` aborts). */
  async wait(id: string, seconds: number, signal?: AbortSignal): Promise<CommandRecord> {
    const record = this.get(id)
    if (record.status !== 'running' || seconds <= 0 || signal?.aborted) return record
    await new Promise<void>(resolve => {
      const set = this.waiters.get(id) ?? new Set<() => void>()
      this.waiters.set(id, set)
      const done = () => {
        clearTimeout(timer)
        signal?.removeEventListener('abort', done)
        set.delete(done)
        if (!set.size && this.waiters.get(id) === set) this.waiters.delete(id)
        resolve()
      }
      const timer = setTimeout(done, seconds * 1000)
      signal?.addEventListener('abort', done, { once: true })
      set.add(done)
    })
    return this.get(id)
  }

  /** Asks the supervisor to stop a running command: SIGTERM to its process group, then SIGKILL. */
  async cancel(id: string): Promise<void> {
    if (this.checkpointHold) throw new AgentConflictError('Command checkpoint is in progress')
    const record = this.get(id)
    if (record.status !== 'running') throw new AgentConflictError('the command has already finished')
    const guest = this.hooks.guest()
    if (!guest) throw new AgentUnavailableError()
    try { await guest.run('/usr/bin/python3', ['-c', await script(), 'cancel', JSON.stringify({ id })], 30_000) } catch (error) { throw guestError(error) }
    this.resume()
  }

  /** Polls while the computer runs and a command is running. */
  resume(): void {
    if (this.checkpointHold || this.timer || !this.running().length) return
    this.timer = setInterval(() => { void this.poll().catch(error => console.error('Command polling failed:', error)) }, this.pollMs)
    this.timer.unref?.()
  }

  /** The computer parked or froze: stop polling; a wake resumes it. */
  pause(): void {
    if (this.timer) clearInterval(this.timer)
    this.timer = undefined
  }

  /** Hold after request admission drains, before runtime shutdown; release after capture. */
  async quiesceForCheckpoint(timeoutMs = 5000): Promise<() => void> {
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 300_000) throw new Error('Invalid command drain timeout')
    if (this.checkpointHold) throw new AgentConflictError('Command checkpoint is in progress')
    // Refuse active work without stopping its result polling or releasing its lease.
    if (this.busy) throw new AgentConflictError('A command is running; cancel it or wait for it to finish')
    this.checkpointHold = true
    this.pause()
    let released = false
    const release = () => {
      if (released) return
      released = true; this.checkpointHold = false; this.resume()
    }
    const drained = (async () => { await this.polling; await this.store.drain() })()
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      await Promise.race([drained, new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new AgentConflictError('Command persistence did not drain before the checkpoint deadline')), timeoutMs)
      })])
      if (this.busy) throw new AgentConflictError('A command is running; checkpoint refused')
      return release
    } catch (error) {
      // Timeout does not prove persistence stopped. Keep commands fenced until it settles.
      void drained.then(release, release)
      throw error
    } finally { clearTimeout(timer) }
  }

  /** A cold restart ended every process in the computer. */
  async computerRestarted(): Promise<void> {
    if (this.checkpointHold) throw new AgentConflictError('Command checkpoint is in progress')
    this.pause()
    await Promise.all(this.running().map(record => this.finish(record, {
      status: 'failed', exitCode: null, signal: null, error: 'Stopped when the computer restarted.', truncated: { stdout: false, stderr: false }, outputs: [],
    })))
  }

  /** One guest command reads every running command's state; finished ones are then collected. */
  poll(): Promise<void> {
    if (this.checkpointHold) return Promise.resolve()
    if (this.polling) return this.polling
    const work = this.pollOnce().finally(() => { this.polling = undefined })
    this.polling = work
    return work
  }

  private async pollOnce(): Promise<void> {
    // A command still starting has no supervisor to find yet.
    const running = this.running().filter(record => !this.collecting.has(record.id) && !this.starting.has(record.id))
    if (!this.running().length) { this.pause(); return }
    const guest = this.hooks.guest()
    if (!guest || !running.length) return
    {
      const source = await script()
      let states: Record<string, unknown>
      try {
        states = JSON.parse(await guest.run('/usr/bin/python3', ['-c', source, 'poll', JSON.stringify({ ids: running.map(record => record.id) })], 20_000))
      } catch { return }
      if (!states || typeof states !== 'object') return
      for (const record of running) {
        const state = states[record.id]
        if (state === 'done') await this.collect(guest, source, record)
        else if (state === 'gone') await this.finish(record, { status: 'failed', exitCode: null, signal: null, error: 'The command stopped without a result.', truncated: { stdout: false, stderr: false }, outputs: [] })
      }
    }
  }

  private async collect(guest: AgentGuest, source: string, record: CommandRecord): Promise<void> {
    if (this.collecting.has(record.id)) return
    this.collecting.add(record.id)
    try {
      let outcome: GuestOutcome, stdout: { text: string; truncated: boolean }, stderr: { text: string; truncated: boolean }
      try {
        const run = (mode: string, request: object) => guest.run('/usr/bin/python3', ['-c', source, mode, JSON.stringify(request)], 30_000)
        outcome = parseGuestResult(JSON.parse(await run('result', { id: record.id })))
        stdout = decodeStream(await run('read', { id: record.id, stream: 'stdout' }))
        stderr = decodeStream(await run('read', { id: record.id, stream: 'stderr' }))
      } catch (error) {
        // A guest failure is retried on the next poll, a few times; a malformed result is final.
        const malformed = error instanceof SyntaxError || (error instanceof Error && /^(result is not|invalid)/.test(error.message))
        const failures = (this.collectFailures.get(record.id) ?? 0) + 1
        this.collectFailures.set(record.id, failures)
        if (malformed || failures >= 5) {
          await this.finish(record, { status: 'failed', exitCode: null, signal: null, error: malformed ? 'The computer reported an invalid result.' : 'The command finished, but its result could not be read.', truncated: { stdout: false, stderr: false }, outputs: [] })
        }
        return
      }
      await this.finish(record, {
        ...outcome, truncated: { stdout: outcome.truncated.stdout || stdout.truncated, stderr: outcome.truncated.stderr || stderr.truncated },
      }, { stdout: stdout.text, stderr: stderr.text })
    } finally { this.collecting.delete(record.id) }
  }

  private async finish(record: CommandRecord, outcome: GuestOutcome, streams: { stdout: string; stderr: string } = { stdout: '', stderr: '' }): Promise<void> {
    const current = this.store.get(record.id)
    if (current && current.status !== 'running') return
    this.collectFailures.delete(record.id)
    const done: CommandRecord = { ...record, ...outcome, ...streams, finishedAt: new Date(this.now()).toISOString() }
    await this.store.save(done).catch(error => console.error('Could not save a command result:', error instanceof Error ? error.message : error))
    this.leases.get(record.id)?.()
    this.leases.delete(record.id)
    const timer = this.longTimers.get(record.id)
    if (timer) clearTimeout(timer)
    this.longTimers.delete(record.id)
    const long = this.long.delete(record.id)
    const waited = this.waiting(record.id)
    for (const resolve of [...this.waiters.get(record.id) ?? []]) resolve()
    this.hooks.progress(done, 'finished', { waited, long })
    if (!this.running().length) this.pause()
    await this.store.prune()
  }
}
