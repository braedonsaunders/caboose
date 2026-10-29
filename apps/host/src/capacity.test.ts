import { afterEach, describe, expect, it, vi } from 'vitest'
import { mkdtemp, mkdir, open, rm, symlink, writeFile, lstat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { CapacitySampler, capacityFor, cpuDelta, linuxAvailableMemory, scanStorage, type CapacityContext } from './capacity.js'
import type { Capacity } from '../../../packages/capacity/types.js'
const admin = { kind: 'admin' as const, userId: 'a', name: 'A', email: 'a@example.test', operator: false, tenantIds: ['a'] }
const dirs: string[] = []
afterEach(async () => { vi.restoreAllMocks(); vi.useRealTimers(); for (const dir of dirs.splice(0)) await rm(dir, { recursive: true, force: true }) })
const temp = async () => { const dir = await mkdtemp(join(tmpdir(), 'capacity-')); dirs.push(dir); return dir }
function context(): CapacityContext {
  return { sampler: new CapacitySampler(undefined, 'container'), queued: () => 7, quotas: async () => ({ memoryMb: 1024, vcpus: 2, diskGb: 1 }), computers: () => [
    { id: 'a-computer', tenantId: 'a', state: 'running', settings: { memoryMb: 2048, vcpus: 4 }, activeResources: { memoryMb: 1024, vcpus: 2 } },
    { id: 'secret', tenantId: 'b', state: 'error', settings: { memoryMb: 9999, vcpus: 99 }, activeResources: null },
  ] }
}
describe('authorized capacity snapshots', () => {
  it('rejects before lookup, scan, or host probes', async () => {
    const c = context(), files = vi.spyOn(c.sampler, 'storage'), host = vi.spyOn(c.sampler, 'host'), quotas = vi.spyOn(c, 'quotas'), computers = vi.spyOn(c, 'computers')
    for (const [principal, tenant, status] of [[undefined, 'a', 401], [{ kind: 'phone' }, 'a', 403], [admin, 'b', 404], [admin, undefined, 403]] as const) expect((await capacityFor(c, principal, tenant)).status).toBe(status)
    expect(files).not.toHaveBeenCalled(); expect(host).not.toHaveBeenCalled(); expect(quotas).not.toHaveBeenCalled(); expect(computers).not.toHaveBeenCalled()
  })
  it('only scans owned computers and never exposes host or aggregate queue', async () => {
    const c = context(), files = vi.spyOn(c.sampler, 'storage'), host = vi.spyOn(c.sampler, 'host')
    const { body } = await capacityFor(c, admin, 'a'), data = body as Capacity
    expect(files).toHaveBeenCalledWith(['a-computer']); expect(host).not.toHaveBeenCalled()
    expect(data.host).toBeUndefined(); expect(JSON.stringify(data)).not.toContain('secret')
    expect(data.counts.total).toBe(1); expect(data.counts.error).toBe(0); expect(data.counts.queued.value).toBeNull()
    expect(data.allocated).toEqual({ memoryBytes: 2048 * 1024 ** 2, vcpus: 4 })
    expect(data.running).toEqual({ memoryBytes: 1024 ** 3, vcpus: 2 })
    expect(data.headroom?.memoryBytes.value).toBe(-(1024 ** 3))
    expect(data.storage.disks.allocatedBytes.value).toBeNull(); expect(data.headroom?.diskBytes.value).toBeNull()
  })
  it('reports unknown running resources and unlimited quotas without zeros', async () => {
    const c = context(); c.computers = () => [{ id: 'x', tenantId: 'a', state: 'running', settings: { memoryMb: 1, vcpus: 1 }, activeResources: null }]; c.quotas = async () => ({ memoryMb: null, vcpus: null, diskGb: null })
    const data = (await capacityFor(c, admin, 'a')).body as Capacity
    expect(data.running.memoryBytes).toBeNull(); expect(data.headroom?.vcpus).toEqual({ value: null, reason: 'No quota' })
  })
  it('operator gets host sampling, aggregate queue and actionable errors', async () => {
    const c = context(), data = (await capacityFor(c, { kind: 'owner' })).body as Capacity
    expect(data.scope).toBe('host'); expect(data.counts.queued.value).toBe(7); expect(data.counts.error).toBe(1)
    expect(data.host?.cpuBusyPercent.value).toBeNull(); expect(data.host?.diskAvailableBytes.value).toBeNull(); expect(data.warnings.length).toBeGreaterThan(0)
  })
})
it('distinguishes Linux available memory, CPU counter percentage, and invalid counters', () => {
  expect(linuxAvailableMemory('MemFree: 1 kB\nMemAvailable: 1234 kB\n').value).toBe(1234 * 1024)
  expect(linuxAvailableMemory('MemFree: 123 kB').value).toBeNull()
  expect(cpuDelta({ idle: 10, total: 100 }, { idle: 35, total: 200 }).value).toBe(75)
  expect(cpuDelta({ idle: 10, total: 100 }, { idle: 1, total: 1 }).value).toBeNull()
})
it('scans sparse logical bytes separately from allocated 512-byte blocks', async () => {
  const dir = await temp(), path = join(dir, 'sparse'); const file = await open(path, 'w'); await file.truncate(16 * 1024 ** 2); await file.close()
  const info = await lstat(path), usage = await scanStorage(path, { left: 10, deadline: Date.now() + 2000 })
  expect(usage.logicalBytes.value).toBe(info.size); expect(usage.allocatedBytes.value).toBe(info.blocks * 512)
})
it('does not follow symlinks or return partial totals after bounded scan failure', async () => {
  const dir = await temp(); await writeFile(join(dir, 'file'), 'data'); await symlink(join(dir, 'file'), join(dir, 'link'))
  expect((await scanStorage(dir, { left: 10, deadline: Date.now() + 2000 })).allocatedBytes.value).toBeNull()
  expect((await scanStorage(dir, { left: 0, deadline: Date.now() + 2000 })).logicalBytes.value).toBeNull()
  expect((await scanStorage(join(dir, 'absent'), { left: 1, deadline: Date.now() + 2000 })).allocatedBytes.value).toBe(0)
})
it('caches storage for sixty seconds and never sums it as unique physical bytes', async () => {
  const dir = await temp(); await mkdir(join(dir, 'overlays')); await writeFile(join(dir, 'overlays', 'owner.raw'), 'abc')
  const s = new CapacitySampler(dir, 'microvm'), a = await s.storage(['owner']); await writeFile(join(dir, 'overlays', 'owner.raw'), 'abcdef')
  expect((await s.storage(['owner'])).disks.logicalBytes.value).toBe(3); expect(a.uniquePhysicalBytes.value).toBeNull()
})
it('does not follow a symlinked overlays directory', async () => {
  const root = await temp(), external = await temp(); await writeFile(join(external, 'owner.raw'), 'private'); await symlink(external, join(root, 'overlays'))
  expect((await new CapacitySampler(root, 'microvm').storage(['owner'])).disks.logicalBytes.value).toBeNull()
})
it('coalesces request-driven host samples for ten seconds', async () => {
  const sampler = new CapacitySampler(undefined, 'container')
  const first = sampler.host(), second = sampler.host()
  expect(second).toBe(first)
  expect((await first).cpuSampleMs.value).toBeNull()
})
