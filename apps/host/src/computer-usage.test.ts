import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { afterEach, expect, it } from 'vitest'
import { mkdtemp, mkdir, rm, readFile, writeFile, symlink, open } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { accumulate, UsageHistory, WINDOW, type History } from './computer-usage.js'
import { allocatedVolume, dockerCounters, dockerEndpointSelection, VOLUME_SCAN_SCRIPT } from './container-usage.js'
import type { UsageCounters } from '../../../packages/capacity/types.js'
const dirs: string[] = []
afterEach(async () => { for (const dir of dirs.splice(0)) await rm(dir, { recursive: true, force: true }) })
const temp = async () => { const d = await mkdtemp(join(tmpdir(), 'usage-')); dirs.push(d); return d }
const sample = (at: number, cpuSeconds = 0, identity = 'a'): UsageCounters => ({ at, cpuSeconds, identity, vcpus: 2, memoryBytes: 123, cacheBytes: 10, memoryLimitBytes: 1000, memoryKind: 'cgroup' })
it('integrates CPU seconds, normalizes by active cores and splits hour boundaries', () => {
  const h: History = { since: 3590000, buckets: [] }
  expect(accumulate(h, sample(3590000, 5), sample(3650000, 65), 3650000)).toBe(50)
  expect(h.buckets).toEqual([{ at: 0, seconds: 10, coveredMs: 10000 }, { at: 3600000, seconds: 50, coveredMs: 50000 }])
})
it('excludes gaps, identity changes, negative deltas, time reversal and resource changes', () => {
  for (const next of [sample(200000, 40), sample(61000, 40, 'b'), sample(61000, 0), sample(500, 40), { ...sample(61000, 40), vcpus: 4 }]) {
    const h: History = { since: 0, buckets: [] }
    expect(accumulate(h, sample(1000, 1), next, next.at)).toBeNull()
    expect(h.buckets).toEqual([])
  }
})
it('bounds rolling history and never bridges a host restart or failed sample', async () => {
  const file = join(await temp(), 'history.json'), at = Date.now()
  const first = new UsageHistory(file)
  await first.record('a', sample(at), at)
  await first.record('a', sample(at + 60000, 60), at + 60000)
  await first.save(['a'])
  const second = new UsageHistory(file)
  await second.record('a', sample(at + 120000, 1000), at + 120000)
  expect(second.get('a').cpuSeconds30d).toBe(60)
  expect(second.get('a').cpuPercent).toBeNull()
  await second.record('a', null, at + 180000)
  await second.record('a', sample(at + 240000, 2000), at + 240000)
  expect(second.get('a').cpuSeconds30d).toBe(60)
  await second.record('a', sample(at + WINDOW + 3600000, 3000), at + WINDOW + 3600000)
  expect(second.get('a').cpuSeconds30d).toBe(0)
  await second.save([])
  expect(JSON.parse(await readFile(file, 'utf8')).entries).toEqual([])
})
it('handles corrupt history as new coverage', async () => {
  const file = join(await temp(), 'history.json')
  await writeFile(file, 'bad')
  const history = new UsageHistory(file), now = Date.now()
  await history.record('a', sample(now), now)
  expect(history.get('a').collectingSince).toBe(now)
  expect(history.get('a').coveredSeconds30d).toBe(0)
})
it('reads cgroup charges and cache without pretending cache is private resident RAM', () => {
  const info = { Id: 'a', State: { Running: true, StartedAt: 'boot1' }, HostConfig: { NanoCpus: 2e9, Memory: 1024 } }
  const stats = { id: 'a', cpu_stats: { cpu_usage: { total_usage: 15e9 } }, memory_stats: { usage: 700, stats: { inactive_file: 100 } } }
  expect(dockerCounters(info, stats, 123)).toMatchObject({ identity: 'a:boot1', cpuSeconds: 15, memoryBytes: 700, cacheBytes: 100, memoryLimitBytes: 1024, vcpus: 2 })
  expect(() => dockerCounters(info, { ...stats, id: 'replacement' })).toThrow()
  expect(() => dockerCounters(info, { ...stats, cpu_stats: {} })).toThrow()
})
it('measures sparse allocated blocks without following symlinks outside the volume', async () => {
  const dir = await temp(), file = await open(join(dir, 'sparse'), 'w')
  await file.truncate(1024 ** 3); await file.close()
  await symlink('/not/a/real/target', join(dir, 'link'))
  const result = await allocatedVolume(dir)
  expect(result.logicalBytes.value).toBeGreaterThanOrEqual(1024 ** 3)
  expect(result.allocatedBytes.value).toBeLessThan(1024 ** 3)
  await expect(allocatedVolume(join(dir, 'missing'))).rejects.toThrow()
  await expect(allocatedVolume(dir, 1)).rejects.toThrow()
})

it('retains at most 256 computer histories', async () => {
  const history = new UsageHistory(), now = Date.now()
  for (let i = 0; i < 257; i++) await history.record(String(i), sample(now), now)
  expect(history.get('256').reason).toContain('256 computers')
  await history.save(['256'])
  await history.record('256', sample(now), now)
  expect(history.get('256').memoryBytes).toBe(123)
})

it('uses Docker context ahead of an environment host override', () => {
  expect(dockerEndpointSelection({ DOCKER_CONTEXT: 'actual', DOCKER_HOST: 'unix:///wrong' })).toEqual({ args: ['context', 'inspect', 'actual', '--format', '{{.Endpoints.docker.Host}}'] })
  expect(dockerEndpointSelection({ DOCKER_HOST: 'unix:///actual' }).endpoint).toBe('unix:///actual')
  expect(dockerEndpointSelection({}).args).toContain('inspect')
})
it('rejects a directory swapped for an outside symlink between stat and open', async () => {
  const root = await temp(), outside = await temp()
  await mkdir(join(root, 'child')); await writeFile(join(outside, 'private'), 'outside')
  // Interpose exactly at the vulnerable boundary; the real worker still opens with NOFOLLOW.
  const attack = `
import os
original_open = os.open
def racing_open(path, flags, *args, **kwargs):
    if path == 'child':
        fd = kwargs['dir_fd']
        os.rename('child', 'moved', src_dir_fd=fd, dst_dir_fd=fd)
        os.symlink(${JSON.stringify(outside)}, 'child', dir_fd=fd)
    return original_open(path, flags, *args, **kwargs)
os.open = racing_open
`
  await expect(promisify(execFile)('python3', ['-I', '-c', attack + VOLUME_SCAN_SCRIPT, root, '100'], { timeout: 2000 })).rejects.toThrow()
  await expect(allocatedVolume(join(root, 'child'))).rejects.toThrow()
  expect(await readFile(join(outside, 'private'), 'utf8')).toBe('outside')
})
