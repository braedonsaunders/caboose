import { lstat, opendir, readFile, statfs } from 'node:fs/promises'
import { cpus, freemem, loadavg, platform, totalmem } from 'node:os'
import { join } from 'node:path'
import type { Capacity, Measurement, ResourceTotals, StorageCategory } from '../../../packages/capacity/types.js'
import type { ComputerState } from './lifecycle.js'
import { vmPaths } from './vm-paths.js'
import { administers, isOperator, type TenancyPrincipal } from './identity/routes.js'
export type { Capacity } from '../../../packages/capacity/types.js'
export const measured = (value: number): Measurement => Number.isFinite(value) && value >= 0 ? { value } : unavailable('Invalid measurement')
export const unavailable = (reason: string): Measurement => ({ value: null, reason })
const missingStorage = (reason: string): StorageCategory => ({ logicalBytes: unavailable(reason), allocatedBytes: unavailable(reason) })
export interface CapacityComputer {
  id: string; tenantId: string | null; state: ComputerState
  settings: { memoryMb: number; vcpus: number }
  activeResources: { memoryMb: number; vcpus: number } | null
}
export interface CapacityContext {
  computers(): CapacityComputer[]
  quotas(id: string): Promise<{ memoryMb: number | null; vcpus: number | null; diskGb: number | null } | null>
  queued(): number | null
  sampler: CapacitySampler
}

/** Authorization happens before quota lookup, sampling or scanning. No tenant response contains host measurements. */
export async function capacityFor(context: CapacityContext, principal: TenancyPrincipal | undefined, tenantId?: string): Promise<{ status: number; body: Capacity | { error: string } }> {
  if (!principal) return { status: 401, body: { error: 'unauthorized' } }
  if (principal.kind === 'phone') return { status: 403, body: { error: 'forbidden' } }
  if (tenantId ? !administers(principal, tenantId) : !isOperator(principal)) return { status: tenantId ? 404 : 403, body: { error: tenantId ? 'tenant not found' : 'Only the operator sees the host' } }
  const quotas = tenantId ? await context.quotas(tenantId) : null
  const computers = context.computers().filter(c => tenantId === undefined || c.tenantId === tenantId)
  const storage = await context.sampler.storage(computers.map(c => c.id))
  const counts: Capacity['counts'] = { total: computers.length, running: 0, parked: 0, frozen: 0, waking: 0, parking: 0, restarting: 0, error: 0, queued: unavailable('Queue membership is not exposed per tenant') }
  for (const c of computers) counts[c.state]++
  if (!tenantId) { const queued = context.queued(); counts.queued = queued === null ? unavailable('Runtime does not expose a queue') : measured(queued) }
  const allocated = totals(computers.map(c => c.settings))
  const running = totals(computers.filter(c => c.state === 'running').map(c => c.activeResources))
  const q = quotas && { memoryBytes: quotas.memoryMb === null ? null : quotas.memoryMb * 1024 ** 2, vcpus: quotas.vcpus, diskBytes: quotas.diskGb === null ? null : quotas.diskGb * 1024 ** 3 }
  const quotaDisk = sumMeasurements([storage.disks.allocatedBytes, storage.snapshots.allocatedBytes])
  const remaining = (limit: number | null, used: number | null): Measurement => limit === null ? unavailable('No quota') : used === null ? unavailable('Usage unavailable') : { value: limit - used }
  const headroom = q && { memoryBytes: remaining(q.memoryBytes, allocated.memoryBytes), vcpus: remaining(q.vcpus, allocated.vcpus), diskBytes: remaining(q.diskBytes, quotaDisk.value) }
  const warnings: string[] = []
  if (headroom) for (const [key, m] of Object.entries(headroom)) if (m.value !== null && m.value <= 0) warnings.push(`${key} quota reached. Remove unused allocations or ask the operator to review the quota.`)
  if (counts.error) warnings.push('Computers have errors. Open Computers to inspect their status before retrying.')
  if (counts.queued.value) warnings.push('Computers are waiting for runtime capacity. Park an idle computer or review the host running limit.')
  const host = tenantId === undefined ? await context.sampler.host() : undefined
  if (host) {
    if (host.diskAvailableBytes.value !== null && host.diskTotalBytes.value && host.diskAvailableBytes.value / host.diskTotalBytes.value < .1) warnings.push('The image filesystem has less than 10% available. Review retained backups and snapshots or expand storage.')
    if (host.memoryAvailableBytes.value !== null && host.memoryTotalBytes.value && host.memoryAvailableBytes.value / host.memoryTotalBytes.value < .1) warnings.push('OS available memory is below 10%. Park idle computers and review host workloads.')
    if (host.memoryTotalBytes.value !== null && allocated.memoryBytes! > host.memoryTotalBytes.value) warnings.push('Assigned memory exceeds OS-visible memory. Not all computers may fit when running together.')
    if (host.cpuBusyPercent.value !== null && host.cpuBusyPercent.value > 90) warnings.push('Measured CPU busy time exceeds 90%. Review running workloads before waking more computers.')
  }
  return { status: 200, body: { sampledAt: new Date().toISOString(), scope: tenantId === undefined ? 'host' : 'tenant', allocated, running, counts, storage, quotas: q, headroom, ...(host ? { host } : {}), warnings } }
}
function totals(resources: Array<{ memoryMb: number; vcpus: number } | null>): ResourceTotals {
  if (resources.some(r => r === null)) return { memoryBytes: null, vcpus: null }
  return { memoryBytes: resources.reduce((n, r) => n + r!.memoryMb * 1024 ** 2, 0), vcpus: resources.reduce((n, r) => n + r!.vcpus, 0) }
}
function sumMeasurements(values: Measurement[]): Measurement {
  return values.find(m => m.value === null) ?? measured(values.reduce((n, m) => n + m.value!, 0))
}

/** Bounded traversal: no symlink following, hard-link inode deduplication, no partial totals on failure. */
export async function scanStorage(path: string, budget: { left: number; deadline: number }): Promise<StorageCategory> {
  let logical = 0, allocated = 0
  const seen = new Set<string>()
  async function walk(path: string, depth = 0): Promise<void> {
    if (--budget.left < 0 || Date.now() > budget.deadline || depth > 32) throw new Error('Storage scan limit reached')
    let info
    try { info = await lstat(path) } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT' && depth === 0) return; throw error }
    if (info.isSymbolicLink()) throw new Error('Symbolic link in storage')
    const key = `${info.dev}:${info.ino}`
    if (seen.has(key)) return
    seen.add(key)
    if (info.isDirectory()) {
      const dir = await opendir(path)
      for await (const entry of dir) await walk(join(path, entry.name), depth + 1)
    } else if (info.isFile()) { logical += info.size; allocated += info.blocks * 512 }
    else throw new Error('Unsupported storage entry')
  }
  try { await walk(path); return { logicalBytes: measured(logical), allocatedBytes: measured(allocated) } }
  catch { return missingStorage('Storage unreadable, changed during scan, or scan limit reached') }
}
export function linuxAvailableMemory(text: string): Measurement {
  const match = /^MemAvailable:\s+(\d+) kB$/m.exec(text)
  return match ? measured(Number(match[1]) * 1024) : unavailable('Kernel does not report MemAvailable')
}
export function cpuDelta(before: { idle: number; total: number }, after: { idle: number; total: number }): Measurement {
  const total = after.total - before.total, idle = after.idle - before.idle
  return total > 0 && idle >= 0 && idle <= total ? measured(100 * (total - idle) / total) : unavailable('CPU counters reset or did not advance')
}
function cpuCounters() {
  const list = cpus()
  return { count: list.length, idle: list.reduce((n, c) => n + c.times.idle, 0), total: list.reduce((n, c) => n + Object.values(c.times).reduce((a, b) => a + b, 0), 0) }
}

/** Request-driven sampling. No timers, guest commands, leases, or background scans. */
export class CapacitySampler {
  private files = new Map<string, { at: number; value: Promise<{ disks: StorageCategory; snapshots: StorageCategory; backups: StorageCategory }> }>()
  private hostCache: { at: number; value: Promise<NonNullable<Capacity['host']>> } | undefined
  private previousCpu: ReturnType<typeof cpuCounters> & { at: number } | undefined
  constructor(private readonly root: string | undefined, private readonly runtime: 'microvm' | 'container' | undefined) {}
  async storage(ids: string[]): Promise<Capacity['storage']> {
    // Sequential scan and a shared request budget bound fleet-wide work. Cache per computer, never by tenant permissions.
    const budget = { left: 4096, deadline: Date.now() + 2000 }
    const values: Array<{ disks: StorageCategory; snapshots: StorageCategory; backups: StorageCategory }> = []
    for (const id of ids) {
      let cached = this.files.get(id)
      if (!cached || Date.now() - cached.at > 60_000) {
        const value = this.computerStorage(id, budget)
        cached = { at: Date.now(), value }; this.files.set(id, cached)
      }
      values.push(await cached.value)
    }
    // Registry is bounded; also discard old entries for deleted computers.
    for (const [id, entry] of this.files) if (Date.now() - entry.at > 120_000) this.files.delete(id)
    const category = (key: 'disks' | 'snapshots' | 'backups'): StorageCategory => ({ logicalBytes: sumMeasurements(values.map(v => v[key].logicalBytes)), allocatedBytes: sumMeasurements(values.map(v => v[key].allocatedBytes)) })
    return { disks: category('disks'), snapshots: category('snapshots'), backups: category('backups'), uniquePhysicalBytes: unavailable('Reflink/shared extents cannot be attributed by summing file blocks') }
  }
  private async computerStorage(id: string, budget: { left: number; deadline: number }) {
    const unknown = missingStorage(this.runtime === 'container' ? 'Container volume storage is not measured' : 'Storage root is unavailable')
    if (!this.root || this.runtime !== 'microvm') return { disks: unknown, snapshots: unknown, backups: unknown }
    try {
      const paths = vmPaths(this.root, id)
      for (const directory of new Set([join(this.root, 'overlays'), paths.directory])) {
        try { if (!(await lstat(directory)).isDirectory()) return { disks: missingStorage('Storage directory is not a plain directory'), snapshots: missingStorage('Storage directory is not a plain directory'), backups: missingStorage('Storage directory is not a plain directory') } }
        catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
      }
      return { disks: await scanStorage(paths.disk, budget), snapshots: await scanStorage(paths.snapshot, budget), backups: await scanStorage(join(paths.directory, `${id}.backup`), budget) }
    } catch { return { disks: unknown, snapshots: unknown, backups: unknown } }
  }
  host(): Promise<NonNullable<Capacity['host']>> {
    if (!this.hostCache || Date.now() - this.hostCache.at >= 10_000) this.hostCache = { at: Date.now(), value: this.sampleHost() }
    return this.hostCache.value
  }
  private async sampleHost(): Promise<NonNullable<Capacity['host']>> {
    const at = Date.now(), cpu = cpuCounters(), previous = this.previousCpu
    this.previousCpu = { ...cpu, at }
    let memoryAvailableBytes = unavailable('Available memory is not measured on this OS; free memory excludes reclaimable caches')
    if (platform() === 'linux') try { memoryAvailableBytes = linuxAvailableMemory(await readFile('/proc/meminfo', 'utf8')) } catch { memoryAvailableBytes = unavailable('Cannot read kernel memory counters') }
    let diskTotalBytes = unavailable('Image filesystem is unavailable'), diskAvailableBytes = diskTotalBytes
    if (this.root) try { const fs = await statfs(this.root); diskTotalBytes = measured(fs.blocks * fs.bsize); diskAvailableBytes = measured(fs.bavail * fs.bsize) } catch {}
    return {
      memoryTotalBytes: measured(totalmem()), memoryFreeBytes: measured(freemem()), memoryAvailableBytes,
      cpuBusyPercent: previous && previous.count === cpu.count ? cpuDelta(previous, cpu) : unavailable('Requires two samples with the same CPU count'),
      cpuSampleMs: previous ? measured(at - previous.at) : unavailable('Requires two samples'), logicalCpus: measured(cpu.count),
      loadAverage1m: platform() === 'win32' ? unavailable('OS does not provide load average') : measured(loadavg()[0]!), diskTotalBytes, diskAvailableBytes,
    }
  }
}
