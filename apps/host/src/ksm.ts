import { readdir, readFile, writeFile } from 'node:fs/promises'
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

export interface ProcStatTelemetry {
  pid: number
  starttimeTicks: number
  cpuSeconds: number
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
    pageSize,
    savedBytes: pagesSharing * safePageSize,
    sharedBytes: pagesShared * safePageSize,
  }
}

/**
 * Reads `/sys/kernel/mm/ksm/*` counters. Returns `null` when KSM sysfs is absent or unreadable.
 */
export async function readKsmSnapshot(ksmRoot = DEFAULT_KSM_ROOT, pageSize = DEFAULT_PAGE_SIZE): Promise<KsmSnapshot | null> {
  try {
    const [run, pagesShared, pagesSharing] = await Promise.all([
      readFile(join(ksmRoot, 'run'), 'utf8'),
      readFile(join(ksmRoot, 'pages_shared'), 'utf8'),
      readFile(join(ksmRoot, 'pages_sharing'), 'utf8'),
    ])
    const optional = await Promise.all(
      (['pages_unshared', 'pages_volatile', 'full_scans', 'sleep_millisecs', 'pages_to_scan'] as const).map(async name => {
        try {
          return [name, await readFile(join(ksmRoot, name), 'utf8')] as const
        } catch {
          return [name, '0'] as const
        }
      }),
    )
    return parseKsmMetrics(
      {
        run,
        pages_shared: pagesShared,
        pages_sharing: pagesSharing,
        ...Object.fromEntries(optional),
      },
      pageSize,
    )
  } catch {
    return null
  }
}

function clearBoostTimer(ksmRoot: string): void {
  const existing = activeBoostTimers.get(ksmRoot)
  if (existing) {
    clearTimeout(existing)
    activeBoostTimers.delete(ksmRoot)
  }
}

/**
 * Event-driven KSM scan-boost controller.
 * On VM wake, template fork, or freeze, raises `pages_to_scan` and lowers `sleep_millisecs`
 * (`run=1`) for `durationMs` so newly faulted/compacted identical pages merge quickly, then
 * steps down to a low steady background scan rate.
 */
export async function pulseKsmMergeBoost(options: KsmBoostOptions = {}): Promise<boolean> {
  const ksmRoot = options.ksmRoot ?? DEFAULT_KSM_ROOT
  const boostPagesToScan = options.boostPagesToScan ?? 4096
  const boostSleepMs = options.boostSleepMs ?? 20
  const steadyPagesToScan = options.steadyPagesToScan ?? 256
  const steadySleepMs = options.steadySleepMs ?? 500
  const durationMs = options.durationMs ?? 20_000

  try {
    await writeFile(join(ksmRoot, 'pages_to_scan'), `${boostPagesToScan}\n`, 'utf8')
    await writeFile(join(ksmRoot, 'sleep_millisecs'), `${boostSleepMs}\n`, 'utf8')
    await writeFile(join(ksmRoot, 'run'), '1\n', 'utf8')
  } catch {
    return false
  }

  clearBoostTimer(ksmRoot)
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

function candidateCgroupDirs(containerId: string, cgroupRoot = '/sys/fs/cgroup'): string[] {
  if (!/^[a-fA-F0-9]{12,128}$/.test(containerId)) return []
  return [
    join(cgroupRoot, 'system.slice', `docker-${containerId}.scope`),
    join(cgroupRoot, 'docker', containerId),
  ]
}

/**
 * Aggregates `/proc/<pid>/smaps_rollup` across all processes in a container's cgroup (`cgroup.procs`),
 * falling back to `fallbackPid` when the cgroup process list is unavailable.
 */
export async function readCgroupSmapsRollup(
  containerId: string,
  fallbackPid?: number,
  cgroupRoot = '/sys/fs/cgroup',
  procRoot = '/proc',
): Promise<SmapsRollup | null> {
  for (const dir of candidateCgroupDirs(containerId, cgroupRoot)) {
    try {
      const rawProcs = await readFile(join(dir, 'cgroup.procs'), 'utf8')
      const pids = rawProcs
        .split(/\s+/)
        .map(s => Number(s.trim()))
        .filter(n => Number.isSafeInteger(n) && n > 0)
      if (!pids.length) continue
      const rollups = (await Promise.all(pids.map(pid => readSmapsRollup(pid, procRoot)))).filter(
        (r): r is SmapsRollup => r !== null,
      )
      if (!rollups.length) continue
      return rollups.reduce<SmapsRollup>(
        (acc, r) => ({
          rssBytes: acc.rssBytes + r.rssBytes,
          pssBytes: acc.pssBytes + r.pssBytes,
          sharedCleanBytes: acc.sharedCleanBytes + r.sharedCleanBytes,
          sharedDirtyBytes: acc.sharedDirtyBytes + r.sharedDirtyBytes,
          privateCleanBytes: acc.privateCleanBytes + r.privateCleanBytes,
          privateDirtyBytes: acc.privateDirtyBytes + r.privateDirtyBytes,
          swapPssBytes: acc.swapPssBytes + r.swapPssBytes,
          sharedBytes: acc.sharedBytes + r.sharedBytes,
          privateBytes: acc.privateBytes + r.privateBytes,
        }),
        {
          rssBytes: 0,
          pssBytes: 0,
          sharedCleanBytes: 0,
          sharedDirtyBytes: 0,
          privateCleanBytes: 0,
          privateDirtyBytes: 0,
          swapPssBytes: 0,
          sharedBytes: 0,
          privateBytes: 0,
        },
      )
    } catch {
      continue
    }
  }
  return typeof fallbackPid === 'number' && fallbackPid > 0 ? readSmapsRollup(fallbackPid, procRoot) : null
}

/**
 * Triggers host-side cgroup v2 proactive memory reclaim (`memory.reclaim`) for a container cgroup.
 * Linux returns `EAGAIN` when fewer bytes than requested could be reclaimed; that still indicates
 * cold pages were reclaimed and is treated as success.
 */
export async function reclaimCgroupMemory(
  containerId: string,
  mode: 'freeze' | 'park' | 'pressure' = 'freeze',
  cgroupRoot = '/sys/fs/cgroup',
): Promise<boolean> {
  const ratio = mode === 'park' ? 0.5 : mode === 'pressure' ? 0.25 : 0.35
  for (const dir of candidateCgroupDirs(containerId, cgroupRoot)) {
    try {
      const currentRaw = await readFile(join(dir, 'memory.current'), 'utf8')
      const currentBytes = parseNonNegativeInt(currentRaw)
      if (currentBytes <= 0) continue
      const requestedBytes = Math.max(4 * 1024 * 1024, Math.floor((currentBytes * ratio) / DEFAULT_PAGE_SIZE) * DEFAULT_PAGE_SIZE)
      try {
        await writeFile(join(dir, 'memory.reclaim'), `${requestedBytes}\n`, 'utf8')
        return true
      } catch (err: any) {
        if (err?.code === 'EAGAIN') return true
      }
    } catch {
      continue
    }
  }
  return false
}

/**
 * Parses Linux `/proc/<pid>/stat` to extract PID, `utime + stime` CPU seconds, and `starttime` ticks.
 */
export function parseProcStat(text: string, clockTicksPerSec = 100): ProcStatTelemetry | null {
  const closeParen = text.lastIndexOf(')')
  if (closeParen <= 0) return null
  const pidMatch = /^\s*(\d+)\s+\(/.exec(text)
  if (!pidMatch) return null
  const pid = Number(pidMatch[1])
  const fields = text.slice(closeParen + 1).trim().split(/\s+/)
  // In /proc/<pid>/stat after `(comm)`: field[0]=state(3), field[11]=utime(14), field[12]=stime(15), field[19]=starttime(22)
  if (fields.length < 20) return null
  const utime = Number(fields[11])
  const stime = Number(fields[12])
  const starttimeTicks = Number(fields[19])
  if (![pid, utime, stime, starttimeTicks].every(n => Number.isSafeInteger(n) && n >= 0) || pid <= 0 || clockTicksPerSec <= 0) {
    return null
  }
  return {
    pid,
    starttimeTicks,
    cpuSeconds: (utime + stime) / clockTicksPerSec,
  }
}

/**
 * Reads `/proc/<pid>/stat` and `/proc/<pid>/smaps_rollup` for a process matching `matchCmdline`
 * (or a known `pid`), returning its CPU and proportional/shared memory telemetry.
 */
export async function findProcessTelemetry(
  matchCmdline: (args: string[]) => boolean,
  procRoot = '/proc',
): Promise<(ProcStatTelemetry & { smaps: SmapsRollup }) | null> {
  try {
    const entries = await readdir(procRoot)
    for (const entry of entries) {
      if (!/^\d+$/.test(entry)) continue
      const pid = Number(entry)
      try {
        const rawCmd = await readFile(join(procRoot, entry, 'cmdline'), 'utf8')
        const args = rawCmd.split('\0').filter(Boolean)
        if (!args.length || !matchCmdline(args)) continue
        const [statRaw, smaps] = await Promise.all([
          readFile(join(procRoot, entry, 'stat'), 'utf8'),
          readSmapsRollup(pid, procRoot),
        ])
        const stat = parseProcStat(statRaw)
        if (stat && smaps) return { ...stat, smaps }
      } catch {
        continue
      }
    }
  } catch {
    // Ignore unreadable procRoot
  }
  return null
}
