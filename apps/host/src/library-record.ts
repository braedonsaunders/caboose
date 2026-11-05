import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

/**
 * A Debian application the Library found through AppStream: what the host needs to install it
 * again when the guest's own operation record is gone.
 */
export interface RecordedDebian { name: string; summary: string; desktopId: string; package: string; componentId: string; license: string | null }
/** One application the owner chose through the Library, kept by the host. */
export interface RecordedApp { id: string; debian?: RecordedDebian }

const ID = /^[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}$/
const PACKAGE = /^[a-z0-9][a-z0-9+.-]{0,99}$/
const DESKTOP = /^[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}\.desktop$/
const MAX = 500

function parseDebian(value: unknown): RecordedDebian | undefined {
  if (!value || typeof value !== 'object') return undefined
  const v = value as Record<string, unknown>
  if (typeof v.name !== 'string' || !v.name || v.name.length > 160 || typeof v.summary !== 'string' || !v.summary || v.summary.length > 500) return undefined
  if (typeof v.desktopId !== 'string' || !DESKTOP.test(v.desktopId) || typeof v.package !== 'string' || !PACKAGE.test(v.package)) return undefined
  if (typeof v.componentId !== 'string' || !ID.test(v.componentId) || (v.license !== null && (typeof v.license !== 'string' || v.license.length > 200))) return undefined
  return { name: v.name, summary: v.summary, desktopId: v.desktopId, package: v.package, componentId: v.componentId, license: v.license }
}

/** The record's applications from its file's contents; anything malformed is left out. */
export function parseRecord(text: string): RecordedApp[] {
  let raw: unknown
  try { raw = JSON.parse(text) } catch { return [] }
  const apps = raw && typeof raw === 'object' && Array.isArray((raw as { apps?: unknown }).apps) ? (raw as { apps: unknown[] }).apps : []
  const result = new Map<string, RecordedApp>()
  for (const value of apps.slice(0, MAX)) {
    if (!value || typeof value !== 'object') continue
    const { id, debian } = value as Record<string, unknown>
    if (typeof id !== 'string' || !ID.test(id)) continue
    const parsed = debian === undefined ? undefined : parseDebian(debian)
    if (debian !== undefined && !parsed) continue
    result.set(id, parsed ? { id, debian: parsed } : { id })
  }
  return [...result.values()]
}

/**
 * The applications the owner installed on one computer through the Library whose files live
 * in its root file system (Debian packages, Craft releases, games' desktop entries): Flathub
 * apps are kept by the computer's Flatpak volume. A container created again starts from its
 * image, so the host installs whatever on this list is missing (docs/architecture.md § Catalog).
 * Kept in the host's state for the computer, written whole and renamed into place.
 */
export class LibraryRecord {
  private apps = new Map<string, RecordedApp>()
  private loaded: Promise<void> | undefined
  private writing = Promise.resolve()
  constructor(private readonly file: string) {}

  private load(): Promise<void> {
    this.loaded ??= readFile(this.file, 'utf8').then(text => { for (const app of parseRecord(text)) this.apps.set(app.id, app) }, (error: NodeJS.ErrnoException) => {
      if (error.code !== 'ENOENT') console.error(`Cannot read ${this.file}:`, error.message)
    })
    return this.loaded
  }

  async list(): Promise<RecordedApp[]> { await this.load(); return [...this.apps.values()] }

  /** Adds or replaces an application; false when nothing changed. */
  async add(app: RecordedApp): Promise<boolean> {
    await this.load()
    const current = this.apps.get(app.id)
    if (current && JSON.stringify(current) === JSON.stringify(app)) return false
    if (!current && this.apps.size >= MAX) throw new Error(`The Library record keeps at most ${MAX} applications`)
    this.apps.set(app.id, app)
    await this.save()
    return true
  }

  async remove(id: string): Promise<void> {
    await this.load()
    if (this.apps.delete(id)) await this.save()
  }

  private save(): Promise<void> {
    const text = JSON.stringify({ apps: [...this.apps.values()] }, null, 2) + '\n'
    this.writing = this.writing.catch(() => {}).then(async () => {
      await mkdir(dirname(this.file), { recursive: true })
      await writeFile(this.file + '.tmp', text, { mode: 0o600 })
      await rename(this.file + '.tmp', this.file)
    })
    return this.writing
  }
}
