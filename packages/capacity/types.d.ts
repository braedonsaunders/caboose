/** Read-only capacity contract. All bytes are binary bytes; memoryMb settings are MiB. */
export interface Measurement { value: number | null; reason?: string }
export interface ResourceTotals { memoryBytes: number | null; vcpus: number | null }
export interface StorageCategory { logicalBytes: Measurement; allocatedBytes: Measurement }
export interface Capacity {
  sampledAt: string
  scope: 'host' | 'tenant'
  allocated: ResourceTotals
  running: ResourceTotals
  counts: Record<'total' | 'running' | 'parked' | 'frozen' | 'waking' | 'parking' | 'restarting' | 'error', number> & { queued: Measurement }
  storage: { disks: StorageCategory; snapshots: StorageCategory; backups: StorageCategory; uniquePhysicalBytes: Measurement }
  quotas: null | { memoryBytes: number | null; vcpus: number | null; diskBytes: number | null }
  headroom: null | { memoryBytes: Measurement; vcpus: Measurement; diskBytes: Measurement }
  host?: {
    memoryTotalBytes: Measurement; memoryFreeBytes: Measurement; memoryAvailableBytes: Measurement
    cpuBusyPercent: Measurement; cpuSampleMs: Measurement; logicalCpus: Measurement
    loadAverage1m: Measurement
    diskTotalBytes: Measurement; diskAvailableBytes: Measurement
  }
  computers?: Array<{ id: string; name: string; memoryLimitBytes: number; vcpus: number; usage: ComputerUsage | null }>
  warnings: string[]
}

/** Cgroup charge includes cache; RSS includes shared pages and is not unique RAM. */
export interface UsageCounters {
  identity: string; at: number; cpuSeconds: number; vcpus: number
  memoryBytes: number; cacheBytes: number | null; memoryLimitBytes: number | null
  memoryKind: 'cgroup' | 'resident'
}
export interface ComputerUsage {
  sampledAt: number | null; memoryBytes: number | null; cacheBytes: number | null
  memoryLimitBytes: number | null; memoryKind: 'cgroup' | 'resident' | 'unavailable'
  cpuPercent: number | null; cpuSeconds30d: number; coveredSeconds30d: number
  collectingSince: number | null; reason?: string
}
export interface ComputerStorage {
  sampledAt: number; home: StorageCategory; writableLayerLogicalBytes: Measurement; sharedImageLogicalBytes: Measurement
}
