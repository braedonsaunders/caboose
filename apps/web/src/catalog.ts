/** The optional application catalog, as `GET /v1/catalog` reports it (docs/architecture.md, Catalog). */

export type CatalogOperation = 'install' | 'update' | 'rollback' | 'remove'

export interface CatalogProgress {
  id: string
  operation: CatalogOperation
  phase: 'queued' | 'installing' | 'finished' | 'failed'
  message?: string
  stage?: string
  /** 0–1 where the installer can estimate it, else null. */
  value?: number | null
}

export interface CatalogPack {
  id: string
  name: string
}

export type CatalogSource =
  | { kind: 'apt'; packages: string[] }
  | { kind: 'deb'; package: string; version: string; url: string; sha256: string; size: number }

export interface CatalogApp {
  id: string
  name: string
  summary: string
  category: string
  packs: string[]
  /** The freedesktop icon name. */
  icon: string
  desktopId: string
  source: CatalogSource
  /** The installed version as dpkg reports it, or null. Last observed while the computer is parked. */
  installedVersion: string | null
  canRollback: boolean
  lastError: string | null
  /** An operation was running when the computer stopped. */
  interrupted: boolean
  /** A PNG data URL for release apps; null for Debian apps. */
  iconData: string | null
  /** The pinned release version for release apps; null for Debian apps. */
  pinnedVersion: string | null
  updateAvailable: boolean
  progress: CatalogProgress | null
}

export interface CatalogResponse {
  packs: CatalogPack[]
  apps: CatalogApp[]
}

/** An operation the host has accepted and not yet finished. */
export function isPending(progress: CatalogProgress | null): boolean {
  return progress?.phase === 'queued' || progress?.phase === 'installing'
}

/** Whether any catalog operation is queued or running; the host runs one at a time. */
export function catalogBusy(catalog: CatalogResponse | null): boolean {
  return catalog?.apps.some(app => isPending(app.progress)) ?? false
}

export function operationLabel(operation: CatalogOperation): string {
  switch (operation) {
    case 'install': return 'Installing'
    case 'update': return 'Updating'
    case 'rollback': return 'Rolling back'
    case 'remove': return 'Removing'
  }
}

/** What to say about an app's operation, with a 0–100 value when the installer estimates one. */
export function progressSummary(progress: CatalogProgress): { label: string; percent?: number } {
  if (progress.phase === 'queued') return { label: 'Queued' }
  if (progress.phase === 'failed') return { label: `${operationLabel(progress.operation)} failed` }
  if (progress.phase === 'finished') return { label: progress.operation === 'remove' ? 'Removed' : 'Done' }
  const stage = progress.stage && progress.stage !== 'installing' ? ` · ${progress.stage}` : ''
  const label = `${operationLabel(progress.operation)}${stage}`
  return typeof progress.value === 'number' && Number.isFinite(progress.value)
    ? { label, percent: Math.round(Math.min(1, Math.max(0, progress.value)) * 100) }
    : { label }
}

/** The version to show: Debian revisions are noise next to an upstream version. */
export function displayVersion(version: string): string {
  return version.split('-')[0] ?? version
}

/** The operations the owner can start for an app, in the order they are offered. */
export function appActions(app: Pick<CatalogApp, 'installedVersion' | 'updateAvailable' | 'canRollback'>): CatalogOperation[] {
  if (!app.installedVersion) return ['install']
  const actions: CatalogOperation[] = []
  if (app.updateAvailable) actions.push('update')
  if (app.canRollback) actions.push('rollback')
  actions.push('remove')
  return actions
}

/** Apps in a pack, in catalog order. */
export function packApps(catalog: CatalogResponse, packId: string): CatalogApp[] {
  return catalog.apps.filter(app => app.packs.includes(packId))
}

/** A pack is worth offering while any of its apps is missing. */
export function packMissing(catalog: CatalogResponse, packId: string): number {
  return packApps(catalog, packId).filter(app => !app.installedVersion).length
}

/** Matches an app by name, summary or category, ignoring case. */
export function matchesQuery(app: { name: string; summary?: string; category?: string; categories?: string[] }, query: string): boolean {
  const needle = query.trim().toLowerCase()
  if (!needle) return true
  return [app.name, app.summary ?? '', app.category ?? '', ...(app.categories ?? [])].some(value => value.toLowerCase().includes(needle))
}
