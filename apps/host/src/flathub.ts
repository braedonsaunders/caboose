import { existsSync } from 'node:fs'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

/** The Library's display categories, in the order clients show them. */
export const CATEGORIES = ['Create', 'Video & Audio', 'Make', 'Productivity', 'Development', 'Games', 'Internet', 'Learn', 'Science', 'System', 'Utilities'] as const
export type Category = typeof CATEGORIES[number]

export interface FlathubApp {
  appId: string
  name: string
  summary: string
  developer: string | null
  license: string | null
  verified: boolean
  /** The 128-pixel icon on dl.flathub.org. */
  icon: string
  categories: Category[]
  keywords: string[]
  /** The runtime ref the stable branch builds against, as `id/arch/branch`. */
  runtime: string
  installs: number
}

export type Fetcher = (url: string, init?: { method?: string; headers?: Record<string, string>; body?: string; signal?: AbortSignal; redirect?: 'error' }) => Promise<{ ok: boolean; status: number; body: ReadableStream<Uint8Array> | null }>

/**
 * A response body of at most `max` bytes, read as it streams so a larger one is refused
 * before it is held; redirects are refused too, so only the named host answers.
 */
export async function fetchBounded(fetcher: Fetcher, url: string, max: number, init: { method?: string; headers?: Record<string, string>; body?: string; timeoutMs?: number } = {}): Promise<{ ok: boolean; status: number; bytes: Buffer }> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(new Error(`${new URL(url).host} did not answer in time`)), init.timeoutMs ?? 30_000)
  timer.unref()
  try {
    const { timeoutMs: _timeout, ...request } = init
    const response = await fetcher(url, { ...request, signal: controller.signal, redirect: 'error' })
    const chunks: Buffer[] = []
    let size = 0
    if (response.body) {
      for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
        size += chunk.byteLength
        if (size > max) { controller.abort(); throw new Error(`${new URL(url).host} sent more than ${max} bytes`) }
        chunks.push(Buffer.from(chunk))
      }
    }
    return { ok: response.ok, status: response.status, bytes: Buffer.concat(chunks) }
  } finally { clearTimeout(timer) }
}

const SEARCH = 'https://flathub.org/api/v2/search'
const PAGE = 250
const MAX_PAGES = 40
const REFRESH_MS = 24 * 3600_000
const RETRY_MS = 3600_000
const ICON_BYTES = 512 * 1024
const PAGE_BYTES = 16 * 1024 * 1024
export const APP_ID = /^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$/
const RUNTIME = /^[A-Za-z_][A-Za-z0-9_.-]{0,254}\/(x86_64|aarch64)\/[A-Za-z0-9_.-]{1,64}$/
const PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

const MAIN: Record<string, Category> = {
  graphics: 'Create', audiovideo: 'Video & Audio', office: 'Productivity', development: 'Development', game: 'Games',
  network: 'Internet', education: 'Learn', science: 'Science', system: 'System', utility: 'Utilities',
}
const MAKE = new Set(['Engineering', 'Electronics', '3DGraphics', 'Construction'])

const text = (value: unknown, max: number): string | null => typeof value === 'string' && value.trim() && !/[\x00-\x08\x0b-\x1f]/.test(value) ? value.trim().slice(0, max) : null

/** Validate one search hit from Flathub; anything unexpected is dropped, never passed on. */
export function parseHit(value: unknown, arch: 'x86_64' | 'aarch64'): FlathubApp | null {
  if (!value || typeof value !== 'object') return null
  const hit = value as Record<string, unknown>
  const appId = typeof hit.app_id === 'string' && hit.app_id.length <= 255 && APP_ID.test(hit.app_id) ? hit.app_id : null
  const name = text(hit.name, 160), summary = text(hit.summary, 500)
  const icon = typeof hit.icon === 'string' && hit.icon.length <= 500 && /^https:\/\/dl\.flathub\.org\/[A-Za-z0-9._~%/-]+\.png$/.test(hit.icon) ? hit.icon : null
  const runtime = typeof hit.runtime === 'string' && RUNTIME.test(hit.runtime) && hit.runtime.split('/')[1] === 'x86_64' ? hit.runtime : null
  const arches = Array.isArray(hit.arches) ? hit.arches : []
  if (!appId || !name || !summary || !icon || !runtime || hit.type !== 'desktop-application' || !arches.includes(arch)) return null
  const mains = (Array.isArray(hit.main_categories) ? hit.main_categories : [hit.main_categories]).filter((c): c is string => typeof c === 'string').map(c => c.toLowerCase())
  const subs = Array.isArray(hit.sub_categories) ? hit.sub_categories.filter((c): c is string => typeof c === 'string') : []
  const categories = [...new Set([...(subs.some(c => MAKE.has(c)) ? ['Make' as const] : []), ...mains.flatMap(c => MAIN[c] ? [MAIN[c]] : [])])]
  if (!categories.length) categories.push('Utilities')
  const keywords = (Array.isArray(hit.keywords) ? hit.keywords : []).flatMap(k => { const t = text(k, 60); return t ? [t.toLowerCase()] : [] }).slice(0, 24)
  const installs = Number.isSafeInteger(hit.installs_last_month) && (hit.installs_last_month as number) >= 0 ? hit.installs_last_month as number : 0
  return {
    appId, name, summary, developer: text(hit.developer_name, 160), license: text(hit.project_license, 200), verified: hit.verification_verified === true,
    // The search index reports the x86_64 runtime; the branch is the same on every architecture.
    icon, categories, keywords, runtime: arch === 'x86_64' ? runtime : runtime.replace('/x86_64/', '/aarch64/'), installs,
  }
}

function words(value: string): string[] { return value.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean) }

/** How well an app matches every word of a query; 0 when any word is missing. */
export function relevance(app: FlathubApp, query: string[]): number {
  const name = app.name.toLowerCase(), nameWords = words(app.name), id = app.appId.toLowerCase(), summary = app.summary.toLowerCase(), developer = (app.developer ?? '').toLowerCase()
  let score = 0
  for (const word of query) {
    const best = name === word ? 100 : nameWords.includes(word) ? 70 : nameWords.some(w => w.startsWith(word)) ? 50
      : app.keywords.includes(word) ? 30 : id.includes(word) ? 25 : summary.includes(word) ? 12 : developer.includes(word) ? 8 : 0
    if (!best) return 0
    score += best
  }
  const phrase = query.join(' ')
  if (name === phrase) score += 200
  else if (query.length > 1 && name.includes(phrase)) score += 40
  return score
}

/**
 * The host's copy of Flathub's desktop applications. It is refreshed daily from Flathub's
 * public search API and kept on disk, so the Library searches it without a computer running.
 */
export class FlathubIndex {
  private apps: FlathubApp[] = []
  private byId = new Map<string, FlathubApp>()
  private fetchedAt = 0
  private failedAt = 0
  private refreshing: Promise<void> | undefined
  private loading: Promise<void> | undefined
  private icons = new Map<string, Promise<string | null>>()
  constructor(private readonly root: string, readonly arch: 'x86_64' | 'aarch64', private readonly fetcher: Fetcher = fetch as unknown as Fetcher, private readonly now: () => number = Date.now) {}

  /** Loads the cached index, refreshing it first when there is none; a stale one refreshes in the background. */
  async ready(): Promise<void> {
    this.loading ??= this.load()
    await this.loading
    if (!this.apps.length) await this.refresh().catch(error => { if (!this.apps.length) throw error })
    else if (this.now() - this.fetchedAt > REFRESH_MS && this.now() - this.failedAt > RETRY_MS) void this.refresh().catch(error => console.error('Flathub index refresh failed:', error))
  }
  private async load(): Promise<void> {
    try {
      const raw = JSON.parse(await readFile(join(this.root, 'index.json'), 'utf8')) as { arch?: unknown; fetchedAt?: unknown; apps?: unknown }
      if (raw.arch !== this.arch || !Number.isSafeInteger(raw.fetchedAt) || !Array.isArray(raw.apps)) return
      // The cache is re-validated as strictly as a response.
      this.set(raw.apps.flatMap(app => { const parsed = parseCached(app); return parsed ? [parsed] : [] }), raw.fetchedAt as number)
    } catch { /* no cache yet */ }
  }
  private set(apps: FlathubApp[], fetchedAt: number): void {
    this.apps = apps.sort((a, b) => b.installs - a.installs || a.name.localeCompare(b.name))
    this.byId = new Map(apps.map(app => [app.appId, app]))
    this.fetchedAt = fetchedAt
  }
  refresh(): Promise<void> {
    this.refreshing ??= (async () => {
      try {
        const apps: FlathubApp[] = []
        let pages = 1
        for (let page = 1; page <= pages; page++) {
          const response = await fetchBounded(this.fetcher, SEARCH, PAGE_BYTES, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: '', hits_per_page: PAGE, page }) })
          if (!response.ok) throw new Error(`Flathub answered ${response.status}`)
          const body = JSON.parse(response.bytes.toString('utf8')) as { hits?: unknown; totalPages?: unknown }
          if (!Array.isArray(body.hits)) throw new Error('Flathub returned no results')
          if (page === 1) pages = Number.isSafeInteger(body.totalPages) ? Math.min(MAX_PAGES, Math.max(1, body.totalPages as number)) : 1
          for (const hit of body.hits) { const app = parseHit(hit, this.arch); if (app) apps.push(app) }
        }
        if (apps.length < 100) throw new Error('Flathub returned too few applications')
        const unique = [...new Map(apps.map(app => [app.appId, app])).values()]
        const fetchedAt = this.now()
        await mkdir(this.root, { recursive: true })
        const temporary = join(this.root, 'index.json.tmp')
        await writeFile(temporary, JSON.stringify({ arch: this.arch, fetchedAt, apps: unique }))
        await rename(temporary, join(this.root, 'index.json'))
        this.set(unique, fetchedAt)
      } catch (error) { this.failedAt = this.now(); throw error }
      finally { this.refreshing = undefined }
    })()
    return this.refreshing
  }
  get size(): number { return this.apps.length }
  get(appId: string): FlathubApp | undefined { return this.byId.get(appId) }
  /** Popular first; with a query, every word must match and relevance is weighted by popularity. */
  search(query: string, category: string, exclude: ReadonlySet<string> = new Set()): FlathubApp[] {
    const terms = words(query)
    const pool = this.apps.filter(app => !exclude.has(app.appId) && (!category || app.categories.includes(category as Category)))
    if (!terms.length) return pool
    return pool.flatMap(app => { const score = relevance(app, terms); return score ? [{ app, score: score * (1 + Math.log10(1 + app.installs) / 3) }] : [] })
      .sort((a, b) => b.score - a.score).map(item => item.app)
  }
  /** The app's icon as a PNG data URL, fetched once from Flathub and cached on disk. */
  icon(appId: string): Promise<string | null> {
    const app = this.byId.get(appId)
    if (!app) return Promise.resolve(null)
    let pending = this.icons.get(appId)
    if (!pending) {
      pending = this.fetchIcon(app)
      this.icons.set(appId, pending)
      // Failures are retried on a later listing; successes stay on disk, not in memory.
      void pending.finally(() => this.icons.delete(appId))
    }
    return pending
  }
  private async fetchIcon(app: FlathubApp): Promise<string | null> {
    const file = join(this.root, 'icons', `${app.appId}.png`)
    if (existsSync(file)) return 'data:image/png;base64,' + (await readFile(file)).toString('base64')
    try {
      const { ok, bytes } = await fetchBounded(this.fetcher, app.icon, ICON_BYTES, { timeoutMs: 15_000 })
      if (!ok || !PNG.every((byte, index) => bytes[index] === byte)) return null
      await mkdir(join(this.root, 'icons'), { recursive: true })
      await writeFile(file + '.tmp', bytes)
      await rename(file + '.tmp', file)
      return 'data:image/png;base64,' + bytes.toString('base64')
    } catch { return null }
  }
}

function parseCached(value: unknown): FlathubApp | null {
  if (!value || typeof value !== 'object') return null
  const app = value as Record<string, unknown>
  const strings = (v: unknown) => Array.isArray(v) && v.every(s => typeof s === 'string')
  if (typeof app.appId !== 'string' || !APP_ID.test(app.appId) || !text(app.name, 160) || !text(app.summary, 500) || typeof app.icon !== 'string' || !/^https:\/\/dl\.flathub\.org\//.test(app.icon)
    || typeof app.runtime !== 'string' || !RUNTIME.test(app.runtime) || !strings(app.categories) || !(app.categories as string[]).every(c => (CATEGORIES as readonly string[]).includes(c))
    || !strings(app.keywords) || !Number.isSafeInteger(app.installs) || typeof app.verified !== 'boolean') return null
  return { appId: app.appId, name: text(app.name, 160)!, summary: text(app.summary, 500)!, developer: text(app.developer, 160), license: text(app.license, 200), verified: app.verified,
    icon: app.icon, categories: app.categories as Category[], keywords: app.keywords as string[], runtime: app.runtime, installs: app.installs as number }
}
