import { resolve } from 'node:path'
import { REGISTRY_URL } from './registry.js'

export interface Config {
  token: string
  host: string
  port: number
  idleMs: number
  imageRoot: string
  memoryMb: number
  vcpus: number
  vmmPath: string
  /** "microvm" (Cloud Hypervisor, the default) or "container" (for a GPU only a container can use). */
  runtime: 'microvm' | 'container'
  containerImage: string
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
  if (!env.CABOOSE_OWNER_TOKEN) throw new Error('CABOOSE_OWNER_TOKEN is required')
  return {
    token: env.CABOOSE_OWNER_TOKEN,
    host: env.CABOOSE_BIND ?? '127.0.0.1',
    port: integer(env.CABOOSE_PORT, 7310, 'CABOOSE_PORT', 65535),
    idleMs: integer(env.CABOOSE_IDLE_MS, 600_000, 'CABOOSE_IDLE_MS', 2_147_483_647),
    imageRoot: resolve(env.CABOOSE_IMAGE_ROOT ?? '/var/lib/caboose'),
    memoryMb: integer(env.CABOOSE_MEMORY_MB, 6144, 'CABOOSE_MEMORY_MB', 1_048_576),
    vcpus: integer(env.CABOOSE_VCPUS, 4, 'CABOOSE_VCPUS', 256),
    vmmPath: env.CABOOSE_VMM_PATH ?? '/usr/local/bin/cloud-hypervisor',
    runtime: runtime(env.CABOOSE_RUNTIME),
    containerImage: env.CABOOSE_CONTAINER_IMAGE ?? 'caboose-computer:latest',
    containerName: env.CABOOSE_CONTAINER_NAME ?? 'caboose-owner',
    containerHome: env.CABOOSE_CONTAINER_HOME ?? 'caboose-home',
    containerArgs: (env.CABOOSE_CONTAINER_ARGS ?? '').split(/\s+/).filter(Boolean),
    gpu: gpu(env.CABOOSE_GPU),
    agentRegistryUrl: registryUrl(env.CABOOSE_AGENT_REGISTRY_URL),
    agentIdleMs: integer(env.CABOOSE_AGENT_IDLE_MS, 600_000, 'CABOOSE_AGENT_IDLE_MS', 86_400_000),
    maxRunning: integer(env.CABOOSE_MAX_RUNNING, 4, 'CABOOSE_MAX_RUNNING', 64),
  }
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
