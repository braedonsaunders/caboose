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

/** The machine the host runs on (`GET /v1/health` `machine`): what its computers share. */
export interface MachineResources {
  memoryMb: number
  availableMemoryMb: number
  cpus: number
  /** The volume holding the computers' disks and memory snapshots; null when the host cannot read it. */
  disk: { totalBytes: number; freeBytes: number } | null
}

/** The computers' image (`GET /v1/health` `image`): present, downloading, failed, or absent with nothing to fetch. */
export interface ImageStatus {
  state: 'ready' | 'fetching' | 'failed' | 'missing'
  reference: string | null
  receivedBytes?: number
  totalBytes?: number
  message?: string
}

export type HealthStatus = (
  | { host: string; hypervisor?: 'virtualization' | 'cloud-hypervisor'; kvm: boolean; desk: DeskStats }
  | { host: string; runtime: 'container'; gpu: GpuKind; container: string; running: boolean }
) & { machine?: MachineResources; image?: ImageStatus }

/** One line about the computers' image, for an owner. */
export function imageLabel(image: ImageStatus): string {
  switch (image.state) {
    case 'ready': return 'Installed'
    case 'missing': return 'Not installed, and this host has none to download'
    case 'failed': return `Download failed: ${image.message ?? 'unknown error'}`
    case 'fetching': return image.totalBytes ? `Downloading (${Math.floor(((image.receivedBytes ?? 0) / image.totalBytes) * 100)}%)` : 'Downloading'
  }
}

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
  const image = health.image
    ? [{ label: 'Computer image', value: imageLabel(health.image), ...(health.image.state === 'missing' || health.image.state === 'failed' ? { problem: true } : {}) }]
    : []
  if ('desk' in health) {
    const desk = health.desk
    const when = (value: string | null) => value ? new Date(value).toLocaleString() : 'Never'
    return [
      ...(health.hypervisor === 'virtualization'
        ? [{ label: 'Hypervisor', value: 'Apple Virtualization.framework' }]
        : [{ label: 'KVM', value: health.kvm ? 'Available' : 'Missing: /dev/kvm is not present', problem: !health.kvm }]),
      { label: 'Running machines', value: `${desk.resident} of ${desk.capacity}${desk.queued ? `, ${desk.queued} waiting` : ''}` },
      { label: 'Last started', value: when(desk.lastStartedAt) },
      { label: 'Last parked', value: when(desk.lastSuspendedAt) },
      { label: 'Guest reconnects', value: desk.reconnects ? `${desk.reconnects}, last ${when(desk.lastReconnectAt)}` : 'None', problem: desk.reconnects > 2 },
      { label: 'Snapshot CPU fallbacks', value: String(desk.snapshotCpuFallbacks), problem: desk.snapshotCpuFallbacks > 0 },
      ...(desk.lastError ? [{ label: 'Desk error', value: desk.lastError, problem: true }] : []),
      ...image,
    ]
  }
  return [
    { label: 'Container', value: health.container },
    { label: 'Container state', value: health.running ? 'Running' : 'Not running' },
    ...image,
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

/** A host problem worth showing above everything else, from what `/v1/health` reports. */
export function healthProblems(health: HealthStatus): string[] {
  const image = health.image?.state === 'missing'
    ? ["The computer's image is not installed, so no computer can start. Install a release that includes it, or build it (guest/image/README.md)."]
    : health.image?.state === 'failed' ? [`Downloading the computer's image failed: ${health.image.message ?? 'unknown error'}`] : []
  if (!('desk' in health)) return image
  return [
    ...(health.hypervisor === 'virtualization' || health.kvm ? [] : ['/dev/kvm is not present, so the host cannot start a microVM.']),
    ...(health.desk.lastError ? [health.desk.lastError] : []),
    ...image,
  ]
}

/** How much of a shared resource the computers are given, as a whole percentage of the machine. */
export function sharePercent(assigned: number, total: number): number {
  if (!(total > 0)) return 0
  return Math.round((assigned / total) * 100)
}

/** What the host's computers are given between them, and how many are running now. */
export function fleetTotals(computers: Array<{ state: string; settings: { memoryMb: number; vcpus: number } }>): { running: number; memoryMb: number; vcpus: number } {
  return computers.reduce((totals, computer) => ({
    running: totals.running + (computer.state === 'running' ? 1 : 0),
    memoryMb: totals.memoryMb + computer.settings.memoryMb,
    vcpus: totals.vcpus + computer.settings.vcpus,
  }), { running: 0, memoryMb: 0, vcpus: 0 })
}
