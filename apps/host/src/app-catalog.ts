import { readFile } from 'node:fs/promises'
import { readFileSync } from 'node:fs'
import { AgentConflictError, AgentNotFoundError, AgentOperationError, AgentUnavailableError, type AgentGuest } from './agents.js'
import { loadCatalog, type CatalogData, type CatalogEntry } from './app-catalog-data.js'

type State = { installedVersion: string | null; canRollback: boolean; lastError: string | null; interrupted: boolean }
type Progress = { id: string; operation: string; phase: 'queued' | 'installing' | 'finished' | 'failed'; message?: string; stage?: string; value?: number | null }
const EMPTY: State = { installedVersion: null, canRollback: false, lastError: null, interrupted: false }

/** Catalog operations are serialized and execute entirely inside the guest as root. */
export class AppCatalog {
  private readonly data: CatalogData
  private states: Record<string, State> = {}
  private progress = new Map<string, Progress>()
  private working = false
  constructor(private readonly guest: () => AgentGuest | undefined, private readonly emit: (event: unknown) => void, private readonly lease: () => () => void, data = loadCatalog()) { this.data = data }
  get busy(): boolean { return this.working }
  private async invoke(action: string, argument: unknown, timeout = 30_000): Promise<string> {
    const guest = this.guest()
    if (!guest) throw new AgentUnavailableError()
    const script = await readFile(new URL('./guest-catalog.py', import.meta.url), 'utf8')
    return guest.run('/usr/bin/python3', ['-c', script, action, JSON.stringify(argument)], timeout)
  }
  async list() {
    if (this.guest()) this.states = JSON.parse(await this.invoke('list', this.data.apps)) as Record<string, State>
    return { packs: this.data.packs, apps: this.data.apps.map(app => {
      const state = this.states[app.id] ?? EMPTY
      const pinnedVersion = app.source.kind === 'deb' ? app.source.version : null
      const installedVersion = state.installedVersion
      const iconData = app.source.kind === 'deb' ? 'data:image/png;base64,' + readFileSync(new URL(`../../../guest/catalog/icons/${app.id}.png`, import.meta.url)).toString('base64') : null
      return { ...app, ...state, iconData, pinnedVersion, updateAvailable: !!(pinnedVersion && installedVersion && installedVersion.split('-')[0] !== pinnedVersion), progress: this.progress.get(app.id) ?? null }
    }) }
  }
  private find(id: string): CatalogEntry {
    const app = this.data.apps.find(item => item.id === id)
    if (!app) throw new AgentNotFoundError('Application not found in catalog')
    return app
  }
  start(id: string, action: 'install' | 'update' | 'rollback' | 'remove'): void { this.startMany([this.find(id)], action) }
  startPack(id: string): void {
    if (!this.data.packs.some(p => p.id === id)) throw new AgentNotFoundError('Pack not found')
    this.startMany(this.data.apps.filter(app => app.packs.includes(id)), 'install')
  }
  private startMany(apps: CatalogEntry[], action: 'install' | 'update' | 'rollback' | 'remove'): void {
    if (this.working) throw new AgentConflictError('Another catalog operation is in progress')
    if (!this.guest()) throw new AgentUnavailableError()
    this.working = true
    const release = this.lease()
    for (const app of apps) this.setProgress({ id: app.id, operation: action, phase: 'queued' })
    void (async () => {
      try {
        await this.list()
        for (const app of apps) {
          const state = this.states[app.id] ?? EMPTY
          if (action === 'install' && state.installedVersion) { this.progress.delete(app.id); continue }
          this.setProgress({ id: app.id, operation: action, phase: 'installing' })
          try {
            if (action === 'rollback' && !state.canRollback) throw new Error('No previous release is available')
            if ((action === 'update' || action === 'remove') && !state.installedVersion) throw new Error('Application is not installed')
            let polling = false
            const timer = setInterval(() => {
              if (polling) return
              polling = true
              void this.invoke('progress', app.id).then(output => {
                if (this.progress.get(app.id)?.phase !== 'installing') return
                const info = JSON.parse(output) as { stage: string; value: number | null }
                this.setProgress({ id: app.id, operation: action, phase: 'installing', ...info })
              }).catch(() => {}).finally(() => { polling = false })
            }, 2000)
            timer.unref()
            try { await this.invoke(action, app, 30 * 60_000) } finally { clearInterval(timer) }
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
      } finally { this.working = false; release(); this.emit({ type: 'catalog.changed' }) }
    })()
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
