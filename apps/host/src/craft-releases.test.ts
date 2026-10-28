import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

// Research inputs are deliberately not wired to the host API or installer.
const manifest = JSON.parse(readFileSync(new URL('../../../guest/catalog/craft-releases.json', import.meta.url), 'utf8')) as {
  releases: { id: string; version: string; url: string; sha256: string; size: number }[]
}

describe('candidate Craft releases', () => {
  it('names a unique, immutable upstream amd64 deb for each pinned release', () => {
    expect(manifest.releases).toHaveLength(13)
    expect(new Set(manifest.releases.map(item => item.id)).size).toBe(13)
    for (const item of manifest.releases) {
      expect(item.id).toMatch(/^[a-z]+craft$/)
      expect(item.version).toMatch(/^\d+\.\d+\.\d+$/)
      expect(item.sha256).toMatch(/^[0-9a-f]{64}$/)
      expect(Number.isSafeInteger(item.size) && item.size > 0).toBe(true)
      expect(item.url).toBe(`https://github.com/storytold/${item.id}/releases/download/v${item.version}/${item.id}-${item.version}-linux-x86_64.deb`)
    }
  })
})
