import { readFile } from 'node:fs/promises'

/**
 * Hands memory back to the host while it is short of it (docs/architecture.md § Memory): every
 * `intervalMs` the host's memory pressure (`some avg10` of /proc/pressure/memory, the share of
 * time some task waited for memory) is read, and above `threshold` every running microVM drops
 * its clean page cache and ages cold memory (`caboose-memory reclaim --mode=pressure`), which
 * free-page reporting returns to the host. At most once per `cooldownMs`.
 */
export interface PressureReclaimOptions {
  computers: () => Array<{ reclaimMemory?(mode?: 'freeze' | 'pressure'): Promise<void> }>
  read?: () => Promise<string>
  threshold?: number
  intervalMs?: number
  cooldownMs?: number
  now?: () => number
  log?: (line: string) => void
}

/** `some avg10` from /proc/pressure/memory, or null when the file says nothing usable. */
export function memoryPressure(text: string): number | null {
  const match = /^some\b.*?\bavg10=([0-9.]+)/m.exec(text)
  return match ? Number(match[1]) : null
}

export function startPressureReclaim(options: PressureReclaimOptions): () => void {
  const read = options.read ?? (() => readFile('/proc/pressure/memory', 'utf8'))
  const threshold = options.threshold ?? 5, cooldown = options.cooldownMs ?? 60_000, now = options.now ?? Date.now
  let last = -Infinity, busy = false
  const tick = async () => {
    if (busy) return
    busy = true
    try {
      const pressure = memoryPressure(await read().catch(() => ''))
      if (pressure === null || pressure <= threshold || now() - last < cooldown) return
      last = now()
      options.log?.(`Host memory pressure ${pressure}: reclaiming running computers' memory`)
      await Promise.all(options.computers().map(computer => computer.reclaimMemory?.('pressure').catch(() => {})))
    } finally { busy = false }
  }
  const timer = setInterval(() => void tick(), options.intervalMs ?? 15_000)
  timer.unref()
  return () => clearInterval(timer)
}
