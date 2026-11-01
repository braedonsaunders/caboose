import { readFile, rename, writeFile } from 'node:fs/promises'
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

const ORIGINS = ['launch', 'window', 'game', 'terminal', 'agent', 'session'] as const
const STATES = ['running', 'sleeping', 'waiting', 'stopped', 'zombie', 'idle', 'other'] as const
const MAX_APPS = 512
const MAX_PROCESSES = 256

export interface RunningProcess {
  pid: number; ppid: number; name: string; command: string
  state: typeof STATES[number]; cpuPercent: number; memoryBytes: number
}
export interface ListeningPort { protocol: 'tcp' | 'udp'; address: string; port: number }
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
  ports: ListeningPort[]
}
export const SERVICE_STATES = ['inactive', 'activating', 'active', 'deactivating', 'failed'] as const
export const SERVICE_ACTIONS = ['start', 'stop', 'restart', 'enable', 'disable'] as const
export type ServiceAction = typeof SERVICE_ACTIONS[number]
/** A service's name: what its unit file is called, without `.service`. */
export const SERVICE_NAME = /^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$/
export interface ServiceStatus {
  id: string; name: string; description: string; source: 'system' | 'owner'
  state: typeof SERVICE_STATES[number]; error: string | null
  autostart: boolean; restart: 'no' | 'on-failure' | 'always'; requires: string[]
  since: number; restarts: number; lastExit: { code: number | null; signal: number | null; at: number } | null
}
export interface RunningService extends ServiceStatus {
  cpuPercent: number; memoryBytes: number
  io: RunningApp['io']; gpu: RunningApp['gpu']
  processCount: number; processes: RunningProcess[]; ports: ListeningPort[]
}
export interface RunningApps {
  version: 1
  sampledAt: number
  intervalMs: number
  machine: { cpus: number; memoryBytes: number }
  apps: RunningApp[]
  services: RunningService[]
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

function parsePorts(value: unknown): ListeningPort[] {
  if (value === undefined) return []
  if (!Array.isArray(value)) return []
  return value.slice(0, 256).flatMap(port => {
    if (!object(port) || !oneOf(['tcp', 'udp'] as const, port.protocol) || !text(port.address, 64) || !/^[0-9a-f.:]+$/i.test(port.address) ||
      !count(port.port) || port.port > 65535) return []
    return [{ protocol: port.protocol, address: port.address, port: port.port }]
  })
}

function parseStatus(value: unknown): ServiceStatus | null {
  if (!object(value)) return null
  const { id, name, description, source, state, error, autostart, restart, requires, since, restarts, lastExit } = value
  if (!text(name, 64) || !SERVICE_NAME.test(name) || id !== `${name}.service`) return null
  if (!text(description, 200) || !oneOf(['system', 'owner'] as const, source) || !oneOf(SERVICE_STATES, state)) return null
  if (error !== null && !(typeof error === 'string' && error.length <= 500)) return null
  if (typeof autostart !== 'boolean' || !oneOf(['no', 'on-failure', 'always'] as const, restart)) return null
  if (!Array.isArray(requires) || requires.length > 64 || !requires.every(r => typeof r === 'string' && SERVICE_NAME.test(r))) return null
  if (!count(since) || !count(restarts)) return null
  let exit: ServiceStatus['lastExit'] = null
  if (lastExit !== null) {
    if (!object(lastExit) || !count(lastExit.at)) return null
    const code = lastExit.code === null ? null : count(lastExit.code) && lastExit.code < 256 ? lastExit.code : undefined
    const sig = lastExit.signal === null ? null : count(lastExit.signal) && lastExit.signal < 128 ? lastExit.signal : undefined
    if (code === undefined || sig === undefined) return null
    exit = { code, signal: sig, at: lastExit.at }
  }
  return { id, name, description, source, state, error: error === null ? null : error.replace(/[\x00-\x1f\x7f]/g, ' '), autostart, restart,
    requires: requires as string[], since, restarts, lastExit: exit }
}

function parseService(value: unknown): RunningService | null {
  const status = parseStatus(value)
  if (!status || !object(value)) return null
  const { cpuPercent, memoryBytes, io, gpu, processCount, processes } = value
  if (!measure(cpuPercent) || !count(memoryBytes) || !count(processCount)) return null
  if (!object(io) || !count(io.readBytesPerSecond) || !count(io.writeBytesPerSecond)) return null
  const parsedGpu = parseGpu(gpu)
  if (parsedGpu === undefined || !Array.isArray(processes)) return null
  const parsed = processes.slice(0, MAX_PROCESSES).map(parseProcess).filter((p): p is RunningProcess => p !== null)
  return { ...status, cpuPercent, memoryBytes, io: { readBytesPerSecond: io.readBytesPerSecond, writeBytesPerSecond: io.writeBytesPerSecond },
    gpu: parsedGpu, processCount: Math.max(processCount, parsed.length), processes: parsed, ports: parsePorts(value.ports) }
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
    gpu: parsedGpu, processCount: Math.max(processCount, parsed.length), processes: parsed, ports: parsePorts(value.ports),
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
  const names = new Set<string>()
  const services = (Array.isArray(value.services) ? value.services : []).slice(0, 256).map(parseService).filter((service): service is RunningService => {
    if (!service || names.has(service.name)) return false
    names.add(service.name)
    return true
  })
  return { version: 1, sampledAt, intervalMs, machine: { cpus: machine.cpus, memoryBytes: machine.memoryBytes }, apps: parsed, services }
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
    case 'forbidden': throw new ComputerConflictError(message)
    case 'no-windows': throw new ComputerConflictError('The app has no windows to close')
    case 'unavailable': throw new ComputerConflictError('The computer is not tracking running apps yet')
    case 'service-forbidden': throw new ComputerConflictError(message)
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

/** A service name from a route (already percent-decoded). */
export function parseServiceName(name: string): string {
  if (!SERVICE_NAME.test(name) || name.endsWith('.service')) throw new AgentInputError('Invalid service name')
  return name
}

/** Start, stop, restart, enable (autostart) or disable a service → its status. Stop waits for it. */
export async function serviceAction(guest: AgentGuest, name: string, action: ServiceAction): Promise<ServiceStatus> {
  parseServiceName(name)
  if (!SERVICE_ACTIONS.includes(action)) throw new AgentInputError('Unknown service action')
  return checkedStatus(unwrap(await guest.run(SCOPES, ['service', action, name], 90_000)))
}

function checkedStatus(value: unknown): ServiceStatus {
  const status = parseStatus(value)
  if (!status) throw new AgentOperationError('The computer gave an invalid service status')
  return status
}

/**
 * The owner's service definition (docs/architecture.md § Services): checked here for shape,
 * and in full by the guest, which writes the unit file.
 */
export function parseServiceDefinition(body: Record<string, unknown>): Record<string, unknown> {
  const known = ['description', 'command', 'workingDirectory', 'environment', 'restart', 'autostart', 'requires']
  for (const key of Object.keys(body)) if (!known.includes(key)) throw new AgentInputError(`Unknown field ${key}`)
  const { command } = body
  if (!Array.isArray(command) || command.length < 1 || command.length > 256 || !command.every(a => typeof a === 'string' && a.length > 0 && a.length <= 4096 && !/[\x00\n]/.test(a))) {
    throw new AgentInputError('command must be a list of 1 to 256 arguments')
  }
  return body
}

export async function putService(guest: AgentGuest, name: string, definition: Record<string, unknown>): Promise<ServiceStatus> {
  parseServiceName(name)
  return checkedStatus(unwrap(await guest.run(SCOPES, ['service-put', name, JSON.stringify(parseServiceDefinition(definition))], 30_000)))
}

export async function deleteService(guest: AgentGuest, name: string): Promise<{ removed: true }> {
  parseServiceName(name)
  const result = unwrap(await guest.run(SCOPES, ['service-delete', name], 90_000))
  if (!object(result) || result.removed !== true) throw new AgentOperationError('The computer gave an invalid answer')
  return { removed: true }
}

/** The last `lines` (1 to 2000) lines of a service's log. */
export async function serviceLogs(guest: AgentGuest, name: string, lines: number): Promise<{ lines: string[] }> {
  parseServiceName(name)
  if (!Number.isSafeInteger(lines) || lines < 1 || lines > 2000) throw new AgentInputError('lines must be 1 to 2000')
  const result = unwrap(await guest.run(SCOPES, ['logs', name, String(lines)], 15_000))
  if (!object(result) || !Array.isArray(result.lines)) throw new AgentOperationError('The computer gave an invalid answer')
  return { lines: result.lines.filter((l): l is string => typeof l === 'string').slice(-lines).map(l => l.slice(0, 4096).replace(/[\x00-\x08\x0b-\x1f\x7f]/g, '')) }
}

export interface ActiveListener extends ListeningPort {
  pid: number | null
  /** The service (`name.service`) or app scope that owns the socket; `caboose` for Caboose's own processes. */
  owner: string
  /** ESTABLISHED connections to it from a non-loopback peer now (TCP; 0 for UDP). */
  established: number
  /** Unix ms the guest last saw such a connection, or null. */
  lastActiveAt: number | null
}
export interface GuestActivity {
  services: { active: number; autostart: number; failed: number }
  listening: ActiveListener[]
}

/** What the guest is serving, for the host's park decision: services and listening ports. */
export async function readActivity(guest: AgentGuest): Promise<GuestActivity> {
  const result = unwrap(await guest.run(SCOPES, ['activity'], 30_000))
  if (!object(result) || !object(result.services) || !Array.isArray(result.listening)) throw new AgentOperationError('The computer gave an invalid activity answer')
  const { active, autostart, failed } = result.services
  if (!count(active) || !count(autostart) || !count(failed)) throw new AgentOperationError('The computer gave an invalid activity answer')
  const listening = result.listening.slice(0, 1024).flatMap((entry): ActiveListener[] => {
    if (!object(entry)) return []
    const [port] = parsePorts([entry])
    if (!port) return []
    const { pid, owner, established, lastActiveAt } = entry
    if (!(pid === null || (count(pid) && pid > 0)) || !text(owner, 255) || !owner || !count(established) || !(lastActiveAt === null || count(lastActiveAt))) return []
    return [{ ...port, pid: pid as number | null, owner, established, lastActiveAt: lastActiveAt as number | null }]
  })
  return { services: { active, autostart, failed }, listening }
}

/**
 * Whether the computer has services that start with it, remembered by the host across its
 * own restarts (`services.json` in the computer's state), so the host can start such a
 * computer when it starts. Updated whenever the host reads the guest's services.
 */
export class ServiceMemory {
  private value = false
  private constructor(private readonly path: string | undefined) {}

  static async open(path?: string): Promise<ServiceMemory> {
    const memory = new ServiceMemory(path)
    if (path) {
      try {
        const saved: unknown = JSON.parse(await readFile(path, 'utf8'))
        memory.value = object(saved) && saved.autostart === true
      } catch { /* none yet */ }
    }
    return memory
  }

  autostart(): boolean { return this.value }

  async record(autostart: boolean): Promise<void> {
    if (autostart === this.value) return
    this.value = autostart
    if (!this.path) return
    const temporary = `${this.path}.tmp`
    await writeFile(temporary, JSON.stringify({ autostart }), { mode: 0o600 })
    await rename(temporary, this.path)
  }
}
