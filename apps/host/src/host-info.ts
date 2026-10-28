import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { Config, DisplayProtocol, GpuKind } from './config.js'
import { detectGpu } from './container-driver.js'

/** One deployment setting as the host read it at startup. Values are never secrets. */
export interface HostSetting {
  /** The environment variable that sets it. */
  name: string
  value: string
  /** True when the variable was not set and this is the host's default. */
  default: boolean
}

/** What `GET /v1/host` reports: how this host was started. Fixed until the host restarts. */
export interface HostInfo {
  /** The caboose-host package version. */
  version: string
  /** The Node.js version the host runs on. */
  node: string
  runtime: Config['runtime']
  display: DisplayProtocol
  /** The GPU the computer is given: the container's, or null for a microVM, which has none. */
  gpu: GpuKind | null
  /** What the computer boots from: the container image, or the microVM's golden image. */
  image: string
  push: boolean
  liveActivities: boolean
  settings: HostSetting[]
}

const VERSION = (JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')) as { version: string }).version

/**
 * Settings worth showing an owner, read from the environment the host started with. The
 * owner token, APNs key path and other credentials are deliberately absent.
 */
const SHOWN: Array<{ name: string; fallback: string; only?: Config['runtime'] }> = [
  { name: 'CABOOSE_RUNTIME', fallback: 'microvm' },
  { name: 'CABOOSE_DISPLAY', fallback: 'xpra' },
  { name: 'CABOOSE_GPU', fallback: 'auto', only: 'container' },
  { name: 'CABOOSE_CONTAINER_IMAGE', fallback: 'caboose-computer:latest', only: 'container' },
  { name: 'CABOOSE_CONTAINER_NAME', fallback: 'caboose-owner', only: 'container' },
  { name: 'CABOOSE_CONTAINER_HOME', fallback: 'caboose-home', only: 'container' },
  { name: 'CABOOSE_IMAGE_ROOT', fallback: '/var/lib/caboose' },
  { name: 'CABOOSE_GUEST_LAN', fallback: 'deny' },
  { name: 'CABOOSE_BIND', fallback: '127.0.0.1' },
  { name: 'CABOOSE_PORT', fallback: '7310' },
  { name: 'CABOOSE_MEMORY_MB', fallback: '6144' },
  { name: 'CABOOSE_VCPUS', fallback: '4' },
  { name: 'CABOOSE_IDLE_MS', fallback: '600000' },
  { name: 'CABOOSE_AGENT_REGISTRY_URL', fallback: 'the public ACP registry' },
  { name: 'CABOOSE_AGENT_IDLE_MS', fallback: '600000' },
]

export function describeHost(config: Config, env: NodeJS.ProcessEnv, options: { push: boolean; liveActivities: boolean; exists?: (path: string) => boolean }): HostInfo {
  const container = config.runtime === 'container'
  return {
    version: VERSION,
    node: process.version,
    runtime: config.runtime,
    display: config.display,
    gpu: container ? (config.gpu === 'auto' ? detectGpu(options.exists) : config.gpu) : null,
    image: container ? config.containerImage : `Debian 13 golden image (${join(config.imageRoot, 'base.raw')})`,
    push: options.push,
    liveActivities: options.liveActivities,
    settings: SHOWN.filter(entry => !entry.only || entry.only === config.runtime).map(({ name, fallback }) => {
      const value = env[name]
      return value ? { name, value: withoutCredentials(value), default: false } : { name, value: fallback, default: true }
    }),
  }
}

/** A URL keeps its address but never a user name or password it was given. */
function withoutCredentials(value: string): string {
  try {
    const url = new URL(value)
    if (!url.username && !url.password) return value
    url.username = ''
    url.password = ''
    return url.href
  } catch {
    return value
  }
}
