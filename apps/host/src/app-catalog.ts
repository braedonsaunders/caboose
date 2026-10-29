import { randomUUID } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { existsSync, readFileSync } from 'node:fs'
import { AgentConflictError, AgentInputError, AgentNotFoundError, AgentUnavailableError, type AgentGuest } from './agents.js'
import { loadCatalog, type CatalogData, type CatalogEntry } from './app-catalog-data.js'
import { APP_ID, CATEGORIES, type FlathubApp, type FlathubIndex } from './flathub.js'
import type { CraftReleases } from './releases.js'
import type { RuntimeDepot } from './depot.js'

type Operation = 'install' | 'update' | 'remove'
type Progress = { id: string; operation: Operation; phase: 'queued' | 'installing' | 'finished' | 'failed'; message?: string; stage?: string; value?: number | null; downloadedBytes?: number; totalBytes?: number }
type State = { installedVersion: string | null; lastError: string | null; interrupted: boolean; active: boolean; operationId: string | null; progress: Progress | null }
/** Library metadata beyond the repository catalog's fields. */
type Entry = CatalogEntry & { origin: 'caboose' | 'flathub' | 'debian'; curated: boolean; categories: string[]; developer: string | null; verified: boolean; license: string | null; installs: number | null; storeComponent?: string }
type Installed = { version: string; name: string; summary: string; runtime: string | null }
const EMPTY: State = { installedVersion: null, lastError: null, interrupted: false, active: false, operationId: null, progress: null }
const OPERATIONS = ['install', 'update', 'remove']
const STAGES = ['preparing', 'downloading', 'verifying', 'refreshing', 'installing', 'configuring', 'removing', 'finished']
const PAGE = 40
const UPDATE_MS = 24 * 3600_000
const RUNTIME = /^[A-Za-z_][A-Za-z0-9_.-]{0,254}\/(x86_64|aarch64)\/[A-Za-z0-9_.-]{1,64}$/
const bounded = (value: unknown) => typeof value === 'string' ? value.slice(-1000) : undefined
const object = (value: unknown): Record<string, unknown> => value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
function parseProgress(id: string, value: unknown): Progress | null {
  const raw = object(value)
  if (typeof raw.operation !== 'string' || !OPERATIONS.includes(raw.operation) || typeof raw.phase !== 'string' || !['queued', 'installing', 'finished', 'failed'].includes(raw.phase)) return null
  const result: Progress = { id, operation: raw.operation as Operation, phase: raw.phase as Progress['phase'], value: null }
  if (typeof raw.stage === 'string' && STAGES.includes(raw.stage)) result.stage = raw.stage
  if (bounded(raw.message)) result.message = bounded(raw.message)
  // A fraction describes only bytes received, never estimated overall installation work.
  if (result.phase === 'installing' && result.stage === 'downloading' && Number.isSafeInteger(raw.downloadedBytes) && Number.isSafeInteger(raw.totalBytes) && (raw.downloadedBytes as number) >= 0 && (raw.totalBytes as number) > 0) {
    result.downloadedBytes = raw.downloadedBytes as number
    result.totalBytes = raw.totalBytes as number
    result.value = Math.min(1, result.downloadedBytes / result.totalBytes)
  }
  return result
}
function parseState(id: string, value: unknown): State {
  const state = object(value)
  return { installedVersion: bounded(state.installedVersion) ?? null, lastError: bounded(state.lastError) ?? null,
    interrupted: state.active !== true && state.interrupted === true, active: state.active === true, operationId: bounded(state.operationId) ?? null,
    progress: parseProgress(id, state.progress) }
}
function parseInstalled(value: unknown): Installed | null {
  const raw = object(value)
  if (typeof raw.version !== 'string' || !raw.version || raw.version.length > 100) return null
  return { version: raw.version, name: typeof raw.name === 'string' ? raw.name.slice(0, 160) : '', summary: typeof raw.summary === 'string' ? raw.summary.slice(0, 500) : '',
    runtime: typeof raw.runtime === 'string' && RUNTIME.test(raw.runtime) ? raw.runtime : null }
}
/** Whether `latest` is a newer release than the installed Debian version (which may carry a revision). */
export function newer(latest: string, installed: string): boolean {
  const a = latest.split('.').map(Number), b = installed.split(/[-+~]/)[0]!.split('.').map(Number)
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0, y = b[i] ?? 0
    if (Number.isNaN(y)) return false
    if (x !== y) return x > y
  }
  return false
}
const pause = () => new Promise<void>(resolve => { const timer = setTimeout(resolve, 2000); timer.unref() })
const ICONS = new URL('../../../guest/catalog/icons/', import.meta.url)

/** The app's icon from guest/catalog/icons as a PNG data URL, so clients can show apps that are not installed. */
export function catalogIcon(id: string): string | null {
  const file = new URL(`${id}.png`, ICONS)
  return existsSync(file) ? 'data:image/png;base64,' + readFileSync(file).toString('base64') : null
}

/** A Flathub application as a Library entry. */
export function flathubEntry(app: FlathubApp): Entry {
  return { id: `flathub-${app.appId}`, name: app.name, summary: app.summary, category: app.categories[0] ?? 'Utilities', categories: app.categories, packs: [], icon: '', desktopId: `${app.appId}.desktop`,
    fileTypes: { extensions: [], utTypes: [] }, source: { kind: 'flatpak', appId: app.appId, runtime: app.runtime }, origin: 'flathub', curated: false,
    developer: app.developer, verified: app.verified, license: app.license, installs: app.installs }
}

function words(value: string): string[] { return value.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean) }

export interface CatalogOptions {
  data?: CatalogData
  flathub?: FlathubIndex
  releases?: CraftReleases
  depot?: RuntimeDepot
  /** This computer, as the depot records which runtimes each computer uses. */
  computer?: string
  now?: () => number
}

/**
 * The Library: Caboose's curated catalog first, then Flathub. Operations are serialized and
 * execute entirely inside the guest as root; a Flatpak's runtime is first added to the host's
 * shared depot. Installed apps update automatically.
 */
export class AppCatalog {
  private readonly data: CatalogData
  private readonly curated: Entry[]
  private readonly flathub: FlathubIndex | undefined
  private readonly releases: CraftReleases | undefined
  private readonly depot: RuntimeDepot | undefined
  private readonly computer: string
  private readonly now: () => number
  private states: Record<string, State> = {}
  private progress = new Map<string, Progress>()
  private store = new Map<string, Entry>()
  /** Flathub apps this computer has installed or operated on, as last observed. */
  private flatpaks = new Map<string, Entry>()
  private environment = { flatpak: false, depot: false }
  private updates = new Set<string>()
  private updatedAt = -Infinity
  private restored = false
  private restoring: Promise<void> | undefined
  private working = false
  private observing = false
  constructor(private readonly guest: () => AgentGuest | undefined, private readonly emit: (event: unknown) => void, private readonly lease: () => () => void, options: CatalogOptions | CatalogData = {}) {
    const settings: CatalogOptions = 'apps' in options ? { data: options } : options
    this.data = settings.data ?? loadCatalog()
    this.curated = this.data.apps.map(app => ({ ...app, origin: 'caboose', curated: true, categories: [app.category], developer: null, verified: false, license: null, installs: null }))
    this.flathub = settings.flathub
    this.releases = settings.releases
    this.depot = settings.depot
    this.computer = settings.computer ?? 'owner'
    this.now = settings.now ?? Date.now
  }
  get busy(): boolean { return this.working || this.observing || Object.values(this.states).some(state => state.active) }
  private async invoke(action: string, argument: unknown, timeout = 30_000): Promise<string> {
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const script = await readFile(new URL('./guest-catalog.py', import.meta.url), 'utf8')
    return guest.run('/usr/bin/python3', ['-c', script, action, JSON.stringify(argument)], timeout)
  }
  /** Debian apps the Library discovered before Flathub replaced Debian discovery; they stay manageable. */
  private async loadStore() {
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const script = await readFile(new URL('./guest-store.py', import.meta.url), 'utf8')
    const output = await guest.run('/usr/bin/python3', ['-c', script, JSON.stringify({ restore: true })], 60_000)
    if (output.length > 600_000) throw new Error('AppStream results too large')
    const raw: unknown = JSON.parse(output)
    if (!Array.isArray(raw) || raw.length > 300) throw new Error('Invalid AppStream results')
    for (const value of raw) {
      const v = object(value)
      if (typeof v.package !== 'string' || !/^[a-z0-9][a-z0-9+.-]{0,99}$/.test(v.package) || v.id !== `debian-${v.package}` || typeof v.desktopId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}\.desktop$/.test(v.desktopId) || typeof v.name !== 'string' || !v.name || v.name.length > 160 || typeof v.summary !== 'string' || !v.summary || v.summary.length > 500 || typeof v.license !== 'string' || v.license.length > 200 || typeof v.componentId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}$/.test(v.componentId)) continue
      if (this.data.apps.some(app => app.source.kind === 'apt' && app.source.packages.includes(v.package as string))) continue
      this.store.set(v.id as string, { id: v.id as string, name: v.name, summary: v.summary, category: 'Utilities', categories: ['Utilities'], origin: 'debian', curated: false, developer: null, verified: false, license: v.license || null, installs: null,
        storeComponent: v.componentId, packs: [], icon: '', desktopId: v.desktopId, fileTypes: { extensions: [], utTypes: [] }, source: { kind: 'apt', packages: [v.package] } })
    }
  }
  /** Loads Flathub's index, so an app found by an earlier search can be operated on after a restart. */
  async ready(): Promise<void> { await this.flathub?.ready().catch(error => console.error('Flathub index unavailable:', error)) }
  async restore() {
    if (!this.guest()) { this.restored = false; return }
    if (!this.restored) {
      this.restoring ??= this.loadStore().then(() => { this.restored = true }).finally(() => { this.restoring = undefined })
      await this.restoring
    }
  }
  /** One ranked list: curated matches in catalog order, then Flathub by popularity or relevance. */
  async discover(query: string, category = '', offset = 0, collection = '') {
    if (typeof query !== 'string' || query.length > 100 || /[\x00-\x1f]/.test(query)) throw new AgentInputError('Invalid search')
    if (category && !(CATEGORIES as readonly string[]).includes(category)) throw new AgentInputError('Unknown category')
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > 100_000) throw new AgentInputError('Invalid offset')
    // A collection is a way to browse, never to install: its apps, then its category's.
    const pack = collection ? this.data.packs.find(item => item.id === collection) : undefined
    if (collection && !pack) throw new AgentNotFoundError('Collection not found')
    if (pack && category) throw new AgentInputError('Choose a collection or a category, not both')
    let error: string | null = null
    if (this.flathub) await this.flathub.ready().catch(cause => { error = `Flathub could not be reached: ${cause instanceof Error ? cause.message : String(cause)}` })
    const terms = words(query)
    const curated = this.curated.filter(app => (pack ? app.packs.includes(pack.id) : !category || app.category === category) && terms.every(term => words(`${app.name} ${app.summary} ${app.id} ${app.category}`).some(word => word.startsWith(term))))
    const aliases = new Set(this.curated.flatMap(app => app.flathub ? [app.flathub] : []))
    const flathub = this.flathub?.size && (!pack || pack.category) ? this.flathub.search(query, pack?.category ?? category, aliases) : []
    const total = curated.length + flathub.length
    const slice = [...curated.slice(offset, offset + PAGE), ...flathub.slice(Math.max(0, offset - curated.length), Math.max(0, offset + PAGE - curated.length)).map(flathubEntry)]
    return { apps: await Promise.all(slice.map(app => this.view(this.flatpaks.get(app.id) ?? app))), total, offset, limit: PAGE, categories: [...CATEGORIES], error }
  }
  private async view(app: Entry) {
    const { operationId: _operationId, ...state } = this.states[app.id] ?? EMPTY
    const release = app.source.kind === 'release' ? this.releases?.known(app.id) ?? null : null
    const installedVersion = state.installedVersion
    const iconData = app.origin === 'flathub' && app.source.kind === 'flatpak' ? await this.flathub?.icon(app.source.appId) ?? null : catalogIcon(app.id)
    const { icon: _icon, flathub: _alias, ...entry } = app
    const source = app.source.kind === 'flatpak' ? { kind: 'flatpak' as const } : app.source.kind === 'release' ? { kind: 'release' as const, ...(release ? { size: release.size } : {}) } : app.source
    return { ...entry, source, ...state, iconData, latestVersion: release?.version ?? null,
      updateAvailable: release && installedVersion ? newer(release.version, installedVersion) : !!installedVersion && this.updates.has(app.id),
      progress: state.active ? state.progress : this.progress.get(app.id) ?? state.progress }
  }
  async list() {
    // Earlier Debian discoveries must not hide the curated catalog if AppStream is missing.
    try { await this.restore() } catch { /* retry on the next listing */ }
    if (this.guest()) await this.observeGuest()
    if (!this.working && !this.observing && Object.values(this.states).some(state => state.active)) this.observe()
    const apps = [...this.curated, ...this.store.values(), ...this.flatpaks.values()]
    return { packs: this.data.packs, apps: await Promise.all(apps.map(app => this.view(app))) }
  }
  private async observeGuest(): Promise<void> {
    const tracked = [...this.curated, ...this.store.values()]
    const raw = object(JSON.parse(await this.invoke('list', tracked.map(({ id, source }) => ({ id, source })))))
    const apps = object(raw.apps), environment = object(raw.environment)
    this.environment = { flatpak: environment.flatpak === true, depot: environment.depot === true }
    const states: Record<string, State> = {}
    for (const app of tracked) states[app.id] = parseState(app.id, apps[app.id])
    const flatpaks = new Map<string, Entry>()
    const runtimes: string[] = []
    for (const [id, value] of Object.entries(apps)) {
      const appId = id.startsWith('flathub-') ? id.slice('flathub-'.length) : null
      if (!appId || !APP_ID.test(appId) || flatpaks.size >= 500) continue
      const installed = parseInstalled(object(value).flatpak)
      const indexed = this.flathub?.get(appId)
      if (installed?.runtime) runtimes.push(installed.runtime)
      // An installed app that has left Flathub's index keeps the name its own metadata gives.
      const entry = indexed ? flathubEntry(indexed) : installed?.name ? flathubEntry({ appId, name: installed.name, summary: installed.summary || installed.name, developer: null, license: null, verified: false, icon: '', categories: ['Utilities'], keywords: [], runtime: installed.runtime ?? '', installs: 0 }) : this.flatpaks.get(id)
      if (!entry) continue
      flatpaks.set(id, entry)
      states[id] = parseState(id, value)
    }
    this.states = states
    this.flatpaks = flatpaks
    if (this.depot?.enabled && this.environment.depot) {
      await this.depot.note(this.computer, runtimes)
      // A runtime collected while this computer slept returns before its apps need it.
      if (!this.busy) for (const runtime of new Set(runtimes)) if (!this.depot.has(runtime)) void this.depot.ensure(runtime).catch(error => console.error(`Cannot restore ${runtime} to the depot:`, error))
    }
  }
  private find(id: string): Entry {
    const known = this.curated.find(item => item.id === id) ?? this.store.get(id) ?? this.flatpaks.get(id)
    if (known) return known
    const appId = id.startsWith('flathub-') ? id.slice('flathub-'.length) : ''
    const indexed = APP_ID.test(appId) ? this.flathub?.get(appId) : undefined
    if (indexed) return flathubEntry(indexed)
    throw new AgentNotFoundError('Application not found in catalog')
  }
  start(id: string, action: Operation): void { this.startMany([this.find(id)], action) }
  /** The exact argument the guest installer runs with: resolved releases and current runtimes. */
  private async prepare(app: Entry, action: Operation): Promise<Record<string, unknown>> {
    if (app.source.kind === 'release' && action !== 'remove') {
      const release = await this.releases?.latest(app.id, action === 'update')
      if (!release) throw new Error(`No verified release of ${app.name} is available`)
      return { ...app, source: { kind: 'deb', package: app.source.package, ...release } }
    }
    if (app.source.kind === 'flatpak' && action !== 'remove') {
      if (!this.environment.flatpak) throw new Error('Flatpak is not installed on this computer yet. Wake it again after Caboose components update.')
      // An update can move an app to a newer runtime; the index names the current one.
      const runtime = this.flathub?.get(app.source.appId)?.runtime ?? app.source.runtime
      if (this.depot?.enabled && this.environment.depot && RUNTIME.test(runtime)) {
        this.setProgress({ id: app.id, operation: action, phase: 'installing', stage: 'preparing', message: 'Checking shared runtimes', value: null })
        await this.depot.ensure(runtime, progress => this.setProgress({ id: app.id, operation: action, phase: 'installing', stage: progress.totalBytes ? 'downloading' : 'preparing', message: progress.message,
          value: progress.totalBytes ? Math.min(1, progress.downloadedBytes! / progress.totalBytes) : null, ...(progress.totalBytes ? { downloadedBytes: progress.downloadedBytes!, totalBytes: progress.totalBytes } : {}) }))
      }
      return { ...app, source: { kind: 'flatpak', appId: app.source.appId, runtime } }
    }
    return { ...app }
  }
  private startMany(apps: Entry[], action: Operation): void {
    if (this.busy) throw new AgentConflictError('Another catalog operation is in progress')
    if (!this.guest()) throw new AgentUnavailableError()
    this.working = true
    const release = this.lease()
    for (const app of apps) this.setProgress({ id: app.id, operation: action, phase: 'queued' })
    void (async () => {
      try {
        await this.list()
        if (Object.values(this.states).some(state => state.active)) throw new AgentConflictError('Another catalog operation is still running')
        for (const app of apps) {
          const state = this.states[app.id] ?? EMPTY
          if (action === 'install' && state.installedVersion && !state.interrupted && !state.lastError) { this.progress.delete(app.id); continue }
          this.setProgress({ id: app.id, operation: action, phase: 'installing' })
          try {
            if ((action === 'update' || action === 'remove') && !state.installedVersion && !state.interrupted && !state.lastError) throw new Error('Application is not installed')
            const argument = await this.prepare(app, action)
            let polling = false, pollActive = true
            const timer = setInterval(() => {
              if (polling) return
              polling = true
              void this.invoke('progress', app.id).then(output => {
                if (!pollActive) return
                const info = parseProgress(app.id, JSON.parse(output))
                if (info?.phase === 'installing') this.setProgress(info)
              }).catch(() => {}).finally(() => { polling = false })
            }, 2000)
            timer.unref()
            const operationId = randomUUID()
            try {
              try { await this.invoke(action, { ...argument, operationId }, 60 * 60_000) }
              catch (error) { await this.reconcile(app.id, action, operationId, error) }
            } finally { pollActive = false; clearInterval(timer) }
            this.updates.delete(app.id)
            this.setProgress({ id: app.id, operation: action, phase: 'finished' })
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error)
            this.setProgress({ id: app.id, operation: action, phase: 'failed', message: message.slice(-1000) })
          }
          try { await this.list() } catch (error) { console.error('Could not refresh catalog:', error) }
          this.emit({ type: 'catalog.changed', id: app.id })
        }
      } catch (error) {
        for (const app of apps) this.setProgress({ id: app.id, operation: action, phase: 'failed', message: error instanceof Error ? error.message : String(error) })
      } finally {
        this.working = false
        if (!this.observing && Object.values(this.states).some(state => state.active)) this.observe()
        release(); this.emit({ type: 'catalog.changed' })
      }
    })()
  }
  /**
   * Once a day while the computer runs: shared runtimes first, then every installed app with
   * a newer release, Flathub commit or Debian package. Never wakes the computer.
   */
  async autoUpdate(): Promise<void> {
    if (this.busy || !this.guest() || this.now() - this.updatedAt < UPDATE_MS) return
    this.updatedAt = this.now()
    if (this.depot?.enabled) await this.depot.maintain().catch(error => console.error('Shared runtime maintenance failed:', error))
    if (this.busy || !this.guest()) return
    this.working = true
    const release = this.lease()
    let due: Entry[] = []
    try {
      const listing = await this.list()
      const installed = new Set(listing.apps.filter(app => app.installedVersion && !app.active).map(app => app.id))
      const updates = object(JSON.parse(await this.invoke('updates', [...this.curated, ...this.store.values()].filter(app => installed.has(app.id) && app.source.kind === 'apt').map(({ id, source }) => ({ id, source })), 15 * 60_000)))
      const flatpak = new Set(Array.isArray(updates.flatpak) ? updates.flatpak.filter((id): id is string => typeof id === 'string').map(id => `flathub-${id}`) : [])
      const apt = new Set(Array.isArray(updates.apt) ? updates.apt.filter((id): id is string => typeof id === 'string') : [])
      for (const app of [...this.curated, ...this.store.values(), ...this.flatpaks.values()]) {
        if (!installed.has(app.id)) continue
        const version = this.states[app.id]?.installedVersion
        if (app.source.kind === 'release') {
          const latest = await this.releases?.latest(app.id, true).catch(() => null)
          if (latest && version && newer(latest.version, version)) due.push(app)
        } else if (flatpak.has(app.id) || apt.has(app.id)) due.push(app)
      }
      this.updates = new Set(due.map(app => app.id))
    } catch (error) {
      console.error('Automatic update check failed:', error)
      due = []
    } finally { this.working = false; release() }
    if (due.length && !this.busy && this.guest()) this.startMany(due, 'update')
  }
  /** A channel timeout is not proof that apt stopped. Keep the lease until the guest answers. */
  private async reconcile(id: string, operation: Operation, operationId: string, error: unknown): Promise<void> {
    for (;;) {
      try { await this.list() }
      catch {
        this.reconnecting(id, operation)
        await pause(); continue
      }
      const state = this.states[id] ?? EMPTY
      if (!state.active) {
        if (state.operationId === operationId && state.progress?.phase === 'finished') return
        throw new Error((state.operationId === operationId ? state.progress?.message ?? state.lastError : null) ?? (error instanceof Error ? error.message : String(error)))
      }
      if (state.progress) this.setProgress(state.progress)
      await pause()
    }
  }
  /** Reattach to work that survived a host restart; no second installer is started. */
  private observe(): void {
    this.observing = true
    const release = this.lease()
    const ids = new Set(Object.entries(this.states).filter(([, state]) => state.active).map(([id]) => id))
    void (async () => {
      try {
        while (Object.values(this.states).some(state => state.active)) {
          await pause()
          try { await this.list() } catch {
            for (const id of ids) this.reconnecting(id, this.states[id]?.progress?.operation ?? 'install')
            continue
          }
          for (const id of ids) {
            const state = this.states[id] ?? EMPTY
            if (state.progress) this.setProgress(state.progress)
            if (!state.active) this.emit({ type: 'catalog.changed', id })
          }
        }
      } finally { this.observing = false; release(); this.emit({ type: 'catalog.changed' }) }
    })()
  }
  private reconnecting(id: string, operation: Operation): void {
    const progress: Progress = { id, operation, phase: 'installing', stage: 'preparing', message: 'Reconnecting to installation…', value: null }
    const state = this.states[id]
    if (state?.active) this.states[id] = { ...state, progress }
    this.setProgress(progress)
  }
  private setProgress(progress: Progress): void { this.progress.set(progress.id, progress); this.emit({ type: 'catalog.progress', ...progress }) }
}

/** Convert installed catalog entries to shell-free ACP stdio server definitions. */
export function craftMcpServers(apps: Array<{ id: string; mcp?: string; installedVersion: string | null }>) {
  return apps.flatMap(app => {
    if (!app.installedVersion || !app.mcp) return []
    const parts = app.mcp.split(' ')
    if (!parts.every(part => /^[a-zA-Z0-9._-]+$/.test(part))) throw new Error(`Invalid MCP command for ${app.id}`)
    return [{ name: `caboose-${app.id}`, command: parts[0]!, args: parts.slice(1), env: [] }]
  })
}
