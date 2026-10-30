import { mkdir, readFile, rename, writeFile, stat } from 'node:fs/promises'
import { dirname } from 'node:path'
import type { ComputerUsage, UsageCounters } from '../../../packages/capacity/types.js'

export const WINDOW = 30 * 86400_000
const HOUR = 3600_000
const MAX_GAP = 150_000
export interface Bucket { at: number; seconds: number; coveredMs: number }
export interface History { since: number; buckets: Bucket[] }
/** Only adjacent, same-runtime counters contribute. Restart never bridges an unobserved interval. */
export function accumulate(history: History, previous: UsageCounters | undefined, next: UsageCounters, now: number): number | null {
  history.buckets = history.buckets.filter(b => b.at >= now - WINDOW)
  if (!previous || previous.identity !== next.identity || previous.vcpus !== next.vcpus || next.at <= previous.at || next.at - previous.at > MAX_GAP || next.cpuSeconds < previous.cpuSeconds) return null
  const elapsed = next.at - previous.at, delta = next.cpuSeconds - previous.cpuSeconds
  if (![elapsed, delta, next.vcpus].every(Number.isFinite) || next.vcpus <= 0) return null
  // Split intervals at hour boundaries; expiry drops the boundary hour conservatively.
  for (let start = previous.at; start < next.at;) {
    const at = Math.floor(start / HOUR) * HOUR, end = Math.min(next.at, at + HOUR)
    if (at >= now - WINDOW) {
      let bucket = history.buckets.find(b => b.at === at)
      if (!bucket) { bucket = { at, seconds: 0, coveredMs: 0 }; history.buckets.push(bucket) }
      bucket.seconds += delta * (end - start) / elapsed; bucket.coveredMs += end - start
    }
    start = end
  }
  return delta / (elapsed / 1000) / next.vcpus * 100
}

export class UsageHistory {
  private histories = new Map<string, History>()
  private previous = new Map<string, UsageCounters>()
  private current = new Map<string, ComputerUsage>()
  private ready: Promise<void>
  private writing: Promise<void> = Promise.resolve()
  constructor(private file?: string) { this.ready = this.load() }
  private async load() {
    if (!this.file) return
    try {
      if ((await stat(this.file)).size > 32 * 1024 * 1024) return
      const raw = await readFile(this.file, 'utf8')
      if (raw.length > 32 * 1024 * 1024) return
      const data = JSON.parse(raw)
      if (data.version !== 1 || !Array.isArray(data.entries) || data.entries.length > 256) return
      for (const [id, h] of data.entries) {
        if (typeof id !== 'string' || !Number.isFinite(h.since) || !Array.isArray(h.buckets) || h.buckets.length > 721) continue
        if (!h.buckets.every((b: Bucket) => [b.at, b.seconds, b.coveredMs].every(n => Number.isFinite(n) && n >= 0) && b.coveredMs <= HOUR)) continue
        this.histories.set(id, h)
      }
    } catch { /* Missing or corrupt telemetry is a coverage gap, never reconstructed usage. */ }
  }
  async record(id: string, sample: UsageCounters | null, now = Date.now(), reason = 'Runtime counters unavailable'): Promise<void> {
    await this.ready
    if (!this.histories.has(id) && this.histories.size >= 256) return
    const h = this.histories.get(id) ?? { since: now, buckets: [] }
    this.histories.set(id, h)
    h.buckets = h.buckets.filter(b => b.at >= now - WINDOW && b.at <= now)
    const percent = sample ? accumulate(h, this.previous.get(id), sample, now) : null
    if (sample) this.previous.set(id, sample); else this.previous.delete(id)
    this.current.set(id, {
      sampledAt: now, memoryBytes: sample?.memoryBytes ?? null, cacheBytes: sample?.cacheBytes ?? null,
      memoryLimitBytes: sample?.memoryLimitBytes ?? null, memoryKind: sample?.memoryKind ?? 'unavailable',
      cpuPercent: percent, cpuSeconds30d: h.buckets.reduce((n, b) => n + b.seconds, 0),
      coveredSeconds30d: h.buckets.reduce((n, b) => n + b.coveredMs / 1000, 0), collectingSince: h.since,
      reason: sample ? undefined : reason,
    })
  }
  get(id: string): ComputerUsage {
    const value = this.current.get(id)
    if (value && value.sampledAt !== null && Date.now() - value.sampledAt < MAX_GAP) return value
    const h = this.histories.get(id)
    const buckets = h?.buckets.filter(b => b.at >= Date.now() - WINDOW) ?? []
    return { sampledAt: value?.sampledAt ?? null, memoryBytes: null, cacheBytes: null, memoryLimitBytes: null, memoryKind: 'unavailable', cpuPercent: null,
      cpuSeconds30d: buckets.reduce((n, b) => n + b.seconds, 0), coveredSeconds30d: buckets.reduce((n, b) => n + b.coveredMs / 1000, 0), collectingSince: h?.since ?? null, reason: this.histories.size >= 256 && !h ? 'History limit of 256 computers reached' : 'Runtime counters unavailable or not yet sampled' }
  }
  async save(ids: string[]) {
    await this.ready
    const keep = new Set(ids)
    for (const id of this.histories.keys()) if (!keep.has(id)) { this.histories.delete(id); this.previous.delete(id); this.current.delete(id) }
    if (!this.file) return
    const contents = JSON.stringify({ version: 1, entries: [...this.histories] })
    const file = this.file
    this.writing = this.writing.catch(() => {}).then(async () => {
      await mkdir(dirname(file), { recursive: true })
      await writeFile(`${file}.tmp`, contents, { mode: 0o600 }); await rename(`${file}.tmp`, file)
    })
    await this.writing
  }
}
