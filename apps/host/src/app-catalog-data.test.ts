import { readdirSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { loadCatalog, parseCatalog } from './app-catalog-data.js'
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
  it('rejects malformed packages, release sources, aliases, duplicates and unknown categories', () => {
    for (const mutate of [
      (d: ReturnType<typeof loadCatalog>) => { d.apps[0]!.source = { kind: 'apt', packages: ['-y'] } },
      (d: ReturnType<typeof loadCatalog>) => { d.apps.find(app => app.id === 'photocraft')!.source = { kind: 'release', package: 'other' } },
      (d: ReturnType<typeof loadCatalog>) => { d.apps.find(app => app.id === 'gimp')!.source = { kind: 'release', package: 'gimp' } },
      (d: ReturnType<typeof loadCatalog>) => { d.apps.find(app => app.id === 'gimp')!.flathub = '../evil' },
      (d: ReturnType<typeof loadCatalog>) => { d.apps.push(d.apps[0]!) },
      (d: ReturnType<typeof loadCatalog>) => { d.apps[0]!.category = 'Office' },
    ]) { const data = loadCatalog(); mutate(data); expect(() => parseCatalog(data)).toThrow() }
  })
})
