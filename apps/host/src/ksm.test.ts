import { afterEach, describe, expect, it, vi } from 'vitest'
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  parseKsmMetrics,
  parseSmapsRollup,
  pulseKsmMergeBoost,
  readKsmSnapshot,
  readSmapsRollup,
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
    const snapshot = parseKsmMetrics({
      run: '1\n',
      pages_shared: '1200\n',
      pages_sharing: '8400\n',
      pages_unshared: '3500\n',
      pages_volatile: '150\n',
      full_scans: '42\n',
      sleep_millisecs: '20\n',
      pages_to_scan: '4096\n',
    }, 4096)

    expect(snapshot).toEqual({
      run: 1,
      active: true,
      pagesShared: 1200,
      pagesSharing: 8400,
      pagesUnshared: 3500,
      pagesVolatile: 150,
      fullScans: 42,
      sleepMillisecs: 20,
      pagesToScan: 4096,
      pageSize: 4096,
      savedBytes: 8400 * 4096,
      sharedBytes: 1200 * 4096,
    })
  })

  it('handles inactive or unmerging KSM states and malformed values safely', () => {
    const snapshot = parseKsmMetrics({
      run: '2',
      pages_shared: 'invalid',
      pages_sharing: '50',
    }, 4096)

    expect(snapshot.run).toBe(2)
    expect(snapshot.active).toBe(false)
    expect(snapshot.pagesShared).toBe(0)
    expect(snapshot.pagesSharing).toBe(50)
    expect(snapshot.savedBytes).toBe(50 * 4096)
  })

  it('reads a live KSM directory and returns null when KSM sysfs is absent', async () => {
    const root = await tempDir()
    await Promise.all([
      writeFile(join(root, 'run'), '1\n'),
      writeFile(join(root, 'pages_shared'), '256\n'),
      writeFile(join(root, 'pages_sharing'), '1024\n'),
      writeFile(join(root, 'pages_unshared'), '512\n'),
      writeFile(join(root, 'pages_volatile'), '12\n'),
      writeFile(join(root, 'full_scans'), '7\n'),
      writeFile(join(root, 'sleep_millisecs'), '100\n'),
      writeFile(join(root, 'pages_to_scan'), '512\n'),
    ])

    const snapshot = await readKsmSnapshot(root, 4096)
    expect(snapshot).not.toBeNull()
    expect(snapshot?.active).toBe(true)
    expect(snapshot?.savedBytes).toBe(1024 * 4096)
    expect(snapshot?.sharedBytes).toBe(256 * 4096)

    const missing = await readKsmSnapshot(join(root, 'nonexistent'))
    expect(missing).toBeNull()
  })
})

describe('event-driven KSM merge boost controller', () => {
  it('enables KSM at boost rate and steps down to steady state after durationMs', async () => {
    vi.useFakeTimers()
    const root = await tempDir()
    await Promise.all([
      writeFile(join(root, 'run'), '0\n'),
      writeFile(join(root, 'pages_to_scan'), '100\n'),
      writeFile(join(root, 'sleep_millisecs'), '200\n'),
    ])

    const boosted = await pulseKsmMergeBoost({
      ksmRoot: root,
      boostPagesToScan: 4096,
      boostSleepMs: 20,
      steadyPagesToScan: 512,
      steadySleepMs: 100,
      durationMs: 15_000,
    })
    expect(boosted).toBe(true)
    expect((await readFile(join(root, 'run'), 'utf8')).trim()).toBe('1')
    expect((await readFile(join(root, 'pages_to_scan'), 'utf8')).trim()).toBe('4096')
    expect((await readFile(join(root, 'sleep_millisecs'), 'utf8')).trim()).toBe('20')

    await vi.advanceTimersByTimeAsync(14_999)
    expect((await readFile(join(root, 'pages_to_scan'), 'utf8')).trim()).toBe('4096')

    await vi.advanceTimersByTimeAsync(1)
    await vi.waitFor(async () => {
      expect((await readFile(join(root, 'pages_to_scan'), 'utf8')).trim()).toBe('512')
      expect((await readFile(join(root, 'sleep_millisecs'), 'utf8')).trim()).toBe('100')
    })
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
})
