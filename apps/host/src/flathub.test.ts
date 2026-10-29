import { mkdtempSync, rmSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { FlathubIndex, parseHit, relevance, type Fetcher } from './flathub.js'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })
const root = () => { const dir = mkdtempSync(join(tmpdir(), 'caboose-flathub-')); roots.push(dir); return dir }

export function hit(appId: string, overrides: Record<string, unknown> = {}) {
  return { app_id: appId, name: appId.split('.').pop(), summary: `About ${appId}`, type: 'desktop-application', arches: ['x86_64', 'aarch64'],
    icon: `https://dl.flathub.org/media/${appId.replaceAll('.', '/')}/abc/icons/128x128/${appId}.png`, runtime: 'org.gnome.Platform/x86_64/49',
    main_categories: 'graphics', sub_categories: [], keywords: ['Paint'], installs_last_month: 10, developer_name: 'Someone', project_license: 'GPL-3.0+', verification_verified: true, ...overrides }
}
const PNG = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex')
function fetcher(pages: unknown[][], icons: Record<string, Buffer> = {}) {
  return vi.fn(async (url: string, init?: { body?: string }) => {
    if (url === 'https://flathub.org/api/v2/search') {
      const page = JSON.parse(init!.body!).page as number
      return new Response(JSON.stringify({ hits: pages[page - 1] ?? [], totalPages: pages.length }))
    }
    const bytes = icons[url]
    return bytes ? new Response(new Uint8Array(bytes)) : new Response(null, { status: 404 })
  }) satisfies Fetcher
}
const many = (count: number, prefix = 'org.example.App') => Array.from({ length: count }, (_, i) => hit(`${prefix}${i}`, { installs_last_month: i }))

describe('Flathub hits', () => {
  it('keeps validated desktop apps for the architecture and maps their categories', () => {
    expect(parseHit(hit('org.gimp.GIMP', { sub_categories: ['RasterGraphics'] }), 'x86_64')).toMatchObject({ appId: 'org.gimp.GIMP', categories: ['Create'], runtime: 'org.gnome.Platform/x86_64/49', verified: true, keywords: ['paint'] })
    expect(parseHit(hit('org.kicad.KiCad', { main_categories: 'science', sub_categories: ['Engineering'] }), 'aarch64')).toMatchObject({ categories: ['Make', 'Science'], runtime: 'org.gnome.Platform/aarch64/49' })
    expect(parseHit(hit('org.example.Tool', { main_categories: 'nonsense' }), 'x86_64')?.categories).toEqual(['Utilities'])
    for (const bad of [{ app_id: '../etc' }, { icon: 'https://evil.example/icon.png' }, { type: 'console-application' }, { arches: ['x86_64'] }, { runtime: 'x; rm -rf /' }, { name: '' }]) {
      expect(parseHit(hit('org.example.Bad', bad), bad.arches ? 'aarch64' : 'x86_64')).toBeNull()
    }
  })
  it('requires every word of a query and prefers names', () => {
    const gimp = parseHit(hit('org.gimp.GIMP', { name: 'GNU Image Manipulation Program', summary: 'Create images and edit photographs' }), 'x86_64')!
    expect(relevance(gimp, ['gimp'])).toBeGreaterThan(0)
    expect(relevance(gimp, ['image'])).toBeGreaterThan(relevance(gimp, ['photographs']))
    expect(relevance(gimp, ['image', 'spreadsheet'])).toBe(0)
  })
})

describe('Flathub index', () => {
  it('fetches every page once, ranks by installs, and serves later starts from its cache', async () => {
    const dir = root(), fetch = fetcher([many(150), many(10, 'org.other.App')])
    const index = new FlathubIndex(dir, 'x86_64', fetch)
    await index.ready()
    expect(index.size).toBe(160)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(index.search('', '')[0]!.appId).toBe('org.example.App149')
    expect(index.search('', 'Games')).toEqual([])
    expect(index.search('', '', new Set(['org.example.App149']))[0]!.appId).toBe('org.example.App148')
    const offline = vi.fn(async () => { throw new Error('offline') })
    const cached = new FlathubIndex(dir, 'x86_64', offline)
    await cached.ready()
    expect(cached.size).toBe(160)
    expect(offline).not.toHaveBeenCalled()
  })
  it('refuses a truncated answer and keeps what it had', async () => {
    const index = new FlathubIndex(root(), 'x86_64', fetcher([many(5)]))
    await expect(index.ready()).rejects.toThrow('too few')
    expect(index.size).toBe(0)
  })
  it('refuses an icon larger than the limit while it streams, and redirects', async () => {
    const { fetchBounded } = await import('./flathub.js')
    let pulled = 0
    const endless = new ReadableStream<Uint8Array>({ pull(controller) { pulled++; controller.enqueue(new Uint8Array(64 * 1024)) } })
    const fetch = vi.fn(async (_url: string, init?: { redirect?: string }) => { expect(init?.redirect).toBe('error'); return new Response(endless) })
    await expect(fetchBounded(fetch, 'https://dl.flathub.org/x.png', 512 * 1024)).rejects.toThrow('more than')
    expect(pulled).toBeLessThan(20)
  })
  it('caches PNG icons and rejects anything else', async () => {
    const dir = root(), good = hit('org.example.Good'), bad = hit('org.example.Bad')
    const index = new FlathubIndex(dir, 'x86_64', fetcher([[good, bad, ...many(120)]], { [good.icon]: PNG, [bad.icon]: Buffer.from('<svg/>') }))
    await index.ready()
    expect(await index.icon('org.example.Good')).toBe('data:image/png;base64,' + PNG.toString('base64'))
    expect(existsSync(join(dir, 'icons', 'org.example.Good.png'))).toBe(true)
    expect(await index.icon('org.example.Bad')).toBeNull()
    expect(await index.icon('org.unknown.App')).toBeNull()
  })
})
