import { describe, expect, it } from 'vitest'
import { loadCatalog, parseCatalog } from './app-catalog-data.js'

describe('application catalog', () => {
  it('loads the reviewed entries and their pack memberships', () => {
    const data = loadCatalog()
    expect(data.apps.filter(a => a.packs.includes('creative-studio'))).toHaveLength(13)
    expect(data.apps.find(a => a.id === 'gridcraft')?.source.kind).toBe('deb')
    expect(data.apps.find(a => a.id === 'gimp')?.source).toEqual({ kind: 'apt', packages: ['gimp'] })
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
