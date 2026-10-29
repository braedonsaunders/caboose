import { randomUUID } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { existsSync, readFileSync } from 'node:fs'
import { AgentConflictError, AgentInputError, AgentNotFoundError, AgentUnavailableError, type AgentGuest } from './agents.js'
import { loadCatalog, type CatalogData, type CatalogEntry } from './app-catalog-data.js'

type Operation = 'install' | 'update' | 'rollback' | 'remove'
type Progress = { id: string; operation: Operation; phase: 'queued' | 'installing' | 'finished' | 'failed'; message?: string; stage?: string; value?: number | null; downloadedBytes?: number; totalBytes?: number }
type State = { installedVersion: string | null; canRollback: boolean; lastError: string | null; interrupted: boolean; active: boolean; operationId: string | null; progress: Progress | null }
const EMPTY: State = { installedVersion: null, canRollback: false, lastError: null, interrupted: false, active: false, operationId: null, progress: null }
const OPERATIONS = ['install', 'update', 'rollback', 'remove']
const STAGES = ['preparing', 'downloading', 'verifying', 'refreshing', 'installing', 'configuring', 'removing', 'finished']
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
function parseStates(value: unknown, apps: CatalogEntry[]): Record<string, State> {
  const raw = object(value)
  return Object.fromEntries(apps.map(app => {
    const state = object(raw[app.id])
    return [app.id, { installedVersion: bounded(state.installedVersion) ?? null, canRollback: state.canRollback === true,
      lastError: bounded(state.lastError) ?? null, interrupted: state.active !== true && state.interrupted === true, active: state.active === true, operationId: bounded(state.operationId) ?? null,
      progress: parseProgress(app.id, state.progress) }]
  }))
}
const pause = () => new Promise<void>(resolve => { const timer = setTimeout(resolve, 2000); timer.unref() })
const ICONS = new URL('../../../guest/catalog/icons/', import.meta.url)

/** The app's icon from guest/catalog/icons as a PNG data URL, so clients can show apps that are not installed. */
export function catalogIcon(id: string): string | null {
  const file = new URL(`${id}.png`, ICONS)
  return existsSync(file) ? 'data:image/png;base64,' + readFileSync(file).toString('base64') : null
}

/** Catalog operations are serialized and execute entirely inside the guest as root. */
export class AppCatalog {
  private readonly data: CatalogData
  private states: Record<string, State> = {}
  private progress = new Map<string, Progress>()
  private store = new Map<string, CatalogEntry & { categories: string[]; license: string; storeComponent: string }>()
  private working = false
  private observing = false
  constructor(private readonly guest: () => AgentGuest | undefined, private readonly emit: (event: unknown) => void, private readonly lease: () => () => void, data = loadCatalog()) { this.data = data }
  get busy(): boolean { return this.working || this.observing || Object.values(this.states).some(state => state.active) }
  private async invoke(action: string, argument: unknown, timeout = 30_000): Promise<string> {
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const script = await readFile(new URL('./guest-catalog.py', import.meta.url), 'utf8')
    return guest.run('/usr/bin/python3', ['-c', script, action, JSON.stringify(argument)], timeout)
  }
  async discover(query: string) {
    if (typeof query !== 'string' || query.length > 100 || /[\x00-\x1f]/.test(query)) throw new AgentInputError('Invalid search')
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const script = await readFile(new URL('./guest-store.py', import.meta.url), 'utf8')
    const output = await guest.run('/usr/bin/python3', ['-c', script, JSON.stringify(query)], 60_000)
    if (output.length > 200_000) throw new Error('AppStream results too large')
    const raw: unknown = JSON.parse(output)
    if (!Array.isArray(raw) || raw.length > 100) throw new Error('Invalid AppStream results')
    const found: string[] = []
    for (const value of raw) {
      const v = object(value)
      if (typeof v.package !== 'string' || !/^[a-z0-9][a-z0-9+.-]{0,99}$/.test(v.package) || v.id !== `debian-${v.package}` || typeof v.desktopId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}\.desktop$/.test(v.desktopId) || typeof v.name !== 'string' || !v.name || v.name.length > 160 || typeof v.summary !== 'string' || !v.summary || v.summary.length > 500 || !Array.isArray(v.categories) || v.categories.length > 12 || !v.categories.every(c => typeof c === 'string' && /^[A-Za-z0-9-]{1,40}$/.test(c)) || typeof v.license !== 'string' || v.license.length > 200 || typeof v.componentId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}$/.test(v.componentId)) continue
      if (this.data.apps.some(app => app.source.kind === 'apt' && app.source.packages.includes(v.package as string))) continue
      const entry: CatalogEntry & { categories: string[]; license: string; storeComponent: string } = { id: v.id as string, name: v.name, summary: v.summary, category: v.categories[0] ?? 'Other', categories: v.categories, license: v.license, storeComponent: v.componentId, packs: [], icon: '', desktopId: v.desktopId, fileTypes: { extensions: [], utTypes: [] }, source: { kind: 'apt', packages: [v.package] } }
      if (!this.store.has(entry.id) && this.store.size >= 300) {
        const evict = [...this.store.keys()].find(id => !this.states[id]?.installedVersion && !this.states[id]?.active && !this.progress.has(id))
        if (!evict) break
        this.store.delete(evict)
      }
      this.store.set(entry.id, entry); found.push(entry.id)
    }
    const listing = await this.list()
    return { apps: listing.apps.filter(app => found.includes(app.id)) }
  }
  async list() {
    const apps = [...this.data.apps, ...this.store.values()]
    if (this.guest()) this.states = parseStates(JSON.parse(await this.invoke('list', apps)), apps)
    if (!this.working && !this.observing && Object.values(this.states).some(state => state.active)) this.observe()
    return { packs: this.data.packs, apps: apps.map(app => {
      const { operationId: _operationId, ...state } = this.states[app.id] ?? EMPTY
      const pinnedVersion = app.source.kind === 'deb' ? app.source.version : null
      const installedVersion = state.installedVersion
      const iconData = catalogIcon(app.id)
      return { ...app, ...state, iconData, pinnedVersion, updateAvailable: !!(pinnedVersion && installedVersion && installedVersion.split('-')[0] !== pinnedVersion), progress: state.active ? state.progress : this.progress.get(app.id) ?? state.progress }
    }) }
  }
  private find(id: string): CatalogEntry {
    const app = this.data.apps.find(item => item.id === id) ?? this.store.get(id)
    if (!app) throw new AgentNotFoundError('Application not found in catalog')
    return app
  }
  start(id: string, action: 'install' | 'update' | 'rollback' | 'remove'): void { this.startMany([this.find(id)], action) }
  startPack(id: string): void {
    if (!this.data.packs.some(p => p.id === id)) throw new AgentNotFoundError('Pack not found')
    this.startMany(this.data.apps.filter(app => app.packs.includes(id)), 'install')
  }
  private startMany(apps: CatalogEntry[], action: 'install' | 'update' | 'rollback' | 'remove'): void {
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
            if (action === 'rollback' && !state.canRollback && !state.interrupted && !state.lastError) throw new Error('No previous release is available')
            if ((action === 'update' || action === 'remove') && !state.installedVersion && !state.interrupted && !state.lastError) throw new Error('Application is not installed')
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
              try { await this.invoke(action, { ...app, operationId }, 30 * 60_000) }
              catch (error) { await this.reconcile(app.id, action, operationId, error) }
            } finally { pollActive = false; clearInterval(timer) }
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
            const state = this.states[id]!
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
