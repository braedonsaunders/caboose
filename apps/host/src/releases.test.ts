import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { CraftReleases, parseRelease, releaseUrl } from './releases.js'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })
const root = () => { const dir = mkdtempSync(join(tmpdir(), 'caboose-releases-')); roots.push(dir); return dir }
const digest = 'b'.repeat(64)
function release(version: string, assets = [{ name: `photocraft-${version}-linux-x86_64.deb`, browser_download_url: releaseUrl('photocraft', version), digest: `sha256:${digest}`, size: 42 }]) {
  return { tag_name: `v${version}`, draft: false, prerelease: false, assets }
}
const answer = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status })

describe('Craft releases', () => {
  it('accepts only the app\'s own asset with a published SHA-256', () => {
    expect(parseRelease('photocraft', release('0.17.0'))).toEqual({ version: '0.17.0', url: releaseUrl('photocraft', '0.17.0'), sha256: digest, size: 42 })
    expect(parseRelease('photocraft', release('0.17.0', [{ name: 'photocraft-0.17.0-linux-aarch64.deb', browser_download_url: releaseUrl('photocraft', '0.17.0', 'aarch64'), digest: `sha256:${digest}`, size: 42 }]), 'aarch64')?.url).toContain('linux-aarch64.deb')
    expect(parseRelease('photocraft', release('0.17.0', [{ name: 'photocraft-0.17.0-linux-x86_64.deb', browser_download_url: releaseUrl('photocraft', '0.17.0'), digest: '', size: 42 }]))).toBeNull()
    expect(parseRelease('photocraft', release('0.17.0', [{ name: 'photocraft-0.17.0-linux-x86_64.deb', browser_download_url: 'https://evil.example/x.deb', digest: `sha256:${digest}`, size: 42 }]))).toBeNull()
    expect(parseRelease('photocraft', { ...release('0.17.0'), prerelease: true })).toBeNull()
    expect(parseRelease('photocraft', { ...release('0.17.0'), tag_name: 'nightly' })).toBeNull()
  })
  it('caches the latest release and keeps the last verified one when GitHub fails or regresses', async () => {
    let now = 0
    const dir = root()
    const fetch = vi.fn(async () => answer(release('0.17.0')))
    const releases = new CraftReleases(dir, 'x86_64', fetch, () => now)
    expect((await releases.latest('photocraft'))?.version).toBe('0.17.0')
    expect((await releases.latest('photocraft'))?.version).toBe('0.17.0')
    expect(fetch).toHaveBeenCalledOnce()
    fetch.mockImplementation(async () => answer(release('0.18.0', [])))
    expect((await releases.latest('photocraft', true))?.version).toBe('0.17.0')
    fetch.mockImplementation(async () => { throw new Error('offline') })
    now += 7 * 3600_000
    expect((await releases.latest('photocraft'))?.version).toBe('0.17.0')
    const restarted = new CraftReleases(dir, 'x86_64', vi.fn(async () => { throw new Error('offline') }), () => now)
    expect((await restarted.latest('photocraft'))?.version).toBe('0.17.0')
    expect(restarted.known('photocraft')?.version).toBe('0.17.0')
  })
})
