import { readFileSync } from 'node:fs'
import { APP_ID, CATEGORIES } from './flathub.js'

/** A computer's architecture, as Flatpak and the release assets name it. */
export type Architecture = 'x86_64' | 'aarch64'
/** A GitHub release asset pinned by its exact size and SHA-256. */
export interface Asset { url: string; sha256: string; size: number }
/**
 * A game (docs/game-handoff.md): its pinned WebAssembly build archive, the bundle Caboose ships
 * for it in guest/game/games, and optional native builds per architecture.
 */
export type GameSource = Asset & { kind: 'game'; bundle: string; version: string; native?: Partial<Record<Architecture, Asset>> }
/**
 * Where an application comes from: Debian packages, a Craft release `.deb` that follows the
 * app's latest GitHub release, a pinned game, or a Flathub application with the runtime it needs.
 */
export type AppSource = { kind: 'apt'; packages: string[] } | { kind: 'release'; package: string } | GameSource | { kind: 'flatpak'; appId: string; runtime: string }
export interface CatalogEntry { id: string; name: string; summary: string; category: string; icon: string; desktopId: string; fileTypes: { extensions: string[]; utTypes: string[] }; cli?: string; mcp?: string; flathub?: string; source: AppSource }
export interface CatalogData { apps: CatalogEntry[] }
const identifier = /^[a-z0-9][a-z0-9+.-]*$/
const nonempty = (v: unknown): v is string => typeof v === 'string' && v.length > 0
const strings = (v: unknown): v is string[] => Array.isArray(v) && v.every(nonempty)
const ARCHITECTURES: readonly string[] = ['x86_64', 'aarch64']
/** A desktop entry's file name, or an icon name, that the guest writes as a path. */
const DESKTOP_NAME = /^[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}$/
const asset = (v: unknown): v is Asset => {
  const a = v as Asset
  return !!a && typeof a === 'object' && typeof a.url === 'string' && /^https:\/\/github\.com\/[A-Za-z0-9-]+\/[A-Za-z0-9._-]+\/releases\/download\/[A-Za-z0-9._+-]+\/[A-Za-z0-9._+-]+$/.test(a.url)
    && !a.url.split('/').some(part => part === '.' || part === '..') && typeof a.sha256 === 'string' && /^[a-f0-9]{64}$/.test(a.sha256) && Number.isSafeInteger(a.size) && a.size > 0
}
/** A game's pins, its shipped bundle's name and a dotted numeric version the Library compares. */
const game = (app: CatalogEntry, source: GameSource): boolean => asset(source) && typeof source.bundle === 'string' && identifier.test(source.bundle)
  && typeof source.version === 'string' && /^\d{1,9}(\.\d{1,9}){0,3}$/.test(source.version) && DESKTOP_NAME.test(app.icon) && app.desktopId.endsWith('.desktop') && DESKTOP_NAME.test(app.desktopId)
  && (source.native === undefined || (!!source.native && typeof source.native === 'object' && !Array.isArray(source.native)
    && Object.entries(source.native).every(([arch, build]) => ARCHITECTURES.includes(arch) && asset(build))))
/** Validate repository-owned metadata before it can become root commands in a guest. */
export function parseCatalog(value: unknown): CatalogData {
  if (!value || typeof value !== 'object') throw new Error('Invalid catalog')
  const data = value as CatalogData
  if (!Array.isArray(data.apps)) throw new Error('Invalid catalog list')
  const ids = new Set<string>()
  for (const app of data.apps) {
    if (!app || !identifier.test(app.id) || ids.has(app.id) || !nonempty(app.name) || !nonempty(app.summary) || !(CATEGORIES as readonly string[]).includes(app.category) || !nonempty(app.icon) || !nonempty(app.desktopId) || !app.fileTypes || !strings(app.fileTypes.extensions) || !strings(app.fileTypes.utTypes)) throw new Error('Invalid catalog entry')
    if (app.flathub !== undefined && (typeof app.flathub !== 'string' || !APP_ID.test(app.flathub))) throw new Error(`Invalid Flathub alias for ${app.id}`)
    ids.add(app.id)
    const source = app.source as AppSource
    // A Craft release is always the app's own repository's asset, so it names nothing but its package.
    if (!source || (source.kind === 'apt' ? !strings(source.packages) || !source.packages.length || source.packages.some(p => !identifier.test(p)) : source.kind === 'release' ? source.package !== app.id || !/^[a-z]+craft$/.test(app.id) : source.kind === 'game' ? !game(app, source) : true)) throw new Error(`Invalid source for ${app.id}`)
  }
  return data
}
export function loadCatalog(): CatalogData {
  return parseCatalog(JSON.parse(readFileSync(new URL('../../../guest/catalog/catalog.json', import.meta.url), 'utf8')))
}
