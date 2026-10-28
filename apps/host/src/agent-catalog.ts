import {
  AGENTD, AgentConflictError, AgentInputError, AgentNotFoundError, AgentOperationError, AgentUnavailableError, RUNNER_MISSING, rethrowRunnerMissing,
  type AgentGuest, type AgentResolver, type SignInMethod,
} from './agents.js'
import { ownerEnv } from './display.js'
import type { HomeOwnership } from './home.js'
import { AGENT_ID, type AgentLaunch, type AgentRegistry, type RegistryAgent } from './registry.js'
import { SettingsInputError, type SettingsStore } from './settings.js'

/**
 * The agents a computer can run: the ACP registry, joined with what the guest's runner
 * (caboose-agentd) reports as installed and the sign-in methods agents announced when they
 * started. GET /v1/agents never wakes the computer; while it is parked the last known guest
 * state is shown. See docs/architecture.md § Agents.
 */
const RUNUSER = '/usr/sbin/runuser'
const GUEST_ENV = ['HOME=/home/caboose', 'PATH=/home/caboose/.local/bin:/usr/local/bin:/usr/bin:/bin']
const INSTALL_TIMEOUT_MS = 15 * 60_000
const PROBE_TIMEOUT_MS = 3 * 60_000

export interface SignInStatus { methodId: string; status: 'running' | 'succeeded' | 'failed'; message?: string; startedAt?: string; finishedAt?: string }

export interface AgentListing {
  id: string
  name: string
  version: string
  description: string
  icon: string | null
  website: string | null
  repository: string | null
  license: string | null
  distribution: AgentLaunch['distribution']
  installed: { version: string } | null
  /** The sign-in methods the agent announced, once it has been started (installed or run). */
  signIn?: SignInMethod[]
  signInStatus?: SignInStatus
  /** The variable names the owner's environment file for the agent sets; never values. */
  env?: string[]
}

export interface AgentsResponse {
  agents: AgentListing[]
  defaultAgent: string | null
  registry: { fetchedAt: string | null; error?: string }
}

interface GuestAgent {
  installed?: { version: string; spec: AgentLaunch; installedAt?: string }
  authMethods?: unknown[]
  signInStatus?: SignInStatus
  env?: string[]
}

const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/
const MAX_ENV_VALUE = 8192

/** Sign-in methods as clients see them; kinds other than "agent" and "terminal" are left out. */
export function publicSignIn(methods: unknown): SignInMethod[] {
  if (!Array.isArray(methods)) return []
  return methods.flatMap(item => {
    const method = item as Record<string, unknown> | null
    if (!method || typeof method.id !== 'string' || typeof method.name !== 'string') return []
    const type = method.type === undefined || method.type === null || method.type === 'agent' ? 'agent' : method.type === 'terminal' ? 'terminal' : undefined
    if (!type) return []
    return [{ id: method.id.slice(0, 200), name: method.name.slice(0, 200), ...(typeof method.description === 'string' && method.description ? { description: method.description.slice(0, 500) } : {}), type }]
  })
}

function readSignInStatus(value: unknown): SignInStatus | undefined {
  const status = value as Record<string, unknown> | null
  if (!status || typeof status.methodId !== 'string' || !['running', 'succeeded', 'failed'].includes(status.status as string)) return undefined
  return {
    methodId: status.methodId, status: status.status as SignInStatus['status'],
    ...(typeof status.message === 'string' ? { message: status.message.slice(0, 1000) } : {}),
    ...(typeof status.startedAt === 'string' ? { startedAt: status.startedAt } : {}),
    ...(typeof status.finishedAt === 'string' ? { finishedAt: status.finishedAt } : {}),
  }
}

/** Parses `caboose-agentd state`. */
export function parseGuestState(output: string): Record<string, GuestAgent> {
  const value = JSON.parse(output) as { agents?: Record<string, Record<string, unknown>> }
  const agents: Record<string, GuestAgent> = {}
  for (const [id, entry] of Object.entries(value.agents ?? {})) {
    if (!AGENT_ID.test(id) || !entry || typeof entry !== 'object') continue
    const installed = entry.installed as GuestAgent['installed'] | undefined
    const spec = installed?.spec
    agents[id] = {
      ...(spec && spec.id === id && typeof installed?.version === 'string' ? { installed: { version: installed.version, spec, ...(installed.installedAt ? { installedAt: installed.installedAt } : {}) } } : {}),
      ...(Array.isArray(entry.authMethods) ? { authMethods: entry.authMethods } : {}),
      ...(readSignInStatus(entry.signInStatus) ? { signInStatus: readSignInStatus(entry.signInStatus) } : {}),
      ...(Array.isArray(entry.env) ? { env: entry.env.filter((name): name is string => typeof name === 'string' && ENV_NAME.test(name)) } : {}),
    }
  }
  return agents
}

export class AgentCatalog implements AgentResolver {
  private guestAgents: Record<string, GuestAgent> = {}
  private readonly installing = new Map<string, Promise<AgentListing>>()

  constructor(
    private readonly registry: AgentRegistry,
    private readonly guest: () => AgentGuest | undefined,
    private readonly settings: SettingsStore,
    /** Gives root-owned leftovers in the home back to caboose before npm, uv or an agent runs. */
    private readonly home?: HomeOwnership,
  ) {}

  defaultAgent(): string | null { return this.settings.get().defaultAgent }

  async list(): Promise<AgentsResponse> {
    const guest = this.guest()
    if (guest) await this.refresh(guest).catch(error => console.error('Could not read the agents in the computer:', error))
    const catalog = await this.registry.catalog()
    const agents: AgentListing[] = []
    const listed = new Set<string>()
    for (const entry of catalog.agents) {
      if (!entry.launch) continue
      agents.push(this.listing(entry, entry.launch))
      listed.add(entry.id)
    }
    // An installed agent stays usable after it leaves the registry.
    for (const [id, state] of Object.entries(this.guestAgents)) {
      if (listed.has(id) || !state.installed) continue
      const spec = state.installed.spec
      agents.push(this.listing({ id, name: spec.name, version: spec.version, description: '', icon: null, website: null, repository: null, license: null }, spec))
    }
    return { agents, defaultAgent: this.defaultAgent(), registry: { fetchedAt: catalog.fetchedAt, ...(catalog.error ? { error: catalog.error } : {}) } }
  }

  private listing(entry: Omit<RegistryAgent, 'launch'>, launch: AgentLaunch): AgentListing {
    const state = this.guestAgents[entry.id]
    const signIn = state?.authMethods ? publicSignIn(state.authMethods) : undefined
    return {
      id: entry.id, name: entry.name, version: entry.version, description: entry.description, icon: entry.icon,
      website: entry.website, repository: entry.repository, license: entry.license, distribution: launch.distribution,
      installed: state?.installed ? { version: state.installed.version } : null,
      ...(signIn ? { signIn } : {}),
      ...(state?.signInStatus ? { signInStatus: state.signInStatus } : {}),
      ...(state?.env?.length ? { env: state.env } : {}),
    }
  }

  /** The launch spec for a task: the installed version when there is one, else the registry's. */
  async launch(id: string): Promise<AgentLaunch> {
    const guest = this.guest()
    if (guest) await this.refresh(guest).catch(() => {})
    const installed = this.guestAgents[id]?.installed?.spec
    if (installed) return installed
    return this.registryLaunch(id)
  }

  private async registryLaunch(id: string): Promise<AgentLaunch> {
    const catalog = await this.registry.catalog()
    const entry = catalog.agents.find(agent => agent.id === id)
    if (entry?.launch) return entry.launch
    if (entry) throw new AgentInputError(`${entry.name} has no build Caboose can run on linux-x86_64`)
    if (!catalog.agents.length && catalog.error) throw new AgentOperationError(catalog.error)
    throw new AgentNotFoundError(`"${id}" is not in the agent registry${catalog.error ? ` (${catalog.error})` : ''}`)
  }

  /** For settings: the id must be one a task could run. */
  async ensureKnown(id: unknown): Promise<void> {
    if (id === null) return
    if (typeof id !== 'string' || !AGENT_ID.test(id)) throw new SettingsInputError('defaultAgent must be an agent id from the registry, or null')
    const guest = this.guest()
    if (guest) await this.refresh(guest).catch(() => {})
    if (this.guestAgents[id]?.installed) return
    try { await this.registryLaunch(id) } catch (error) {
      throw new SettingsInputError(error instanceof Error ? error.message : String(error))
    }
  }

  /** Prefetches the registry's current version into the computer and records it as installed. */
  install(id: string): Promise<AgentListing> {
    const running = this.installing.get(id)
    if (running) return running
    const work = this.installNow(id).finally(() => this.installing.delete(id))
    this.installing.set(id, work)
    return work
  }

  private async installNow(id: string): Promise<AgentListing> {
    if (!AGENT_ID.test(id)) throw new AgentNotFoundError('agent not found')
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const catalog = await this.registry.catalog()
    const entry = catalog.agents.find(agent => agent.id === id)
    const launch = await this.registryLaunch(id)
    await this.home?.ensure(guest)
    await agentd(guest, 'install', encode(launch), INSTALL_TIMEOUT_MS).catch(error => {
      if (error instanceof AgentConflictError) throw error
      throw new AgentOperationError(`Installing ${launch.name} failed: ${guestMessage(error)}`)
    })
    await this.refresh(guest)
    if (this.defaultAgent() === null) await this.settings.update({ defaultAgent: id })
    return this.listing(entry!, launch)
  }

  /**
   * Starts sign-in method `methodId` of agent `id` on the owner's display: an "agent" method
   * opens the agent's own browser sign-in there, a "terminal" method a terminal window
   * running the agent's login. Progress appears in GET /v1/agents as `signInStatus`.
   */
  async signIn(id: string, input: Record<string, unknown>): Promise<{ started: true; method: SignInMethod }> {
    if (!AGENT_ID.test(id)) throw new AgentNotFoundError('agent not found')
    const methodId = input.methodId
    if (typeof methodId !== 'string' || !methodId || methodId.length > 200) throw new AgentInputError('methodId is required')
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const launch = await this.launch(id)
    await this.home?.ensure(guest)
    if (!this.guestAgents[id]?.authMethods) {
      // Not started yet in this computer: start it once to learn how it signs in.
      await agentd(guest, 'probe', encode(launch), PROBE_TIMEOUT_MS).catch(error => {
        if (error instanceof AgentConflictError) throw error
        throw new AgentOperationError(`${launch.name} did not start: ${guestMessage(error)}`)
      })
      await this.refresh(guest)
    }
    const method = publicSignIn(this.guestAgents[id]?.authMethods).find(item => item.id === methodId)
    if (!method) throw new AgentInputError(`${launch.name} has no sign-in method "${methodId}"`)
    await guest.run(RUNUSER, ['-u', 'caboose', '--', '/usr/bin/env', ...GUEST_ENV, '/bin/sh', '-c', SIGN_IN_SCRIPT, 'sh', AGENTD,
      encode({ agent: launch, methodId, env: envObject(ownerEnv(guest)) })], 30_000).catch(rethrowRunnerMissing)
    const state = this.guestAgents[id] ?? (this.guestAgents[id] = {})
    state.signInStatus = { methodId, status: 'running', startedAt: new Date().toISOString() }
    return { started: true, method }
  }

  /**
   * Sets and removes variables in the owner's environment file for agent `id`, for API keys
   * and the like: `{ set?: { NAME: value }, remove?: [NAME] }`. The runner writes the file
   * (mode 0600) in the computer; the host keeps nothing. Returns the names it now sets.
   */
  async setEnv(id: string, input: Record<string, unknown>): Promise<{ env: string[] }> {
    if (!AGENT_ID.test(id)) throw new AgentNotFoundError('agent not found')
    for (const key of Object.keys(input)) if (key !== 'set' && key !== 'remove') throw new AgentInputError(`Unknown field: ${key}`)
    const set = input.set ?? {}
    const remove = input.remove ?? []
    if (!set || typeof set !== 'object' || Array.isArray(set) || !Array.isArray(remove)) throw new AgentInputError('Send { set?: { NAME: value }, remove?: [NAME] }')
    for (const [name, value] of Object.entries(set)) {
      if (!ENV_NAME.test(name)) throw new AgentInputError(`${name.slice(0, 130)} is not a variable name`)
      if (typeof value !== 'string' || /[\r\n\0]/.test(value) || value.length > MAX_ENV_VALUE) throw new AgentInputError(`${name} must be one line of at most ${MAX_ENV_VALUE} characters`)
    }
    for (const name of remove) if (typeof name !== 'string' || !ENV_NAME.test(name)) throw new AgentInputError('remove must list variable names')
    if (!Object.keys(set).length && !remove.length) throw new AgentInputError('Nothing to change')
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const output = await agentd(guest, 'set-env', id, 20_000, JSON.stringify({ set, remove }))
    const env = (JSON.parse(output) as { env?: unknown }).env
    const names = Array.isArray(env) ? env.filter((name): name is string => typeof name === 'string' && ENV_NAME.test(name)) : []
    const state = this.guestAgents[id] ?? (this.guestAgents[id] = {})
    state.env = names
    return { env: names }
  }

  private async refresh(guest: AgentGuest): Promise<void> {
    this.guestAgents = parseGuestState(await agentd(guest, 'state', undefined, 20_000))
  }
}

/** Starts a sign-in detached from the guest command, as `caboose`; $1 is the runner, $2 its spec. */
const SIGN_IN_SCRIPT = [
  `[ -f "$1" ] || { echo "${RUNNER_MISSING}" >&2; exit 1; }`,
  'log="$HOME/.local/share/caboose/agents"; mkdir -p "$log"',
  'setsid node "$1" sign-in "$2" >> "$log/sign-in.log" 2>&1 < /dev/null &',
].join('\n')

/** The useful end of a failed guest command's message. */
function guestMessage(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error)
  return text.replace(/^(Guest command failed|docker exec failed):\s*/, '').trim().split('\n').slice(-3).join(' ').slice(0, 600)
}

/** `KEY=value` pairs as an object; a later pair for the same name wins, as with env(1). */
function envObject(pairs: string[]): Record<string, string> {
  return Object.fromEntries(pairs.filter(pair => pair.indexOf('=') > 0).map(pair => [pair.slice(0, pair.indexOf('=')), pair.slice(pair.indexOf('=') + 1)]))
}

function encode(value: unknown): string { return Buffer.from(JSON.stringify(value)).toString('base64') }

async function agentd(guest: AgentGuest, mode: string, argument: string | undefined, timeoutMs: number, ...more: string[]): Promise<string> {
  const script = `[ -f "$1" ] || { echo "${RUNNER_MISSING}" >&2; exit 1; }\nexec node "$@"`
  return guest.run(RUNUSER, ['-u', 'caboose', '--', '/usr/bin/env', ...GUEST_ENV, '/bin/sh', '-c', script, 'sh', AGENTD, mode, ...(argument ? [argument] : []), ...more], timeoutMs)
    .catch(rethrowRunnerMissing)
}
