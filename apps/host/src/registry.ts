import { readJsonFile, writePrivateJson } from './settings.js'

/**
 * The Agent Client Protocol registry: which agents exist and how to start each one. Caboose
 * runs agents inside a Debian amd64 computer, so each entry is resolved for linux-x86_64.
 * The registry is fetched, cached with its ETag (in memory and on disk), and when a fetch
 * fails the last good copy is served with the error. There is no built-in list.
 * See https://github.com/agentclientprotocol/registry (FORMAT.md).
 */
export const REGISTRY_URL = 'https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json'
export const PLATFORM = 'linux-x86_64'
const DEFAULT_TTL_MS = 60 * 60_000
const RETRY_MS = 60_000
const FETCH_TIMEOUT_MS = 15_000

export const AGENT_ID = /^[a-z0-9][a-z0-9._-]{0,63}$/
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/
const VERSION = /^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$/

/** How the runner in the guest starts an agent: the registry's distribution for linux-x86_64. */
export interface AgentLaunch {
  id: string
  name: string
  version: string
  distribution: 'npx' | 'uvx' | 'binary'
  /** npx and uvx: the package, with its version. */
  package?: string
  /** binary: the archive URL, its SHA-256 when the registry gives one, and the command inside it. */
  archive?: string
  sha256?: string
  cmd?: string
  args: string[]
  env: Record<string, string>
}

export interface RegistryAgent {
  id: string
  name: string
  version: string
  description: string
  icon: string | null
  website: string | null
  repository: string | null
  license: string | null
  /** Undefined when the agent has no distribution Caboose can run on linux-x86_64. */
  launch?: AgentLaunch
}

export interface Catalog {
  agents: RegistryAgent[]
  /** When the registry was last fetched or confirmed unchanged; null before any success. */
  fetchedAt: string | null
  /** Why the last fetch failed; the agents are then the last good copy. */
  error?: string
}

function text(value: unknown, max: number): string | null {
  return typeof value === 'string' && value.trim() ? value.trim().slice(0, max) : null
}

function webUrl(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > 2048) return null
  try {
    const url = new URL(value)
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : null
  } catch { return null }
}

function stringList(value: unknown): string[] | undefined {
  if (value === undefined || value === null) return []
  return Array.isArray(value) && value.every(item => typeof item === 'string') ? value : undefined
}

function envMap(value: unknown): Record<string, string> | undefined {
  if (value === undefined || value === null) return {}
  if (typeof value !== 'object' || Array.isArray(value)) return undefined
  const entries = Object.entries(value as Record<string, unknown>)
  return entries.every(([key, item]) => ENV_NAME.test(key) && typeof item === 'string') ? Object.fromEntries(entries) as Record<string, string> : undefined
}

function packageSpec(value: unknown): string | undefined {
  return typeof value === 'string' && value && value.length <= 214 && !/\s/.test(value) && !value.startsWith('-') ? value : undefined
}

/**
 * The way to start `entry` on `platform`, preferring a binary the registry pins by SHA-256,
 * then npx, then uvx, then a binary without a checksum (downloaded over HTTPS only).
 */
export function resolveLaunch(entry: { id: string; name: string; version: string; distribution?: unknown }, platform = PLATFORM): AgentLaunch | undefined {
  const distribution = entry.distribution && typeof entry.distribution === 'object' ? entry.distribution as Record<string, unknown> : {}
  const base = { id: entry.id, name: entry.name, version: entry.version }
  const binaries = distribution.binary && typeof distribution.binary === 'object' ? distribution.binary as Record<string, unknown> : {}
  const target = binaries[platform] && typeof binaries[platform] === 'object' ? binaries[platform] as Record<string, unknown> : undefined
  let binary: AgentLaunch | undefined
  if (target) {
    const archive = webUrl(target.archive)
    const sha256 = typeof target.sha256 === 'string' && /^[0-9a-fA-F]{64}$/.test(target.sha256) ? target.sha256.toLowerCase() : undefined
    const cmd = typeof target.cmd === 'string' && target.cmd && !target.cmd.startsWith('/') && !target.cmd.split(/[\\/]/).includes('..') ? target.cmd : undefined
    const args = stringList(target.args)
    const env = envMap(target.env)
    if (archive?.startsWith('https:') && cmd && args && env) binary = { ...base, distribution: 'binary', archive, ...(sha256 ? { sha256 } : {}), cmd, args, env }
  }
  if (binary?.sha256) return binary
  for (const kind of ['npx', 'uvx'] as const) {
    const value = distribution[kind] && typeof distribution[kind] === 'object' ? distribution[kind] as Record<string, unknown> : undefined
    if (!value) continue
    const spec = packageSpec(value.package)
    const args = stringList(value.args)
    const env = envMap(value.env)
    if (spec && args && env) return { ...base, distribution: kind, package: spec, args, env }
  }
  return binary
}

/** Reads registry.json; entries without an id, name or version Caboose can use are left out. */
export function parseRegistry(value: unknown, platform = PLATFORM): RegistryAgent[] {
  const agents = value && typeof value === 'object' ? (value as { agents?: unknown }).agents : undefined
  if (!Array.isArray(agents)) throw new Error('registry.json has no agents list')
  const seen = new Set<string>()
  return agents.flatMap((item): RegistryAgent[] => {
    if (!item || typeof item !== 'object') return []
    const entry = item as Record<string, unknown>
    const id = typeof entry.id === 'string' && AGENT_ID.test(entry.id) ? entry.id : undefined
    const name = text(entry.name, 100)
    const version = typeof entry.version === 'string' && VERSION.test(entry.version) ? entry.version : undefined
    if (!id || !name || !version || seen.has(id)) return []
    seen.add(id)
    const launch = resolveLaunch({ id, name, version, distribution: entry.distribution }, platform)
    return [{
      id, name, version,
      description: text(entry.description, 500) ?? '',
      icon: webUrl(entry.icon),
      website: webUrl(entry.website),
      repository: webUrl(entry.repository),
      license: text(entry.license, 100),
      ...(launch ? { launch } : {}),
    }]
  })
}

interface CacheFile { etag: string | null; fetchedAt: string; registry: unknown }

export interface RegistryOptions {
  url?: string
  ttlMs?: number
  /** Where the last good copy is kept across host restarts. */
  cachePath?: string
  fetch?: typeof fetch
  now?: () => number
}

export class AgentRegistry {
  private agents: RegistryAgent[] | undefined
  private etag: string | null = null
  private fetchedAt: string | null = null
  private error: string | undefined
  private checkedAt = 0
  private inFlight: Promise<void> | undefined
  private loaded = false
  private readonly url: string
  private readonly ttlMs: number
  private readonly fetcher: typeof fetch
  private readonly now: () => number

  constructor(private readonly options: RegistryOptions = {}) {
    this.url = options.url ?? REGISTRY_URL
    this.ttlMs = options.ttlMs ?? DEFAULT_TTL_MS
    this.fetcher = options.fetch ?? ((input, init) => globalThis.fetch(input, init))
    this.now = options.now ?? Date.now
  }

  /** The registry, refreshed when older than the TTL (or after a failure, a minute later). */
  async catalog(): Promise<Catalog> {
    await this.loadCache()
    const age = this.now() - this.checkedAt
    if (!this.agents || age >= (this.error ? RETRY_MS : this.ttlMs)) await this.refresh()
    return { agents: this.agents ?? [], fetchedAt: this.fetchedAt, ...(this.error ? { error: this.error } : {}) }
  }

  async get(id: string): Promise<RegistryAgent | undefined> {
    return (await this.catalog()).agents.find(agent => agent.id === id)
  }

  private async loadCache(): Promise<void> {
    if (this.loaded) return
    this.loaded = true
    if (!this.options.cachePath) return
    try {
      const cached = await readJsonFile(this.options.cachePath) as CacheFile | undefined
      if (!cached) return
      this.agents = parseRegistry(cached.registry)
      this.etag = typeof cached.etag === 'string' ? cached.etag : null
      this.fetchedAt = typeof cached.fetchedAt === 'string' ? cached.fetchedAt : null
    } catch (error) {
      console.error('Ignoring the cached agent registry:', error)
    }
  }

  private refresh(): Promise<void> {
    this.inFlight ??= this.fetchRegistry().finally(() => { this.inFlight = undefined })
    return this.inFlight
  }

  private async fetchRegistry(): Promise<void> {
    try {
      const headers: Record<string, string> = { accept: 'application/json' }
      if (this.etag && this.agents) headers['if-none-match'] = this.etag
      const response = await this.fetcher(this.url, { headers, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) })
      const at = new Date(this.now()).toISOString()
      if (response.status === 304 && this.agents) {
        this.fetchedAt = at
      } else {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        const body = await response.json() as unknown
        this.agents = parseRegistry(body)
        this.etag = response.headers.get('etag')
        this.fetchedAt = at
        if (this.options.cachePath) await writePrivateJson(this.options.cachePath, { etag: this.etag, fetchedAt: at, registry: body } satisfies CacheFile).catch(error => console.error('Could not cache the agent registry:', error))
      }
      this.error = undefined
    } catch (error) {
      this.error = `The agent registry could not be fetched: ${error instanceof Error ? error.message : String(error)}`
    } finally {
      this.checkedAt = this.now()
    }
  }
}
