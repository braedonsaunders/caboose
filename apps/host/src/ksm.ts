import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

export const DEFAULT_KSM_ROOT = '/sys/kernel/mm/ksm'
export const DEFAULT_PAGE_SIZE = 4096

export interface KsmSnapshot {
  run: 0 | 1 | 2
  active: boolean
  pagesShared: number
  pagesSharing: number
  pagesUnshared: number
  pagesVolatile: number
  fullScans: number
  sleepMillisecs: number
  pagesToScan: number
  pageSize: number
  savedBytes: number
  sharedBytes: number
}

export interface KsmBoostOptions {
  ksmRoot?: string
  boostPagesToScan?: number
  boostSleepMs?: number
  steadyPagesToScan?: number
  steadySleepMs?: number
  durationMs?: number
}

export interface SmapsRollup {
  rssBytes: number
  pssBytes: number
  sharedCleanBytes: number
  sharedDirtyBytes: number
  privateCleanBytes: number
  privateDirtyBytes: number
  swapPssBytes: number
  sharedBytes: number
  privateBytes: number
}

const KSM_METRIC_FILES = [
  'run',
  'pages_shared',
  'pages_sharing',
  'pages_unshared',
  'pages_volatile',
  'full_scans',
  'sleep_millisecs',
  'pages_to_scan',
] as const

const activeBoostTimers = new Map<string, ReturnType<typeof setTimeout>>()

function parseNonNegativeInt(raw: string | undefined): number {
  if (typeof raw !== 'string') return 0
  const trimmed = raw.trim()
  if (!/^\d+$/.test(trimmed)) return 0
  const parsed = Number(trimmed)
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0
}

/**
 * Pure parser for Linux `/sys/kernel/mm/ksm/*` counter files.
 * `savedBytes = pagesSharing * pageSize` is the physical RAM reclaimed across VMs by KSM.
 */
export function parseKsmMetrics(files: Record<string, string>, pageSize = DEFAULT_PAGE_SIZE): KsmSnapshot {
  const safePageSize = Number.isSafeInteger(pageSize) && pageSize > 0 ? pageSize : DEFAULT_PAGE_SIZE
  const rawRun = parseNonNegativeInt(files.run)
  const run: 0 | 1 | 2 = rawRun === 1 || rawRun === 2 ? rawRun : 0
  const pagesShared = parseNonNegativeInt(files.pages_shared)
  const pagesSharing = parseNonNegativeInt(files.pages_sharing)
  const pagesUnshared = parseNonNegativeInt(files.pages_unshared)
  const pagesVolatile = parseNonNegativeInt(files.pages_volatile)
  const fullScans = parseNonNegativeInt(files.full_scans)
  const sleepMillisecs = parseNonNegativeInt(files.sleep_millisecs)
  const pagesToScan = parseNonNegativeInt(files.pages_to_scan)
  return {
    run,
    active: run === 1,
    pagesShared,
    pagesSharing,
    pagesUnshared,
    pagesVolatile,
    fullScans,
    sleepMillisecs,
    pagesToScan,
    pageSize: safePageSize,
    savedBytes: pagesSharing * safePageSize,
    sharedBytes: pagesShared * safePageSize,
  }
}

/**
 * Reads `/sys/kernel/mm/ksm/*` and returns a snapshot, or `null` when KSM sysfs is absent or unreadable.
 */
export async function readKsmSnapshot(ksmRoot = DEFAULT_KSM_ROOT, pageSize = DEFAULT_PAGE_SIZE): Promise<KsmSnapshot | null> {
  try {
    const runRaw = await readFile(join(ksmRoot, 'run'), 'utf8')
    const trimmedRun = runRaw.trim()
    if (trimmedRun !== '0' && trimmedRun !== '1' && trimmedRun !== '2') return null
    const entries = await Promise.all(
      KSM_METRIC_FILES.map(async name => {
        if (name === 'run') return [name, runRaw] as const
        try {
          return [name, await readFile(join(ksmRoot, name), 'utf8')] as const
        } catch {
          return [name, '0'] as const
        }
      }),
    )
    return parseKsmMetrics(Object.fromEntries(entries), pageSize)
  } catch {
    return null
  }
}

/**
 * Event-driven KSM merge boost controller.
 * Temporarily increases KSM scan speed when a VM freezes or finishes waking/forking,
 * then throttles back to a low-CPU steady state after `durationMs`.
 * Gracefully no-ops when non-root or when `/sys/kernel/mm/ksm` is absent/read-only.
 */
export async function pulseKsmMergeBoost(options: KsmBoostOptions = {}): Promise<boolean> {
  const ksmRoot = options.ksmRoot ?? DEFAULT_KSM_ROOT
  const boostPagesToScan = options.boostPagesToScan ?? 4096
  const boostSleepMs = options.boostSleepMs ?? 20
  const steadyPagesToScan = options.steadyPagesToScan ?? 512
  const steadySleepMs = options.steadySleepMs ?? 100
  const durationMs = options.durationMs ?? 15_000

  try {
    await writeFile(join(ksmRoot, 'pages_to_scan'), `${boostPagesToScan}\n`, 'utf8')
    await writeFile(join(ksmRoot, 'sleep_millisecs'), `${boostSleepMs}\n`, 'utf8')
    await writeFile(join(ksmRoot, 'run'), '1\n', 'utf8')
  } catch {
    return false
  }

  const existing = activeBoostTimers.get(ksmRoot)
  if (existing) clearTimeout(existing)

  const timer = setTimeout(() => {
    activeBoostTimers.delete(ksmRoot)
    void (async () => {
      try {
        await writeFile(join(ksmRoot, 'pages_to_scan'), `${steadyPagesToScan}\n`, 'utf8')
        await writeFile(join(ksmRoot, 'sleep_millisecs'), `${steadySleepMs}\n`, 'utf8')
      } catch {
        // Ignore step-down errors if sysfs became unavailable.
      }
    })()
  }, Math.max(1, durationMs))
  timer.unref?.()
  activeBoostTimers.set(ksmRoot, timer)
  return true
}

/**
 * Parses Linux `/proc/<pid>/smaps_rollup` content into byte measurements.
 * Returns `null` if required `Rss:` or `Pss:` counters are absent.
 */
export function parseSmapsRollup(text: string): SmapsRollup | null {
  const readKb = (field: string): number | null => {
    const match = new RegExp(`^${field}:\\s+(\\d+)\\s+kB$`, 'm').exec(text)
    if (!match) return null
    const value = Number(match[1])
    return Number.isSafeInteger(value) && value >= 0 ? value * 1024 : null
  }
  const rssBytes = readKb('Rss')
  const pssBytes = readKb('Pss')
  if (rssBytes === null || pssBytes === null) return null

  const sharedCleanBytes = readKb('Shared_Clean') ?? 0
  const sharedDirtyBytes = readKb('Shared_Dirty') ?? 0
  const privateCleanBytes = readKb('Private_Clean') ?? 0
  const privateDirtyBytes = readKb('Private_Dirty') ?? 0
  const swapPssBytes = readKb('SwapPss') ?? 0

  return {
    rssBytes,
    pssBytes,
    sharedCleanBytes,
    sharedDirtyBytes,
    privateCleanBytes,
    privateDirtyBytes,
    swapPssBytes,
    sharedBytes: sharedCleanBytes + sharedDirtyBytes,
    privateBytes: privateCleanBytes + privateDirtyBytes,
  }
}

/**
 * Reads `/proc/<pid>/smaps_rollup` for a host process and parses its proportional and shared memory footprint.
 */
export async function readSmapsRollup(pid: number, procRoot = '/proc'): Promise<SmapsRollup | null> {
  if (!Number.isSafeInteger(pid) || pid <= 0) return null
  try {
    const content = await readFile(join(procRoot, String(pid), 'smaps_rollup'), 'utf8')
    return parseSmapsRollup(content)
  } catch {
    return null
  }
}
