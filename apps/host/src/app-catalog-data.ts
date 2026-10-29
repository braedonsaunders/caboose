import { readFileSync } from 'node:fs'
import { APP_ID } from './flathub.js'

/**
 * Where an application comes from: Debian packages, a Craft release `.deb` that follows the
 * app's latest GitHub release, or a Flathub application with the runtime it needs.
 */
export type AppSource = { kind: 'apt'; packages: string[] } | { kind: 'release'; package: string } | { kind: 'flatpak'; appId: string; runtime: string }
export interface CatalogEntry { id: string; name: string; summary: string; category: string; packs: string[]; icon: string; desktopId: string; fileTypes: { extensions: string[]; utTypes: string[] }; cli?: string; mcp?: string; flathub?: string; source: AppSource }
export interface CatalogData { packs: { id: string; name: string }[]; apps: CatalogEntry[] }
const identifier = /^[a-z0-9][a-z0-9+.-]*$/
const nonempty = (v: unknown): v is string => typeof v === 'string' && v.length > 0
const strings = (v: unknown): v is string[] => Array.isArray(v) && v.every(nonempty)
/** Validate repository-owned metadata before it can become root commands in a guest. */
export function parseCatalog(value: unknown): CatalogData {
  if (!value || typeof value !== 'object') throw new Error('Invalid catalog')
  const data = value as CatalogData
  if (!Array.isArray(data.packs) || !Array.isArray(data.apps)) throw new Error('Invalid catalog lists')
  const packs = new Set<string>(), ids = new Set<string>()
  for (const pack of data.packs) {
    if (!identifier.test(pack.id) || !nonempty(pack.name) || packs.has(pack.id)) throw new Error('Invalid catalog pack')
    packs.add(pack.id)
  }
  for (const app of data.apps) {
    if (!app || !identifier.test(app.id) || ids.has(app.id) || !nonempty(app.name) || !nonempty(app.summary) || !nonempty(app.category) || !nonempty(app.icon) || !nonempty(app.desktopId) || !strings(app.packs) || app.packs.some(p => !packs.has(p)) || !app.fileTypes || !strings(app.fileTypes.extensions) || !strings(app.fileTypes.utTypes)) throw new Error('Invalid catalog entry')
    if (app.flathub !== undefined && (typeof app.flathub !== 'string' || !APP_ID.test(app.flathub))) throw new Error(`Invalid Flathub alias for ${app.id}`)
    ids.add(app.id)
    const source = app.source as AppSource
    // A Craft release is always the app's own repository's asset, so it names nothing but its package.
    if (!source || (source.kind === 'apt' ? !strings(source.packages) || !source.packages.length || source.packages.some(p => !identifier.test(p)) : source.kind === 'release' ? source.package !== app.id || !/^[a-z]+craft$/.test(app.id) : true)) throw new Error(`Invalid source for ${app.id}`)
  }
  return data
}
export function loadCatalog(): CatalogData {
  return parseCatalog(JSON.parse(readFileSync(new URL('../../../guest/catalog/catalog.json', import.meta.url), 'utf8')))
}
