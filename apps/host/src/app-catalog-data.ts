import { readFileSync } from 'node:fs'

export type AppSource = { kind: 'apt'; packages: string[] } | { kind: 'deb'; package: string; version: string; url: string; sha256: string; size: number }
export interface CatalogEntry { id: string; name: string; summary: string; category: string; packs: string[]; icon: string; desktopId: string; fileTypes: { extensions: string[]; utTypes: string[] }; cli?: string; mcp?: string; source: AppSource }
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
    ids.add(app.id)
    const source = app.source
    if (!source || (source.kind === 'apt' ? !strings(source.packages) || !source.packages.length || source.packages.some(p => !identifier.test(p)) : source.kind === 'deb' ? !identifier.test(source.package) || !/^\d+\.\d+\.\d+$/.test(source.version) || !/^[a-f0-9]{64}$/.test(source.sha256) || !Number.isSafeInteger(source.size) || source.size <= 0 || source.url !== `https://github.com/storytold/${app.id}/releases/download/v${source.version}/${app.id}-${source.version}-linux-x86_64.deb` : true)) throw new Error(`Invalid source for ${app.id}`)
  }
  return data
}
export function loadCatalog(): CatalogData {
  return parseCatalog(JSON.parse(readFileSync(new URL('../../../guest/catalog/catalog.json', import.meta.url), 'utf8')))
}
