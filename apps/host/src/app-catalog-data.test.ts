import { readFileSync, readdirSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { loadCatalog, parseCatalog, type GameSource } from './app-catalog-data.js'
import { catalogIcon } from './app-catalog.js'

describe('application catalog', () => {
  it('follows each Craft app\'s own releases and gives curated Debian apps their Flathub identity', () => {
    const apps = loadCatalog().apps
    for (const app of apps.filter(app => app.source.kind === 'release')) expect(app.source).toEqual({ kind: 'release', package: app.id })
    expect(apps.find(app => app.id === 'gimp')?.flathub).toBe('org.gimp.GIMP')
    expect(apps.filter(app => app.source.kind === 'apt').every(app => app.flathub)).toBe(true)
  })
  it('loads the reviewed entries in the Library\'s categories', () => {
    const data = loadCatalog()
    expect(data.apps.filter(a => a.source.kind === 'release')).toHaveLength(13)
    expect(data.apps.find(a => a.id === 'wordcraft')?.category).toBe('Productivity')
    expect(data.apps.find(a => a.id === 'gridcraft')?.source.kind).toBe('release')
    expect(data.apps.find(a => a.id === 'gimp')?.source).toEqual({ kind: 'apt', packages: ['gimp'] })
  })
  it('pins The Powder Toy as a game in Games, with the bundle Caboose ships for it', () => {
    const game = loadCatalog().apps.find(app => app.id === 'powder-toy')!
    expect(game).toMatchObject({ category: 'Games', icon: 'uk.co.powdertoy.tpt', desktopId: 'uk.co.powdertoy.tpt.desktop', flathub: 'uk.co.powdertoy.tpt' })
    const release = 'https://github.com/The-Powder-Toy/The-Powder-Toy/releases/download/v100.1.400/powder-v100.1.400'
    expect(game.source).toEqual({
      kind: 'game', bundle: 'powder-toy', version: '100.1.400', url: `${release}-wasm32-emscripten-emscripten.tar`, size: 9666560,
      sha256: '55143cc3f9b01e4d950841983079f9040cd105f5816f6af7f4f8d5ab9608dbb6',
      native: {
        x86_64: { url: `${release}-x86_64-linux-gnu`, size: 7671200, sha256: '5e28b1c911e8bb0c5fe42d50c33880c7db9fca3cdf098facb09e0afb7731d499' },
        aarch64: { url: `${release}-aarch64-linux-gnu`, size: 6714136, sha256: '4e7295c81078273d4e2b1f807213ae4c6973a0d7a1e367373856602b2a12a3cc' },
      },
    })
    const bundle = new URL('../../../guest/game/games/powder-toy/', import.meta.url)
    const manifest = JSON.parse(readFileSync(new URL('caboose-game.json', bundle), 'utf8')) as { app_id: string; native_fallback: string[] }
    expect(`${manifest.app_id}.desktop`).toBe(game.desktopId)
    expect(manifest.app_id).toBe(game.icon)
    expect(manifest.native_fallback[0]).toBe('native/powder')
    expect(readFileSync(new URL('icon.png', bundle))).toEqual(readFileSync(new URL('../../../guest/catalog/icons/powder-toy.png', import.meta.url)))
    const shipped = JSON.parse(readFileSync(new URL('../../../guest/components/manifest.json', import.meta.url), 'utf8')) as string[]
    for (const file of ['caboose-game.json', 'web/index.html', 'icon.png', 'icon-license.txt']) expect(shipped).toContain(`game/games/powder-toy/${file}`)
    expect(shipped).toContain('game/caboose-game-run')
  })
  it('records verified native projects and camera raw associations', () => {
    const apps = loadCatalog().apps
    const types = (id: string) => apps.find(app => app.id === id)!.fileTypes.extensions
    expect(types('vectorcraft')).toContain('ai')
    expect(types('filmcraft')).toContain('fcproj')
    expect(types('soundcraft')).toContain('scraft')
    expect(types('lightcraft')).toEqual(expect.arrayContaining(['cr2', 'cr3', 'arw', 'nef', 'raf', 'rw2', 'rwl', 'pef', 'orf']))
  })
  it('gives every app a 128-pixel PNG icon with its licence, and keeps no other icons', () => {
    const apps = loadCatalog().apps
    const files = readdirSync(new URL('../../../guest/catalog/icons/', import.meta.url))
    for (const app of apps) {
      const png = Buffer.from(catalogIcon(app.id)?.split(',')[1] ?? '', 'base64')
      expect(png.subarray(0, 8).toString('hex'), app.id).toBe('89504e470d0a1a0a')
      expect([png.readUInt32BE(16), png.readUInt32BE(20)], app.id).toEqual([128, 128])
      expect(files.some(file => file === `${app.id}.LICENSE.txt` || file === `${app.id}.MIT.txt`), `${app.id} licence`).toBe(true)
    }
    const ids = new Set(apps.map(app => app.id))
    expect(files.filter(file => !ids.has(file.split('.')[0]!))).toEqual([])
  })
  it('rejects malformed packages, release and game sources, aliases, duplicates and unknown categories', () => {
    for (const mutate of [
      (d: ReturnType<typeof loadCatalog>) => { d.apps[0]!.source = { kind: 'apt', packages: ['-y'] } },
      (d: ReturnType<typeof loadCatalog>) => { d.apps.find(app => app.id === 'photocraft')!.source = { kind: 'release', package: 'other' } },
      (d: ReturnType<typeof loadCatalog>) => { d.apps.find(app => app.id === 'gimp')!.source = { kind: 'release', package: 'gimp' } },
      (d: ReturnType<typeof loadCatalog>) => { d.apps.find(app => app.id === 'gimp')!.flathub = '../evil' },
      (d: ReturnType<typeof loadCatalog>) => { d.apps.push(d.apps[0]!) },
      (d: ReturnType<typeof loadCatalog>) => { d.apps[0]!.category = 'Office' },
      ...([
        { url: 'https://evil.example/powder.tar' },
        { url: 'https://github.com/a/b/releases/download/v1/../../../x' },
        { sha256: 'F'.repeat(64) },
        { size: 0 },
        { bundle: '../powder-toy' },
        { version: '1 2' },
        { version: 'v100' },
        { native: { amd64: { url: 'https://github.com/a/b/releases/download/v1/x', sha256: 'a'.repeat(64), size: 1 } } },
        { native: { aarch64: { url: 'https://github.com/a/b/releases/download/v1/x', sha256: 'a'.repeat(64), size: -1 } } },
        { native: [] },
      ] as Record<string, unknown>[]).map(change => (d: ReturnType<typeof loadCatalog>) => {
        const game = d.apps.find(app => app.source.kind === 'game')!
        game.source = { ...game.source, ...change } as GameSource
      }),
      (d: ReturnType<typeof loadCatalog>) => { d.apps.find(app => app.source.kind === 'game')!.desktopId = 'powder toy.desktop' },
      (d: ReturnType<typeof loadCatalog>) => { d.apps.find(app => app.source.kind === 'game')!.icon = '../icon' },
      (d: ReturnType<typeof loadCatalog>) => { d.apps[0]!.source = { kind: 'flatpak', appId: 'org.example.App', runtime: 'org.freedesktop.Platform/x86_64/25.08' } },
    ]) { const data = loadCatalog(); mutate(data); expect(() => parseCatalog(data)).toThrow() }
  })
})
