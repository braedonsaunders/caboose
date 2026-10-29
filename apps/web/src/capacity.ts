export type { Capacity, Measurement } from '../../../packages/capacity/types.js'
import type { Measurement } from '../../../packages/capacity/types.js'
export function capacityValue(m: Measurement, unit: 'bytes' | 'count' | 'percent' = 'count'): string {
  if (m.value === null) return `Unavailable: ${m.reason ?? 'not measured'}`
  if (unit === 'bytes') {
    const bytes = Math.abs(m.value), units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB']
    const index = bytes > 0 ? Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1) : 0
    return `${m.value < 0 ? '−' : ''}${(bytes / 1024 ** index).toFixed(index === 0 ? 0 : 1)} ${units[index]}`
  }
  if (unit === 'percent') return `${m.value.toFixed(1)}%`
  return m.value.toLocaleString(undefined, { maximumFractionDigits: 2 })
}
