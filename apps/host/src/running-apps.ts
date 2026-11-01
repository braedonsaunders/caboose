import type { AgentGuest } from './agents.js'
import { AgentInputError, AgentNotFoundError, AgentOperationError } from './agents.js'
import { ComputerConflictError } from './lifecycle.js'

/**
 * The owner's running apps: the guest's app scopes (guest/scopes, docs/architecture.md
 * § Running apps), read and ended through `caboose-scopes` as root. Everything the guest
 * answers is checked field by field; what fails is dropped.
 */

export const SCOPES = '/usr/local/bin/caboose-scopes'
export const SESSION_SCOPE = 'session.scope'
/** An app scope (`app-<systemd-escaped key>-<n>.scope`) or the session scope. */
export const RUNNING_APP_ID = /^(?:session\.scope|app-[A-Za-z0-9:_.\\]+-[0-9]{1,10}\.scope)$/
export type RunningAppAction = 'quit' | 'force-quit' | 'kill'
export const RUNNING_APP_ACTIONS: readonly RunningAppAction[] = ['quit', 'force-quit', 'kill']

const ORIGINS = ['launch', 'window', 'game', 'terminal', 'session'] as const
const STATES = ['running', 'sleeping', 'waiting', 'stopped', 'zombie', 'idle', 'other'] as const
const MAX_APPS = 512
const MAX_PROCESSES = 256

export interface RunningProcess {
  pid: number; ppid: number; name: string; command: string
  state: typeof STATES[number]; cpuPercent: number; memoryBytes: number
}
export interface RunningApp {
  id: string
  kind: 'app' | 'session'
  desktopId: string | null
  name: string
  origin: typeof ORIGINS[number]
  startedAt: number
  windows: number[]
  cpuPercent: number
  memoryBytes: number
  io: { readBytesPerSecond: number; writeBytesPerSecond: number }
  gpu: { streams: number; surfaces: number; toPhoneBytesPerSecond: number; fromPhoneBytesPerSecond: number } | null
  processCount: number
  processes: RunningProcess[]
}
export interface RunningApps {
  version: 1
  sampledAt: number
  intervalMs: number
  machine: { cpus: number; memoryBytes: number }
  apps: RunningApp[]
}

type Json = Record<string, unknown>
const object = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value)
const count = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
const measure = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value) && value >= 0
const text = (value: unknown, max: number): value is string =>
  typeof value === 'string' && value.length <= max && !/[\x00-\x1f\x7f]/.test(value)
const oneOf = <T extends string>(values: readonly T[], value: unknown): value is T => values.includes(value as T)
const DESKTOP_ID = (value: unknown): value is string => text(value, 255) && value.endsWith('.desktop') && value.length > 8 && !value.includes('/')

function parseProcess(value: unknown): RunningProcess | null {
  if (!object(value)) return null
  const { pid, ppid, name, command, state, cpuPercent, memoryBytes } = value
  if (!count(pid) || pid === 0 || !count(ppid) || !text(name, 64) || typeof command !== 'string' || command.length > 512 ||
    !oneOf(STATES, state) || !measure(cpuPercent) || !count(memoryBytes)) return null
  // A command line may hold any byte; control characters are shown as spaces.
  return { pid, ppid, name, command: command.replace(/[\x00-\x1f\x7f]/g, ' '), state, cpuPercent, memoryBytes }
}

function parseGpu(value: unknown): RunningApp['gpu'] | undefined {
  if (value === null) return null
  if (!object(value)) return undefined
  const { streams, surfaces, toPhoneBytesPerSecond, fromPhoneBytesPerSecond } = value
  if (![streams, surfaces, toPhoneBytesPerSecond, fromPhoneBytesPerSecond].every(count)) return undefined
  return { streams, surfaces, toPhoneBytesPerSecond, fromPhoneBytesPerSecond } as NonNullable<RunningApp['gpu']>
}

function parseApp(value: unknown): RunningApp | null {
  if (!object(value)) return null
  const { id, kind, desktopId, name, origin, startedAt, windows, cpuPercent, memoryBytes, io, gpu, processCount, processes } = value
  if (!text(id, 255) || !RUNNING_APP_ID.test(id)) return null
  const expected = id === SESSION_SCOPE ? 'session' : 'app'
  if (kind !== expected) return null
  if (desktopId !== null && !DESKTOP_ID(desktopId)) return null
  if (!text(name, 200) || !name || !oneOf(ORIGINS, origin) || !count(startedAt)) return null
  if (!Array.isArray(windows) || windows.length > 1024 || !windows.every(count)) return null
  if (!measure(cpuPercent) || !count(memoryBytes) || !count(processCount)) return null
  if (!object(io) || !count(io.readBytesPerSecond) || !count(io.writeBytesPerSecond)) return null
  const parsedGpu = parseGpu(gpu)
  if (parsedGpu === undefined || !Array.isArray(processes)) return null
  const parsed = processes.slice(0, MAX_PROCESSES).map(parseProcess).filter((p): p is RunningProcess => p !== null)
  return {
    id, kind: expected, desktopId, name, origin, startedAt, windows: [...new Set(windows)], cpuPercent, memoryBytes,
    io: { readBytesPerSecond: io.readBytesPerSecond, writeBytesPerSecond: io.writeBytesPerSecond },
    gpu: parsedGpu, processCount: Math.max(processCount, parsed.length), processes: parsed,
  }
}

/** The guest's listing, checked; throws when its envelope is not a version 1 listing. */
export function parseRunningApps(value: unknown): RunningApps {
  if (!object(value) || value.version !== 1) throw new AgentOperationError('The computer answered an unknown running-apps listing')
  const { sampledAt, intervalMs, machine, apps } = value
  if (!count(sampledAt) || !count(intervalMs) || !object(machine) || !count(machine.cpus) || !count(machine.memoryBytes) || !Array.isArray(apps)) {
    throw new AgentOperationError('The computer answered an invalid running-apps listing')
  }
  const seen = new Set<string>()
  const parsed = apps.slice(0, MAX_APPS).map(parseApp).filter((app): app is RunningApp => {
    if (!app || seen.has(app.id)) return false
    seen.add(app.id)
    return true
  })
  return { version: 1, sampledAt, intervalMs, machine: { cpus: machine.cpus, memoryBytes: machine.memoryBytes }, apps: parsed }
}

/** An app id from a route (already percent-decoded). */
export function parseRunningAppId(id: string): string {
  if (!RUNNING_APP_ID.test(id) || id.length > 255) throw new AgentInputError('Invalid running app id')
  return id
}

/** caboose-scopes answers `{ ok: true, result }` or `{ ok: false, error, message }`. */
function unwrap(stdout: string): unknown {
  let answer: unknown
  try { answer = JSON.parse(stdout) } catch { throw new AgentOperationError('The computer gave no running-apps answer') }
  if (!object(answer)) throw new AgentOperationError('The computer gave no running-apps answer')
  if (answer.ok === true) return answer.result
  const message = text(answer.message, 300) && answer.message ? answer.message : 'The request failed'
  switch (answer.error) {
    case 'unknown': case 'gone': throw new AgentNotFoundError('No such running app')
    case 'invalid': throw new AgentInputError(message)
    case 'forbidden': throw new ComputerConflictError("Caboose's own processes cannot be quit")
    case 'no-windows': throw new ComputerConflictError('The app has no windows to close')
    case 'unavailable': throw new ComputerConflictError('The computer is not tracking running apps yet')
    default: throw new AgentOperationError(`The computer could not do that: ${message}`)
  }
}

export async function listRunningApps(guest: AgentGuest): Promise<RunningApps> {
  return parseRunningApps(unwrap(await guest.run(SCOPES, ['list'], 15_000)))
}

/** Quit, Force Quit or Kill one app. Force Quit waits up to 5 s for the app before killing it. */
export async function endRunningApp(guest: AgentGuest, id: string, action: RunningAppAction): Promise<{ closed: number } | { ended: boolean; killed: boolean }> {
  parseRunningAppId(id)
  if (id === SESSION_SCOPE) throw new ComputerConflictError("Caboose's own processes cannot be quit")
  const result = unwrap(await guest.run(SCOPES, [action, id], 20_000))
  if (action === 'quit') {
    if (!object(result) || !count(result.closed)) throw new AgentOperationError('The computer gave an invalid answer')
    return { closed: result.closed }
  }
  if (!object(result) || typeof result.ended !== 'boolean' || typeof result.killed !== 'boolean') throw new AgentOperationError('The computer gave an invalid answer')
  return { ended: result.ended, killed: result.killed }
}
