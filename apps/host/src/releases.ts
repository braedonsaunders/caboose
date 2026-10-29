import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { Fetcher } from './flathub.js'

/** A Craft release `.deb`, as its GitHub release describes it. */
export interface Release { version: string; url: string; sha256: string; size: number }

const FRESH_MS = 6 * 3600_000
const RETRY_MS = 15 * 60_000

/** The release asset Caboose installs for a Craft app at a version. */
export function releaseUrl(id: string, version: string, arch: 'x86_64' | 'aarch64' = 'x86_64'): string {
  return `https://github.com/storytold/${id}/releases/download/v${version}/${id}-${version}-linux-${arch}.deb`
}

/** Validate GitHub's latest-release answer; the asset's published SHA-256 is required. */
export function parseRelease(id: string, value: unknown, arch: 'x86_64' | 'aarch64' = 'x86_64'): Release | null {
  if (!value || typeof value !== 'object') return null
  const release = value as { tag_name?: unknown; draft?: unknown; prerelease?: unknown; assets?: unknown }
  if (release.draft === true || release.prerelease === true || typeof release.tag_name !== 'string') return null
  const version = /^v(\d+\.\d+\.\d+)$/.exec(release.tag_name)?.[1]
  if (!version || !Array.isArray(release.assets)) return null
  const name = `${id}-${version}-linux-${arch}.deb`
  const asset = release.assets.find(a => a && typeof a === 'object' && (a as { name?: unknown }).name === name) as { browser_download_url?: unknown; digest?: unknown; size?: unknown } | undefined
  if (!asset || asset.browser_download_url !== releaseUrl(id, version, arch)) return null
  const sha256 = typeof asset.digest === 'string' ? /^sha256:([a-f0-9]{64})$/.exec(asset.digest)?.[1] : undefined
  if (!sha256 || !Number.isSafeInteger(asset.size) || (asset.size as number) <= 0) return null
  return { version, url: releaseUrl(id, version, arch), sha256, size: asset.size as number }
}

/**
 * Follows each Craft app's latest GitHub release. Answers are cached on disk so a restart or
 * an unreachable GitHub still knows the last release seen; a release whose asset lacks a
 * published SHA-256 is never offered.
 */
export class CraftReleases {
  private cache = new Map<string, { release: Release | null; checkedAt: number }>()
  private loaded: Promise<void> | undefined
  private pending = new Map<string, Promise<Release | null>>()
  constructor(private readonly root: string, readonly arch: 'x86_64' | 'aarch64', private readonly fetcher: Fetcher = fetch as unknown as Fetcher, private readonly now: () => number = Date.now) {}
  private load(): Promise<void> {
    this.loaded ??= readFile(join(this.root, `releases-${this.arch}.json`), 'utf8').then(text => {
      const raw = JSON.parse(text) as Record<string, { release?: unknown; checkedAt?: unknown }>
      for (const [id, entry] of Object.entries(raw)) {
        const release = entry.release && typeof entry.release === 'object' ? entry.release as Release : null
        if (!/^[a-z0-9][a-z0-9-]*$/.test(id) || !Number.isSafeInteger(entry.checkedAt)) continue
        if (release && (!/^\d+\.\d+\.\d+$/.test(release.version) || release.url !== releaseUrl(id, release.version, this.arch) || !/^[a-f0-9]{64}$/.test(release.sha256) || !Number.isSafeInteger(release.size))) continue
        this.cache.set(id, { release, checkedAt: entry.checkedAt as number })
      }
    }).catch(() => {})
    return this.loaded
  }
  /** The last known release, without waiting for GitHub. */
  known(id: string): Release | null { return this.cache.get(id)?.release ?? null }
  /** The latest release; checks GitHub when the cached answer is old, else answers from the cache. */
  async latest(id: string, force = false): Promise<Release | null> {
    await this.load()
    const cached = this.cache.get(id)
    const age = cached ? this.now() - cached.checkedAt : Infinity
    if (cached && !force && (age < FRESH_MS || (!cached.release && age < RETRY_MS))) return cached.release
    let pending = this.pending.get(id)
    if (!pending) {
      pending = this.check(id).finally(() => this.pending.delete(id))
      this.pending.set(id, pending)
    }
    try { return await pending } catch (error) {
      if (cached?.release) return cached.release
      throw error
    }
  }
  private async check(id: string): Promise<Release | null> {
    const response = await this.fetcher(`https://api.github.com/repos/storytold/${id}/releases/latest`, { headers: { accept: 'application/vnd.github+json', 'user-agent': 'caboose-host' }, signal: AbortSignal.timeout(20_000) })
    if (!response.ok && response.status !== 404) throw new Error(`GitHub answered ${response.status} for ${id}`)
    const release = response.ok ? parseRelease(id, await response.json(), this.arch) : null
    const previous = this.cache.get(id)?.release
    // A newer tag without a verifiable asset keeps the last verified release on offer.
    this.cache.set(id, { release: release ?? previous ?? null, checkedAt: this.now() })
    await mkdir(this.root, { recursive: true })
    const file = join(this.root, `releases-${this.arch}.json`)
    await writeFile(file + '.tmp', JSON.stringify(Object.fromEntries(this.cache)))
    await rename(file + '.tmp', file)
    return release ?? previous ?? null
  }
}
