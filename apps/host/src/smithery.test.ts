import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { imageSize, parseServer, SmitheryCatalog, type Requester } from './smithery.js'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })
const root = () => { const dir = mkdtempSync(join(tmpdir(), 'caboose-smithery-')); roots.push(dir); return dir }

export function listing(name: string, uses: number, overrides: Record<string, unknown> = {}) {
  return { qualifiedName: name, displayName: name[0]!.toUpperCase() + name.slice(1), description: `About ${name}`, iconUrl: `https://api.smithery.ai/servers/${name}/icon`, verified: false, useCount: uses, remote: true, homepage: 'https://example.com', ...overrides }
}
const answer = (body: unknown, status = 200, type = 'application/json') => ({ status, headers: { 'content-type': type }, body: Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body)) })
function png(width: number, height: number): Buffer {
  const bytes = Buffer.alloc(33)
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(bytes)
  bytes.writeUInt32BE(13, 8); bytes.write('IHDR', 12, 'latin1'); bytes.writeUInt32BE(width, 16); bytes.writeUInt32BE(height, 20)
  return bytes
}

describe('Smithery listings', () => {
  it('keeps only valid remote servers', () => {
    expect(parseServer(listing('brave', 87579))).toMatchObject({ id: 'brave', uses: 87579, iconUrl: 'https://api.smithery.ai/servers/brave/icon' })
    expect(parseServer(listing('upstash/context7-mcp', 5))?.id).toBe('upstash/context7-mcp')
    for (const bad of [{ remote: false }, { qualifiedName: '../etc' }, { description: '' }, { unlisted: true }, { qualifiedName: 'a/b/c' }]) expect(parseServer(listing('x', 1, bad))).toBeNull()
    expect(parseServer(listing('x', 1, { iconUrl: 'http://insecure.example/icon', useCount: -4 }))).toMatchObject({ iconUrl: null, uses: 0 })
  })
  it('reads the size a PNG or JPEG declares', () => {
    expect(imageSize(png(128, 64))).toEqual({ width: 128, height: 64 })
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x20, 0x00, 0x40, 0x03, 0, 0, 0])
    expect(imageSize(jpeg)).toEqual({ width: 64, height: 32 })
    expect(imageSize(Buffer.from('<svg/>'))).toBeNull()
  })
})

describe('the MCP Library catalog', () => {
  function requester(pages: Record<string, unknown>, icons: Record<string, ReturnType<typeof answer>> = {}) {
    const calls: string[] = []
    const request = vi.fn(async (url: string) => {
      calls.push(url)
      if (icons[url]) return icons[url]!
      const parsed = new URL(url)
      if (parsed.pathname === '/servers') {
        const key = parsed.searchParams.get('verified') ? 'verified' : parsed.searchParams.get('q') ?? `page${parsed.searchParams.get('page') ?? '1'}`
        return answer({ servers: pages[key] ?? [], pagination: { totalCount: 1000 } })
      }
      const detail = pages[`detail:${parsed.pathname.slice('/servers/'.length)}`]
      return detail ? answer(detail) : answer({ error: 'not found' }, 404)
    })
    return { request: request as unknown as Requester, calls }
  }
  it('ranks Popular by use counts, keeps it on disk, and lists topics', async () => {
    const dir = root()
    const { request, calls } = requester({ page1: [listing('low', 3), listing('high', 900), listing('mid', 40)], verified: [listing('brave', 87579, { verified: true })], 'web search research': [listing('exa', 9000)] })
    const catalog = new SmitheryCatalog(dir, request)
    const groups = await catalog.storefront()
    expect(groups[0]).toMatchObject({ id: 'popular', note: 'Ranked by uses on Smithery' })
    expect(groups[0]!.servers.map(s => s.id)).toEqual(['high', 'mid', 'low'])
    expect(groups.find(g => g.id === 'verified')?.servers[0]?.id).toBe('brave')
    expect(groups.find(g => g.id === 'search')?.servers[0]?.id).toBe('exa')
    expect(calls.every(url => url.startsWith('https://registry.smithery.ai/servers?remote=true'))).toBe(true)
    const offline = new SmitheryCatalog(dir, vi.fn(async () => { throw new Error('offline') }) as unknown as Requester)
    expect((await offline.storefront())[0]!.servers.map(s => s.id)).toEqual(['high', 'mid', 'low'])
    // See All pages a row in full: Popular from the ranked list, the rest from Smithery.
    expect(await offline.group('popular', 1)).toMatchObject({ total: 3, servers: [{ id: 'high' }, { id: 'mid' }, { id: 'low' }] })
    expect((await catalog.group('search', 1)).servers.map(s => s.id)).toEqual(['exa'])
    await expect(catalog.group('nonsense', 1)).rejects.toThrow('Unknown row')
  })
  it('searches Smithery and validates its arguments', async () => {
    const { request } = requester({ github: [listing('github', 6000)] })
    const catalog = new SmitheryCatalog(root(), request)
    expect((await catalog.search('github', 1)).servers.map(s => s.id)).toEqual(['github'])
    await expect(catalog.search('x'.repeat(101), 1)).rejects.toThrow('Invalid search')
    await expect(catalog.search('ok', 0)).rejects.toThrow('Invalid page')
    await expect(catalog.detail('../../etc')).rejects.toThrow('Invalid server')
  })
  it('serves icons it handed out, refusing oversized images and rasterizing SVG', async () => {
    const dir = root()
    const icons: Record<string, ReturnType<typeof answer>> = {
      'https://icons.example/ok.png': answer(png(128, 128), 200, 'image/png'),
      'https://icons.example/huge.png': answer(png(20000, 20000), 200, 'image/png'),
      'https://icons.example/logo.svg': answer('<svg xmlns="http://www.w3.org/2000/svg"/>', 200, 'image/svg+xml'),
      'https://icons.example/page.html': answer('<html></html>', 200, 'text/html'),
    }
    const { request } = requester({}, icons)
    const rasterize = vi.fn(() => png(128, 128))
    const catalog = new SmitheryCatalog(dir, request, Date.now, rasterize)
    const id = (url: string) => catalog.iconId(url)!
    expect(await catalog.icon(id('https://icons.example/ok.png'))).toEqual(png(128, 128))
    expect(await catalog.icon(id('https://icons.example/huge.png'))).toBeNull()
    expect(await catalog.icon(id('https://icons.example/logo.svg'))).toEqual(png(128, 128))
    expect(rasterize).toHaveBeenCalledOnce()
    expect(await catalog.icon(id('https://icons.example/page.html'))).toBeNull()
    expect(await catalog.icon('0'.repeat(32))).toBeNull()
    // Two requests for an icon not yet cached share one fetch and one write.
    const twin = id('https://icons.example/twin.png')
    icons['https://icons.example/twin.png'] = answer(png(64, 64), 200, 'image/png')
    const before = (request as unknown as { mock: { calls: unknown[] } }).mock.calls.length
    const [a, b] = await Promise.all([catalog.icon(twin), catalog.icon(twin)])
    expect(a).toEqual(png(64, 64)); expect(b).toEqual(png(64, 64))
    expect((request as unknown as { mock: { calls: unknown[] } }).mock.calls.length - before).toBe(1)
    expect(await catalog.icon('../../etc/passwd')).toBeNull()
  })
})
