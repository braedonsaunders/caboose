/** The optional application catalog, as `GET /v1/catalog` and its discover route report it (docs/architecture.md, Catalog). */

export type CatalogOperation = 'install' | 'update' | 'remove'

export interface CatalogProgress {
  id: string
  operation: CatalogOperation
  phase: 'queued' | 'installing' | 'finished' | 'failed'
  message?: string
  stage?: string
  /** 0–1 where the installer can estimate it, else null. */
  value?: number | null
  downloadedBytes?: number
  totalBytes?: number
}

/** A curated collection: browsed, never installed at once. */
export interface CatalogPack {
  id: string
  name: string
  /** The Library category whose popular apps follow the collection's own. */
  category?: string
}

export interface CatalogSource {
  kind: 'apt' | 'release' | 'flatpak'
  /** Download bytes, when known. */
  size?: number
}

export interface CatalogApp {
  /** A curated id, `flathub-<appId>` or `debian-<package>`. */
  id: string
  name: string
  summary: string
  category: string
  categories: string[]
  /** Curated packs only. */
  packs: string[]
  desktopId: string
  fileTypes: { extensions: string[]; utTypes: string[] }
  /** A 128-pixel PNG data URL, or null. */
  iconData: string | null
  source: CatalogSource
  /** One of Caboose's curated entries. */
  curated: boolean
  origin: 'caboose' | 'flathub' | 'debian'
  developer: string | null
  /** A Flathub verified publisher. */
  verified: boolean
  license: string | null
  /** Flathub installs last month. */
  installs: number | null
  /** The installed version, or null. Last observed while the computer is parked. */
  installedVersion: string | null
  latestVersion: string | null
  /** Apps update on their own; this is a newer version not yet installed. */
  updateAvailable: boolean
  lastError: string | null
  /** An operation was running when the computer stopped. */
  interrupted: boolean
  active: boolean
  progress: CatalogProgress | null
}

export interface CatalogResponse {
  packs: CatalogPack[]
  apps: CatalogApp[]
}

/** One page of the Library: curated matches first, then Flathub's, ranked by the host. */
export interface CatalogPage {
  apps: CatalogApp[]
  total: number
  offset: number
  limit: number
  /** The display categories, in the host's order. */
  categories: string[]
  /** Why only Caboose's apps are listed: the host could not reach Flathub. */
  error: string | null
}

export interface DiscoverQuery {
  q?: string
  /** One of `CatalogPage.categories`; empty for all. */
  category?: string
  /** A curated collection's id, browsed in place of a category; never installed at once. */
  collection?: string
  offset?: number
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
export function displayVersion(version: string, source?: CatalogSource): string {
  return source && source.kind !== 'apt' ? version : version.split('-')[0] ?? version
}

/** The operations the owner can start for an app, in the order they are offered. */
export function appActions(app: Pick<CatalogApp, 'installedVersion' | 'updateAvailable'>): CatalogOperation[] {
  if (!app.installedVersion) return ['install']
  const actions: CatalogOperation[] = []
  if (app.updateAvailable) actions.push('update')
  actions.push('remove')
  return actions
}

/** A button's label: installing after a failed or interrupted attempt is a retry. */
export function actionLabel(app: Pick<CatalogApp, 'lastError' | 'interrupted'>, operation: CatalogOperation): string {
  switch (operation) {
    case 'install': return app.lastError || app.interrupted ? 'Retry' : 'Install'
    case 'update': return 'Update now'
    case 'remove': return 'Remove'
  }
}

/** Apps in a pack, in catalog order. */
export function packApps(catalog: CatalogResponse, packId: string): CatalogApp[] {
  return catalog.apps.filter(app => app.packs.includes(packId))
}


/**
 * Library rows with the catalog's current state. `GET /v1/catalog` lists every app that is
 * curated, installed, being changed or failed, so a discovered app it leaves out has none of
 * that state, whatever it had when its page arrived.
 */
export function withLiveState(apps: CatalogApp[], catalog: CatalogResponse | null): CatalogApp[] {
  if (!catalog) return apps
  const live = new Map(catalog.apps.map(app => [app.id, app]))
  return apps.map(app => live.get(app.id) ?? (app.curated ? app : {
    ...app, installedVersion: null, updateAvailable: false, lastError: null, interrupted: false, active: false, progress: null,
  }))
}

/** The next page after the rows already shown, without an app the ranking moved between pages appearing twice. */
export function appendPage(shown: CatalogApp[], page: CatalogApp[]): CatalogApp[] {
  const seen = new Set(shown.map(app => app.id))
  return [...shown, ...page.filter(app => !seen.has(app.id) && seen.add(app.id))]
}

/** Where the next page starts, or null once every result has arrived. An empty page ends the list. */
export function nextOffset(page: Pick<CatalogPage, 'apps' | 'offset' | 'total'>): number | null {
  const next = page.offset + page.apps.length
  return page.apps.length > 0 && next < page.total ? next : null
}
