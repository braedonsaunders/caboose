import { describe, expect, it, vi } from 'vitest'
import { memoryPressure, startPressureReclaim } from './memory-pressure.js'

const psi = (avg10: number) => `some avg10=${avg10} avg60=1.00 avg300=0.50 total=123\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=4\n`

describe('memory back to the host under pressure', () => {
  it('reads some avg10 from /proc/pressure/memory', () => {
    expect(memoryPressure(psi(14.6))).toBe(14.6)
    expect(memoryPressure('garbage')).toBeNull()
  })

  it('reclaims every running computer above the threshold, at most once per cooldown', async () => {
    vi.useFakeTimers()
    try {
      let pressure = 2, clock = 0
      const reclaims: string[] = []
      const computer = { reclaimMemory: async (mode?: 'freeze' | 'pressure') => { reclaims.push(mode ?? 'freeze') } }
      const stop = startPressureReclaim({ computers: () => [computer, {}], read: async () => psi(pressure), now: () => clock, intervalMs: 1000, cooldownMs: 60_000 })
      await vi.advanceTimersByTimeAsync(1000)
      expect(reclaims).toEqual([])
      pressure = 12
      await vi.advanceTimersByTimeAsync(1000)
      expect(reclaims).toEqual(['pressure'])
      clock = 30_000; await vi.advanceTimersByTimeAsync(1000)
      expect(reclaims).toHaveLength(1)
      clock = 61_000; await vi.advanceTimersByTimeAsync(1000)
      expect(reclaims).toHaveLength(2)
      stop()
    } finally { vi.useRealTimers() }
  })
})
