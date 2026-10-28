/** How the host was started (`GET /v1/host`) and how it is doing (`GET /v1/health`). */

export type GpuKind = 'wsl' | 'nvidia' | 'dri' | 'none'

export interface HostSetting {
  name: string
  value: string
  /** The variable was not set; this is the host's default. */
  default: boolean
}

export interface HostInfo {
  version: string
  node: string
  runtime: 'microvm' | 'container'
  /** The container's GPU; null for a microVM. */
  gpu: GpuKind | null
  image: string
  push: boolean
  liveActivities: boolean
  settings: HostSetting[]
}

/** appkit-desk's host statistics, as a microVM host reports them. */
export interface DeskStats {
  resident: number
  queued: number
  capacity: number
  suspended: number
  lastStartedAt: string | null
  lastSuspendedAt: string | null
  reconnects: number
  lastReconnectAt: string | null
  lastError: string | null
  snapshotCpuFallbacks: number
}

export type HealthStatus =
  | { host: string; kvm: boolean; desk: DeskStats }
  | { host: string; runtime: 'container'; gpu: GpuKind; container: string; running: boolean }

/** The guest-components upgrade a host runs on wake, when it reports one (`GET /v1/computer` `upgrade`). */
export interface ComponentsUpgrade {
  state: 'checking' | 'updating' | 'succeeded' | 'failed'
  version?: string
  message?: string
}

export function runtimeLabel(runtime: HostInfo['runtime']): string {
  return runtime === 'container' ? 'Container' : 'microVM'
}

export function gpuLabel(gpu: GpuKind | null): string {
  switch (gpu) {
    case null: return 'None (microVM)'
    case 'wsl': return 'WSL2 GPU (/dev/dxg)'
    case 'nvidia': return 'NVIDIA (container toolkit)'
    case 'dri': return 'Render nodes (/dev/dri)'
    case 'none': return 'None: software rendering'
  }
}

/** One line per fact the health route reports, whichever runtime answered. */
export function healthFacts(health: HealthStatus): Array<{ label: string; value: string; problem?: boolean }> {
  if ('desk' in health) {
    const desk = health.desk
    const when = (value: string | null) => value ? new Date(value).toLocaleString() : 'Never'
    return [
      { label: 'KVM', value: health.kvm ? 'Available' : 'Missing: /dev/kvm is not present', problem: !health.kvm },
      { label: 'Running machines', value: `${desk.resident} of ${desk.capacity}${desk.queued ? `, ${desk.queued} waiting` : ''}` },
      { label: 'Last started', value: when(desk.lastStartedAt) },
      { label: 'Last parked', value: when(desk.lastSuspendedAt) },
      { label: 'Guest reconnects', value: desk.reconnects ? `${desk.reconnects}, last ${when(desk.lastReconnectAt)}` : 'None', problem: desk.reconnects > 2 },
      { label: 'Snapshot CPU fallbacks', value: String(desk.snapshotCpuFallbacks), problem: desk.snapshotCpuFallbacks > 0 },
      ...(desk.lastError ? [{ label: 'Desk error', value: desk.lastError, problem: true }] : []),
    ]
  }
  return [
    { label: 'Container', value: health.container },
    { label: 'Container state', value: health.running ? 'Running' : 'Not running' },
  ]
}

export function upgradeLabel(upgrade: ComponentsUpgrade): string {
  switch (upgrade.state) {
    case 'checking': return 'Checking Caboose components'
    case 'updating': return 'Updating Caboose components'
    case 'succeeded': return 'Caboose components are up to date'
    case 'failed': return 'Caboose components could not be updated'
  }
}
