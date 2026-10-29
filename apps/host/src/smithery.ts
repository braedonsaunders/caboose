import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdir, readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { fetchSafe, type SafeRequest, type SafeResponse } from './safe-fetch.js'

/**
 * Smithery's registry of MCP servers: the MCP Library's catalog. Only remote servers are
 * listed, since those are the ones Smithery Connect can host for a computer. Everything it
 * returns is untrusted and validated field by field.
 */
export const REGISTRY = 'https://registry.smithery.ai'
export const API = 'https://api.smithery.ai'

export interface McpServer {
  /** Smithery's qualified name, such as `brave` or `upstash/context7-mcp`. */
  id: string
  name: string
  description: string
  /** Smithery's count of uses, its measure of popularity. */
  uses: number
  verified: boolean
  /** Where the icon is, or null; served to clients only through /v1/mcp/icons. */
  iconUrl: string | null
  homepage: string | null
}
export interface McpServerDetail extends McpServer { tools: Array<{ name: string; description: string }> }
export type Requester = (url: string, max: number, init?: SafeRequest) => Promise<SafeResponse>

export const QUALIFIED = /^@?[a-zA-Z0-9][a-zA-Z0-9_-]{0,100}(?:\/[a-zA-Z0-9][a-zA-Z0-9_.-]{0,100})?$/
const text = (value: unknown, max: number): string | null => typeof value === 'string' && value.trim() && !/[\x00-\x08\x0b-\x1f\x7f]/.test(value) ? value.trim().slice(0, max) : null
const httpsUrl = (value: unknown): string | null => {
  if (typeof value !== 'string' || value.length > 500) return null
  try { const url = new URL(value); return url.protocol === 'https:' && !url.username && !url.password ? url.href : null } catch { return null }
}

/** One listing entry from Smithery, or null when anything about it is unexpected. */
export function parseServer(value: unknown): McpServer | null {
  if (!value || typeof value !== 'object') return null
  const raw = value as Record<string, unknown>
  const id = typeof raw.qualifiedName === 'string' && QUALIFIED.test(raw.qualifiedName) ? raw.qualifiedName : null
  const name = text(raw.displayName, 120) ?? (id ? id.split('/').pop()! : null)
  const description = text(raw.description, 600)
  if (!id || !name || !description || raw.remote !== true || raw.unlisted === true || raw.inactive === true) return null
  return { id, name, description, uses: Number.isSafeInteger(raw.useCount) && (raw.useCount as number) >= 0 ? raw.useCount as number : 0,
    verified: raw.verified === true, iconUrl: httpsUrl(raw.iconUrl), homepage: httpsUrl(raw.homepage) }
}

/** The topic rows of the front page: editorial groupings, each Smithery's search for it. */
export const TOPICS: ReadonlyArray<{ id: string; title: string; query: string }> = [
  { id: 'search', title: 'Search & Research', query: 'web search research' },
  { id: 'productivity', title: 'Productivity', query: 'email calendar documents notes' },
  { id: 'development', title: 'Development', query: 'github code developer tools' },
  { id: 'data', title: 'Data & Analytics', query: 'database analytics spreadsheets' },
]
const SHELF = 15
const POPULAR_PAGES = 5
const PAGE_BYTES = 4 * 1024 * 1024
const FRESH_MS = 6 * 3600_000
const ICON_BYTES = 256 * 1024
const ICON_SIDE = 1024
const ICON_BUDGET = 64 * 1024 * 1024
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

/** Width and height a PNG or JPEG declares, or null for anything else. */
export function imageSize(bytes: Buffer): { width: number; height: number } | null {
  if (bytes.length > 24 && bytes.subarray(0, 8).equals(PNG) && bytes.subarray(12, 16).toString('latin1') === 'IHDR') return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) }
  if (bytes.length > 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let at = 2
    while (at + 9 < bytes.length && bytes[at] === 0xff) {
      const marker = bytes[at + 1]!, length = bytes.readUInt16BE(at + 2)
      if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) return { width: bytes.readUInt16BE(at + 7), height: bytes.readUInt16BE(at + 5) }
      if (length < 2) return null
      at += 2 + length
    }
  }
  return null
}

type Rasterize = (svg: string) => Buffer | null
/** An SVG icon as a 128-pixel PNG. resvg loads nothing external and runs no scripts. */
async function defaultRasterize(): Promise<Rasterize> {
  const { Resvg } = await import('@resvg/resvg-js')
  return svg => {
    try { return new Resvg(svg, { fitTo: { mode: 'width', value: 128 }, font: { loadSystemFonts: false } }).render().asPng() } catch { return null }
  }
}

/**
 * The host's view of Smithery's catalog: the front page's rows cached on disk and in memory for
 * six hours, live search, and icons fetched once each into a bounded disk cache.
 */
export class SmitheryCatalog {
  private rows: { at: number; groups: Array<{ id: string; title: string; note: string | null; servers: McpServer[] }> } | null = null
  private loading: Promise<void> | undefined
  private icons = new Map<string, string>()
  private rasterize: Promise<Rasterize> | undefined
  constructor(private readonly root: string, private readonly request: Requester = fetchSafe, private readonly now: () => number = Date.now, rasterize?: Rasterize) {
    if (rasterize) this.rasterize = Promise.resolve(rasterize)
  }

  private async list(params: Record<string, string>): Promise<{ servers: McpServer[]; total: number }> {
    const query = new URLSearchParams({ remote: 'true', ...params })
    const response = await this.request(`${REGISTRY}/servers?${query}`, PAGE_BYTES, { headers: { accept: 'application/json' }, timeoutMs: 20_000 })
    if (response.status !== 200) throw new Error(`Smithery's registry answered ${response.status}`)
    const body = JSON.parse(response.body.toString('utf8')) as { servers?: unknown; pagination?: { totalCount?: unknown } }
    if (!Array.isArray(body.servers)) throw new Error("Smithery's registry sent no servers")
    const servers = body.servers.slice(0, 100).flatMap(value => { const server = parseServer(value); return server ? [server] : [] })
    const total = Number.isSafeInteger(body.pagination?.totalCount) ? Math.min(body.pagination!.totalCount as number, 100_000) : servers.length
    return { servers, total }
  }

  /** Popular by Smithery's use counts, Verified, then the topic rows. */
  async storefront() {
    if (!this.rows) await this.loadCache()
    if (!this.rows || this.now() - this.rows.at > FRESH_MS) {
      this.loading ??= this.refresh().finally(() => { this.loading = undefined })
      if (this.rows) void this.loading.catch(error => console.error('Smithery refresh failed:', error instanceof Error ? error.message : error))
      else await this.loading
    }
    return this.rows!.groups
  }
  private async refresh(): Promise<void> {
    const popular: McpServer[] = []
    for (let page = 1; page <= POPULAR_PAGES; page++) {
      const { servers } = await this.list({ page: String(page), pageSize: '100' })
      popular.push(...servers)
      if (servers.length < 100) break
    }
    const byUses = (servers: McpServer[]) => [...new Map(servers.map(server => [server.id, server])).values()].sort((a, b) => b.uses - a.uses || a.name.localeCompare(b.name))
    const verified = await this.list({ verified: 'true', pageSize: '100' })
    const groups: Array<{ id: string; title: string; note: string | null; servers: McpServer[] }> = [
      { id: 'popular', title: 'Popular', note: 'Ranked by uses on Smithery', servers: byUses(popular).slice(0, SHELF) },
      { id: 'verified', title: 'Verified', note: 'Publishers Smithery has verified', servers: byUses(verified.servers).slice(0, SHELF) },
    ]
    for (const topic of TOPICS) {
      const { servers } = await this.list({ q: topic.query, pageSize: '40' })
      if (servers.length) groups.push({ id: topic.id, title: topic.title, note: null, servers: byUses(servers).slice(0, SHELF) })
    }
    if (!groups[0]!.servers.length) throw new Error("Smithery's registry returned no servers")
    this.rows = { at: this.now(), groups }
    await mkdir(this.root, { recursive: true })
    await writeFile(join(this.root, 'storefront.json.tmp'), JSON.stringify(this.rows))
    await rename(join(this.root, 'storefront.json.tmp'), join(this.root, 'storefront.json'))
  }
  private async loadCache(): Promise<void> {
    const file = join(this.root, 'storefront.json')
    try {
      if ((await stat(file)).size > 2 * 1024 * 1024) return
      const raw = JSON.parse(await readFile(file, 'utf8')) as { at?: unknown; groups?: unknown }
      if (!Number.isSafeInteger(raw.at) || !Array.isArray(raw.groups)) return
      const groups = raw.groups.slice(0, 10).flatMap(value => {
        const group = value as { id?: unknown; title?: unknown; note?: unknown; servers?: unknown }
        if (typeof group.id !== 'string' || !/^[a-z-]{1,40}$/.test(group.id) || !text(group.title, 60) || !Array.isArray(group.servers)) return []
        const servers = group.servers.slice(0, SHELF).flatMap(server => {
          const s = server as Record<string, unknown>
          const parsed = parseServer({ qualifiedName: s.id, displayName: s.name, description: s.description, useCount: s.uses, verified: s.verified, iconUrl: s.iconUrl, homepage: s.homepage, remote: true })
          return parsed ? [parsed] : []
        })
        return [{ id: group.id, title: text(group.title, 60)!, note: text(group.note, 120), servers }]
      })
      if (groups.length) this.rows = { at: raw.at as number, groups }
    } catch { /* no cache yet */ }
  }

  /** Smithery's own full-text and semantic search, 40 at a time. */
  async search(query: string, page: number) {
    if (typeof query !== 'string' || query.length > 100 || /[\x00-\x1f]/.test(query)) throw new RangeError('Invalid search')
    if (!Number.isSafeInteger(page) || page < 1 || page > 250) throw new RangeError('Invalid page')
    const { servers, total } = await this.list({ ...(query.trim() ? { q: query.trim() } : {}), page: String(page), pageSize: '40' })
    return { servers, total, page, pageSize: 40 }
  }

  /** One server, with the tools Smithery lists for it. */
  async detail(id: string): Promise<McpServerDetail> {
    if (!QUALIFIED.test(id)) throw new RangeError('Invalid server')
    const response = await this.request(`${REGISTRY}/servers/${id.split('/').map(encodeURIComponent).join('/')}`, PAGE_BYTES, { headers: { accept: 'application/json' } })
    if (response.status === 404) throw new RangeError('Server not found')
    if (response.status !== 200) throw new Error(`Smithery's registry answered ${response.status}`)
    const raw = JSON.parse(response.body.toString('utf8')) as Record<string, unknown>
    const server = parseServer({ ...raw, useCount: raw.useCount ?? 0, verified: raw.verified })
    if (!server) throw new RangeError('Server not available through Smithery')
    const tools = (Array.isArray(raw.tools) ? raw.tools : []).slice(0, 200).flatMap(tool => {
      const t = tool as Record<string, unknown>
      const name = text(t.name, 120)
      return name ? [{ name, description: text(t.description, 400) ?? '' }] : []
    })
    return { ...server, tools }
  }

  /** The id under which a server's icon is served; its source never reaches a client. */
  iconId(url: string | null): string | null {
    if (!url) return null
    const id = createHash('sha256').update(url).digest('hex').slice(0, 32)
    this.icons.set(id, url)
    if (this.icons.size > 5000) this.icons.delete(this.icons.keys().next().value!)
    return id
  }

  /** A PNG or JPEG for an icon id this catalog handed out: cached, fetched once, or rasterized from SVG. */
  async icon(id: string): Promise<Buffer | null> {
    if (!/^[0-9a-f]{32}$/.test(id)) return null
    const file = join(this.root, 'icons', `${id}.png`)
    if (existsSync(file)) return readFile(file)
    const url = this.icons.get(id)
    if (!url) return null
    let png: Buffer | null = null
    try {
      const response = await this.request(url, ICON_BYTES, { timeoutMs: 10_000 })
      const type = String(response.headers['content-type'] ?? '').split(';')[0]!.trim()
      if (response.status !== 200) return null
      // A PNG or JPEG is kept as it is, if its declared size is sane: a small file can
      // declare a huge image. An SVG becomes a PNG here, so no client ever parses one.
      const size = imageSize(response.body)
      if (size) png = size.width > 0 && size.height > 0 && size.width <= ICON_SIDE && size.height <= ICON_SIDE ? response.body : null
      else if (type === 'image/svg+xml' || response.body.subarray(0, 512).toString('utf8').includes('<svg')) png = (await (this.rasterize ??= defaultRasterize()))(response.body.toString('utf8'))
    } catch { return null }
    if (!png) return null
    await mkdir(join(this.root, 'icons'), { recursive: true })
    await this.trimIcons(png.length)
    await writeFile(file + '.tmp', png)
    await rename(file + '.tmp', file)
    return png
  }
  /** Keeps the icon cache within its budget, oldest first. */
  private async trimIcons(adding: number): Promise<void> {
    const dir = join(this.root, 'icons')
    const files = await Promise.all((await readdir(dir).catch(() => [] as string[])).filter(name => name.endsWith('.png')).map(async name => ({ name, info: await stat(join(dir, name)).catch(() => null) })))
    let total = files.reduce((sum, file) => sum + (file.info?.size ?? 0), 0) + adding
    for (const file of files.sort((a, b) => (a.info?.mtimeMs ?? 0) - (b.info?.mtimeMs ?? 0))) {
      if (total <= ICON_BUDGET) break
      total -= file.info?.size ?? 0
      await rm(join(dir, file.name), { force: true })
    }
  }
}
