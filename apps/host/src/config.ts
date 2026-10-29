import { resolve } from 'node:path'
import { publicUrl } from './reach.js'
import { REGISTRY_URL } from './registry.js'

export interface Config {
  /** `CABOOSE_OWNER_TOKEN`; null means the host generates one in its state directory. */
  token: string | null
  host: string
  port: number
  idleMs: number
  /** Maximum time a resident microVM remains frozen before parking. */
  freezeParkMs?: number
  imageRoot: string
  memoryMb: number
  vcpus: number
  vmmPath: string
  /** "microvm" (Cloud Hypervisor, the default) or "container" (for a GPU only a container can use). */
  runtime: 'microvm' | 'container'
  containerImage: string
  /** An OCI reference for the microVM image, fetched on first run when the disk root lacks it. */
  baseImage: string | null
  /** Postgres for accounts and tenants; null keeps them in an embedded database in the image root. */
  databaseUrl: string | null
  containerName: string
  /** A named volume or an absolute host path for /home/caboose. */
  containerHome: string
  /** Extra `docker run` arguments, whitespace-separated. */
  containerArgs: string[]
  /** Which GPU the container gets: detected from the host's devices unless set. */
  gpu: GpuKind | 'auto'
  /** The ACP agent registry (registry.json); a mirror can stand in for the public one. */
  agentRegistryUrl: string
  /** How long a task's agent stays running after a turn, waiting for a reply. */
  agentIdleMs: number
  /** How many microVM computers may run at once; waking one more waits for another to park. */
  maxRunning: number
  /** `CABOOSE_PUBLIC_URL`: where phones reach this host from anywhere, first in every pairing link. */
  publicUrl: string | null
  /** Cloud Hypervisor snapshot and memory options. */
  vmCow?: boolean
  vmRestoreMode?: 'copy' | 'copyonwrite' | 'ondemand'
  vmTemplate?: boolean
  vmFreePageReporting?: boolean
  /** `CABOOSE_MDNS`: advertise `_caboose._tcp` on the LAN (default on). */
  mdns: boolean
}

/** What `/v1/session` tells the app to speak on `/v1/display` (docs/architecture.md, docs/display.md). */
export type DisplayProtocol = 'caboose-display'

/**
 * The ways a host can hand a GPU to a container. `wsl`: WSL2's paravirtual /dev/dxg (any
 * vendor; NVENC on NVIDIA). `nvidia`: a Linux host with the NVIDIA container toolkit.
 * `dri`: Linux render nodes (Intel, AMD; Mesa and VA-API). `none`: CPU only.
 */
export type GpuKind = 'wsl' | 'nvidia' | 'dri' | 'none'
function integer(value: string | undefined, fallback: number, name: string, max: number): number {
  const parsed = value === undefined ? fallback : Number(value)
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > max) throw new Error(`${name} must be an integer from 1 to ${max}`)
  return parsed
}
export function config(env: NodeJS.ProcessEnv): Config {
  const selectedRuntime = runtime(env.CABOOSE_RUNTIME)
  const cowAlias = toggle(env.CABOOSE_VM_COW, 'CABOOSE_VM_COW')
  const requestedMode = env.CABOOSE_VM_RESTORE_MODE
  if (requestedMode !== undefined && !['copy', 'copyonwrite', 'ondemand'].includes(requestedMode)) throw new Error('CABOOSE_VM_RESTORE_MODE must be copy, copyonwrite or ondemand')
  if (cowAlias && requestedMode !== undefined && requestedMode !== 'copyonwrite') throw new Error('CABOOSE_VM_COW=on conflicts with CABOOSE_VM_RESTORE_MODE')
  const vmRestoreMode = (requestedMode ?? (cowAlias ? 'copyonwrite' : 'copy')) as 'copy' | 'copyonwrite' | 'ondemand'
  const vmCow = vmRestoreMode === 'copyonwrite'
  const vmTemplate = toggle(env.CABOOSE_VM_TEMPLATE, 'CABOOSE_VM_TEMPLATE')
  const vmFreePageReporting = toggle(env.CABOOSE_VM_FREE_PAGE_REPORTING, 'CABOOSE_VM_FREE_PAGE_REPORTING')
  if (vmTemplate && vmRestoreMode === 'ondemand') throw new Error('CABOOSE_VM_TEMPLATE cannot be combined with ondemand restore')
  if ((vmRestoreMode !== 'copy' || vmTemplate) && env.CABOOSE_VM_DEPOT?.trim()) throw new Error('CABOOSE_VM_COW and CABOOSE_VM_TEMPLATE cannot be combined with the microVM depot')
  if (selectedRuntime === 'container' && (vmRestoreMode !== 'copy' || vmFreePageReporting || vmTemplate)) throw new Error('Cloud Hypervisor memory options require the microVM runtime')
  return {
    token: env.CABOOSE_OWNER_TOKEN || null,
    host: env.CABOOSE_BIND ?? '127.0.0.1',
    port: integer(env.CABOOSE_PORT, 7310, 'CABOOSE_PORT', 65535),
    idleMs: integer(env.CABOOSE_IDLE_MS, 600_000, 'CABOOSE_IDLE_MS', 2_147_483_647),
    freezeParkMs: integer(env.CABOOSE_FREEZE_PARK_MS, 60_000, 'CABOOSE_FREEZE_PARK_MS', 2_147_483_647),
    imageRoot: resolve(env.CABOOSE_IMAGE_ROOT ?? '/var/lib/caboose'),
    memoryMb: integer(env.CABOOSE_MEMORY_MB, 6144, 'CABOOSE_MEMORY_MB', 1_048_576),
    vcpus: integer(env.CABOOSE_VCPUS, 4, 'CABOOSE_VCPUS', 256),
    vmmPath: env.CABOOSE_VMM_PATH ?? (process.platform === 'darwin' ? '/usr/local/bin/appkit-desk-vz' : '/usr/local/bin/cloud-hypervisor'),
    runtime: selectedRuntime,
    containerImage: env.CABOOSE_CONTAINER_IMAGE ?? 'caboose-computer:latest',
    baseImage: env.CABOOSE_BASE_IMAGE || null,
    databaseUrl: env.CABOOSE_DATABASE_URL || null,
    containerName: env.CABOOSE_CONTAINER_NAME ?? 'caboose-owner',
    containerHome: env.CABOOSE_CONTAINER_HOME ?? 'caboose-home',
    containerArgs: (env.CABOOSE_CONTAINER_ARGS ?? '').split(/\s+/).filter(Boolean),
    gpu: gpu(env.CABOOSE_GPU),
    agentRegistryUrl: registryUrl(env.CABOOSE_AGENT_REGISTRY_URL),
    agentIdleMs: integer(env.CABOOSE_AGENT_IDLE_MS, 600_000, 'CABOOSE_AGENT_IDLE_MS', 86_400_000),
    maxRunning: integer(env.CABOOSE_MAX_RUNNING, 4, 'CABOOSE_MAX_RUNNING', 64),
    publicUrl: publicUrl(env.CABOOSE_PUBLIC_URL),
    mdns: mdns(env.CABOOSE_MDNS),
    vmCow,
    vmRestoreMode,
    vmTemplate,
    vmFreePageReporting,
  }
}

function toggle(value: string | undefined, name: string): boolean {
  if (value === undefined || value === 'off') return false
  if (value === 'on') return true
  throw new Error(`${name} must be on or off`)
}

function mdns(value: string | undefined): boolean {
  if (value === undefined || value === 'on') return true
  if (value === 'off') return false
  throw new Error('CABOOSE_MDNS must be "on" or "off"')
}

function registryUrl(value: string | undefined): string {
  if (!value) return REGISTRY_URL
  let url: URL
  try { url = new URL(value) } catch { throw new Error('CABOOSE_AGENT_REGISTRY_URL must be an http(s) URL') }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') throw new Error('CABOOSE_AGENT_REGISTRY_URL must be an http(s) URL')
  return url.href
}

function runtime(value: string | undefined): 'microvm' | 'container' {
  if (value === undefined || value === 'microvm') return 'microvm'
  if (value === 'container') return 'container'
  throw new Error('CABOOSE_RUNTIME must be "microvm" or "container"')
}

function gpu(value: string | undefined): GpuKind | 'auto' {
  const kinds = ['auto', 'wsl', 'nvidia', 'dri', 'none'] as const
  const chosen = value ?? 'auto'
  if ((kinds as readonly string[]).includes(chosen)) return chosen as GpuKind | 'auto'
  throw new Error(`CABOOSE_GPU must be one of ${kinds.join(', ')}`)
}
