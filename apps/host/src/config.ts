import { resolve } from 'node:path'

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
}
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
    memoryMb: integer(env.CABOOSE_MEMORY_MB, 2048, 'CABOOSE_MEMORY_MB', 1_048_576),
    vcpus: integer(env.CABOOSE_VCPUS, 2, 'CABOOSE_VCPUS', 256),
    vmmPath: env.CABOOSE_VMM_PATH ?? '/usr/local/bin/cloud-hypervisor',
    runtime: runtime(env.CABOOSE_RUNTIME),
    containerImage: env.CABOOSE_CONTAINER_IMAGE ?? 'caboose-computer:latest',
    containerName: env.CABOOSE_CONTAINER_NAME ?? 'caboose-owner',
    containerHome: env.CABOOSE_CONTAINER_HOME ?? 'caboose-home',
    containerArgs: (env.CABOOSE_CONTAINER_ARGS ?? '').split(/\s+/).filter(Boolean),
  }
}

function runtime(value: string | undefined): 'microvm' | 'container' {
  if (value === undefined || value === 'microvm') return 'microvm'
  if (value === 'container') return 'container'
  throw new Error('CABOOSE_RUNTIME must be "microvm" or "container"')
}
