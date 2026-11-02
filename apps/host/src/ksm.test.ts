import { afterEach, describe, expect, it, vi } from 'vitest'
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  findProcessTelemetry,
  parseKsmMetrics,
  parseProcStat,
  parseSmapsRollup,
  pulseKsmMergeBoost,
  readCgroupSmapsRollup,
  readKsmSnapshot,
  readSmapsRollup,
  reclaimCgroupMemory,
} from './ksm.js'

const dirs: string[] = []

afterEach(async () => {
  vi.restoreAllMocks()
  vi.useRealTimers()
  for (const dir of dirs.splice(0)) {
    await chmod(dir, 0o700).catch(() => {})
    await rm(dir, { recursive: true, force: true })
  }
})

async function tempDir(prefix = 'ksm-'): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), prefix))
  dirs.push(dir)
  return dir
}

describe('KSM metrics parser and sysfs snapshot reader', () => {
  it('computes savedBytes, sharedBytes, and active status from KSM sysfs counters', () => {
    const snapshot = parseKsmMetrics(
      {
        run: '1\n',
        pages_shared: '1200\n',
        pages_sharing: '3600\n',
        pages_unshared: '450\n',
        pages_volatile: '80\n',
        full_scans: '14\n',
        sleep_millisecs: '20\n',
        pages_to_scan: '4096\n',
      },
      4096,
    )

    expect(snapshot).toEqual({
      run: 1,
      active: true,
      pagesShared: 1200,
      pagesSharing: 3600,
      pagesUnshared: 450,
      pagesVolatile: 80,
      fullScans: 14,
      sleepMillisecs: 20,
      pagesToScan: 4096,
      pageSize: 4096,
      savedBytes: 3600 * 4096,
      sharedBytes: 1200 * 4096,
    })
  })

  it('normalizes inactive or malformed KSM counter values safely', () => {
    const snapshot = parseKsmMetrics({
      run: '2',
      pages_shared: 'not-a-number',
      pages_sharing: '-5',
    })
    expect(snapshot.run).toBe(2)
    expect(snapshot.active).toBe(false)
    expect(snapshot.savedBytes).toBe(0)
    expect(snapshot.sharedBytes).toBe(0)
  })

  it('reads KSM snapshot from sysfs directory and returns null when absent', async () => {
    const root = await tempDir()
    const files: Record<string, string> = {
      run: '1\n',
      pages_shared: '256\n',
      pages_sharing: '1024\n',
      pages_unshared: '128\n',
      pages_volatile: '12\n',
      full_scans: '5\n',
      sleep_millisecs: '100\n',
      pages_to_scan: '512\n',
    }
    for (const [name, content] of Object.entries(files)) {
      await writeFile(join(root, name), content)
    }

    const snapshot = await readKsmSnapshot(root, 4096)
    expect(snapshot?.active).toBe(true)
    expect(snapshot?.savedBytes).toBe(1024 * 4096)
    expect(snapshot?.sharedBytes).toBe(256 * 4096)

    const missing = await readKsmSnapshot(join(root, 'missing-ksm'))
    expect(missing).toBeNull()
  })
})

describe('KSM event-driven scan-boost controller', () => {
  it('pulses scan rate upward and steps down after durationMs', async () => {
    vi.useFakeTimers()
    const root = await tempDir()
    for (const name of ['run', 'pages_to_scan', 'sleep_millisecs']) {
      await writeFile(join(root, name), '0\n')
    }

    const boosted = await pulseKsmMergeBoost({
      ksmRoot: root,
      boostPagesToScan: 4096,
      boostSleepMs: 20,
      steadyPagesToScan: 256,
      steadySleepMs: 500,
      durationMs: 15_000,
    })

    expect(boosted).toBe(true)
    expect((await readFile(join(root, 'run'), 'utf8')).trim()).toBe('1')
    expect((await readFile(join(root, 'pages_to_scan'), 'utf8')).trim()).toBe('4096')
    expect((await readFile(join(root, 'sleep_millisecs'), 'utf8')).trim()).toBe('20')

    await vi.advanceTimersByTimeAsync(15_000)

    expect((await readFile(join(root, 'pages_to_scan'), 'utf8')).trim()).toBe('256')
    expect((await readFile(join(root, 'sleep_millisecs'), 'utf8')).trim()).toBe('500')
  })

  it('gracefully no-ops when KSM sysfs is absent or unwritable', async () => {
    const root = await tempDir()
    const missing = await pulseKsmMergeBoost({ ksmRoot: join(root, 'missing', 'subpath') })
    expect(missing).toBe(false)
  })
})

describe('smaps_rollup parser and reader', () => {
  const sampleSmaps = [
    '55d9c7e00000-7fffd1234000 ---p 00000000 00:00 0                          [rollup]',
    'Rss:              524288 kB',
    'Pss:              180224 kB',
    'Pss_Anon:          65536 kB',
    'Pss_File:         114688 kB',
    'Shared_Clean:     360448 kB',
    'Shared_Dirty:      32768 kB',
    'Private_Clean:     65536 kB',
    'Private_Dirty:     65536 kB',
    'Swap:                  0 kB',
    'SwapPss:            4096 kB',
  ].join('\n')

  it('parses RSS, PSS, shared, private, and swapPss byte counters accurately', () => {
    const parsed = parseSmapsRollup(sampleSmaps)
    expect(parsed).toEqual({
      rssBytes: 524288 * 1024,
      pssBytes: 180224 * 1024,
      sharedCleanBytes: 360448 * 1024,
      sharedDirtyBytes: 32768 * 1024,
      privateCleanBytes: 65536 * 1024,
      privateDirtyBytes: 65536 * 1024,
      swapPssBytes: 4096 * 1024,
      sharedBytes: (360448 + 32768) * 1024,
      privateBytes: (65536 + 65536) * 1024,
    })
  })

  it('returns null when Rss or Pss is missing', () => {
    expect(parseSmapsRollup('Rss: 1024 kB\n')).toBeNull()
    expect(parseSmapsRollup('Pss: 1024 kB\n')).toBeNull()
    expect(parseSmapsRollup('')).toBeNull()
  })

  it('reads /proc/<pid>/smaps_rollup from an injectable procRoot', async () => {
    const procRoot = await tempDir('proc-')
    await mkdir(join(procRoot, '4242'), { recursive: true })
    await writeFile(join(procRoot, '4242', 'smaps_rollup'), sampleSmaps)

    const result = await readSmapsRollup(4242, procRoot)
    expect(result?.pssBytes).toBe(180224 * 1024)
    expect(result?.sharedBytes).toBe(393216 * 1024)
    expect(await readSmapsRollup(9999, procRoot)).toBeNull()
    expect(await readSmapsRollup(-1, procRoot)).toBeNull()
  })

  it('parses /proc/<pid>/stat and locates process telemetry across procRoot', async () => {
    const statLine = '4242 (cloud-hyperviso) S 1 4242 4242 0 -1 4194560 1200 0 10 0 250 150 0 0 20 0 8 0 987654 2147483648 131072 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 2 0 0 0 0 0'
    expect(parseProcStat(statLine, 100)).toEqual({
      pid: 4242,
      starttimeTicks: 987654,
      cpuSeconds: 4,
    })

    const procRoot = await tempDir('proc-find-')
    await mkdir(join(procRoot, '4242'), { recursive: true })
    await writeFile(join(procRoot, '4242', 'cmdline'), '/usr/bin/cloud-hypervisor\0--disk\0path=/var/lib/caboose/overlays/owner.raw\0')
    await writeFile(join(procRoot, '4242', 'stat'), statLine)
    await writeFile(join(procRoot, '4242', 'smaps_rollup'), sampleSmaps)

    const found = await findProcessTelemetry(args => args.some(arg => arg.includes('owner.raw')), procRoot)
    expect(found?.pid).toBe(4242)
    expect(found?.cpuSeconds).toBe(4)
    expect(found?.smaps.pssBytes).toBe(180224 * 1024)
    expect(found?.smaps.sharedBytes).toBe(393216 * 1024)
  })

  it('aggregates smaps_rollup across cgroup.procs and triggers cgroup memory.reclaim', async () => {
    const cgroupRoot = await tempDir('cgroup-')
    const procRoot = await tempDir('proc-cg-')
    const containerId = '00d9c8f9968a575c5863311ddf43a1cc04699d495533e0602a71221e5b094e8e'
    const scopeDir = join(cgroupRoot, 'system.slice', `docker-${containerId}.scope`)
    await mkdir(scopeDir, { recursive: true })
    await writeFile(join(scopeDir, 'cgroup.procs'), '1001\n1002\n')
    await writeFile(join(scopeDir, 'memory.current'), String(100 * 1024 * 1024) + '\n')
    await writeFile(join(scopeDir, 'memory.reclaim'), '0\n')

    await mkdir(join(procRoot, '1001'), { recursive: true })
    await mkdir(join(procRoot, '1002'), { recursive: true })
    await writeFile(join(procRoot, '1001', 'smaps_rollup'), sampleSmaps)
    await writeFile(join(procRoot, '1002', 'smaps_rollup'), sampleSmaps)

    const summed = await readCgroupSmapsRollup(containerId, undefined, cgroupRoot, procRoot)
    expect(summed?.pssBytes).toBe(2 * 180224 * 1024)
    expect(summed?.sharedBytes).toBe(2 * 393216 * 1024)

    const reclaimed = await reclaimCgroupMemory(containerId, 'park', cgroupRoot)
    expect(reclaimed).toBe(true)
    expect((await readFile(join(scopeDir, 'memory.reclaim'), 'utf8')).trim()).toBe(String(50 * 1024 * 1024))
  })
})
