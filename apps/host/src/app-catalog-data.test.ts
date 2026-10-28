import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { loadCatalog, parseCatalog } from './app-catalog-data.js'

describe('application catalog', () => {
  it('loads the reviewed entries and their pack memberships', () => {
    const data = loadCatalog()
    expect(data.apps.filter(a => a.packs.includes('creative-studio'))).toHaveLength(13)
    expect(data.apps.find(a => a.id === 'gridcraft')?.source.kind).toBe('deb')
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
  it('keeps all release assets aligned with the reviewed checksums', () => {
    const releases = JSON.parse(readFileSync(new URL('../../../guest/catalog/craft-releases.json', import.meta.url), 'utf8')) as { releases: { id: string; version: string; sha256: string; size: number; url: string }[] }
    const entries = loadCatalog().apps.filter(app => app.source.kind === 'deb')
    expect(entries).toHaveLength(releases.releases.length)
    for (const release of releases.releases) {
      const source = entries.find(app => app.id === release.id)?.source
      expect(source).toMatchObject({ kind: 'deb', version: release.version, sha256: release.sha256, size: release.size, url: release.url })
    }
  })
  it('rejects malformed packages, URLs, duplicates and unknown packs', () => {
    for (const mutate of [
      (d: ReturnType<typeof loadCatalog>) => { d.apps[0]!.source = { kind: 'apt', packages: ['-y'] } },
      (d: ReturnType<typeof loadCatalog>) => { const source = d.apps[0]!.source; if (source.kind === 'deb') source.url = 'https://evil.example/file.deb' },
      (d: ReturnType<typeof loadCatalog>) => { d.apps.push(d.apps[0]!) },
      (d: ReturnType<typeof loadCatalog>) => { d.apps[0]!.packs = ['missing'] },
    ]) { const data = loadCatalog(); mutate(data); expect(() => parseCatalog(data)).toThrow() }
  })
})
