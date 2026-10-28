import { execFile } from 'node:child_process'
import { guardContainerPrinting } from './components.js'
import { randomBytes } from 'node:crypto'
import { existsSync } from 'node:fs'
import { readFile, rm } from 'node:fs/promises'
import type { Config, GpuKind } from './config.js'
import type { ComputerIdentity, ComputerResources } from './driver.js'
import type { App, Controller, Session } from './server.js'
import type { ComputerSettings } from './settings.js'
import { fenceBridge, unfenceBridge } from './network.js'
import { AGENT_DISPLAY_PORT, DISPLAY_ENV_PATH, OWNER_DISPLAY_PORT, WRITE_TOKEN_SCRIPT, parseEnvFile } from './display.js'

/** The owner computer's own Docker network, so its bridge interface has a known name to fence. */
export const CONTAINER_NETWORK = 'caboose'
export const CONTAINER_BRIDGE = 'caboose-br0'
const FILES_PORT = 14700

/**
 * Where a container computer lives on the host. Slot 0 is the owner's computer and keeps the
 * names and loopback ports a host had before it ran several. Every other computer gets its own
 * container, home volume and bridge network (Docker isolates bridge networks from each other),
 * and loopback ports from 20000 + 10 × slot.
 */
export function containerPlacement(config: Pick<Config, 'containerName' | 'containerHome'>, identity: ComputerIdentity) {
  if (identity.slot === 0) {
    return { name: config.containerName, home: config.containerHome, network: CONTAINER_NETWORK, bridge: CONTAINER_BRIDGE, ports: { display: OWNER_DISPLAY_PORT, agent: AGENT_DISPLAY_PORT, files: FILES_PORT } }
  }
  const base = 20_000 + identity.slot * 10
  return {
    name: `caboose-${identity.id}`, home: `${config.containerHome}-${identity.id}`,
    network: `caboose-${identity.slot}`, bridge: `caboose-br${identity.slot}`,
    ports: { display: base, agent: base + 1, files: base + 2 },
  }
}

/**
 * The computer as a container instead of a microVM, for hosts whose GPU a container can use
 * but a VM cannot have: WSL2's paravirtual /dev/dxg (any vendor), a Linux NVIDIA GPU through
 * the container toolkit, or Linux render nodes (Intel, AMD). The image reads CABOOSE_GPU to
 * pick its GL driver and caboose-display's video encoder; with no GPU it runs on the CPU.
 *
 * The image provides `caboose-session start | ready | start-agent | start-files`, which runs
 * D-Bus and the two caboose-display instances (the owner's display and the agent seat) as
 * `caboose`, reading the per-wake token from /run/caboose/display-token. Displays are
 * published on loopback only.
 *
 * Parking freezes the container (cgroup freezer): memory stays in RAM and resume is
 * instant, but unlike a microVM snapshot it does not survive a restart of the host;
 * after one the computer boots fresh with its home intact. See docs/architecture.md.
 */
export type Docker = (args: string[], timeoutMs?: number) => Promise<string>

export function dockerCli(binary = 'docker'): Docker {
  return (args, timeoutMs = 60_000) => new Promise((resolve, reject) => {
    execFile(binary, args, { timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) reject(new Error(`docker ${args[0]} failed: ${(stderr || error.message).trim()}`))
      else resolve(stdout)
    })
  })
}

/** The GPU this host can give a container, by the devices it has. */
export function detectGpu(exists: (path: string) => boolean = existsSync): GpuKind {
  if (exists('/dev/dxg')) return 'wsl'
  if (exists('/dev/nvidiactl') || exists('/dev/nvidia0')) return 'nvidia'
  if (exists('/dev/dri/renderD128')) return 'dri'
  return 'none'
}

/**
 * `docker run` arguments that hand the container the GPU. With a render node the
 * container also gets /dev/udmabuf when the host has it: the Caboose VA-API driver exports
 * its decode surfaces through it, so GL players keep video passthrough (guest/vaapi).
 */
export function gpuArgs(kind: GpuKind, exists: (path: string) => boolean = existsSync): string[] {
  const udmabuf = exists('/dev/udmabuf') ? ['--device', '/dev/udmabuf'] : []
  switch (kind) {
    case 'wsl': return ['--device', '/dev/dxg', '-v', '/usr/lib/wsl:/usr/lib/wsl:ro', '-e', 'LD_LIBRARY_PATH=/usr/lib/wsl/lib', '-e', 'CABOOSE_GPU=wsl']
    case 'nvidia': return ['--gpus', 'all', '-e', 'NVIDIA_DRIVER_CAPABILITIES=all', ...udmabuf, '-e', 'CABOOSE_GPU=nvidia']
    case 'dri': return ['--device', '/dev/dri', ...udmabuf, '-e', 'CABOOSE_GPU=dri']
    case 'none': return ['-e', 'CABOOSE_GPU=none']
  }
}

export function createContainerController(config: Config, dependencies: { docker?: Docker; exists?: (path: string) => boolean; settings?: () => ComputerSettings; fence?: (device: string) => Promise<void>; unfence?: (device: string) => Promise<void>; identity?: ComputerIdentity } = {}): Controller {
  const docker = dependencies.docker ?? dockerCli()
  const place = containerPlacement(config, dependencies.identity ?? { id: 'owner', slot: 0 })
  const settings = (): ComputerSettings => dependencies.settings?.() ?? { name: 'Caboose', memoryMb: config.memoryMb, vcpus: config.vcpus, idleMs: config.idleMs, defaultAgent: null }
  /** What the container was created with; settings changes apply on the next restart. */
  let resources: ComputerResources | null = null
  let lastError: string | null = null
  const name = place.name
  const gpu: GpuKind = config.gpu === 'auto' ? detectGpu(dependencies.exists) : config.gpu
  /** What an app launched onto the owner's display needs; caboose-display's, read at each wake. */
  let launchEnv: string[] = []
  let displayToken = ''
  let running = false
  let filesPortWarning: string | undefined

  async function state(): Promise<'missing' | 'running' | 'paused' | 'stopped'> {
    try {
      const status = (await docker(['inspect', '-f', '{{.State.Status}}', name], 15_000)).trim()
      if (status === 'running') return 'running'
      if (status === 'paused') return 'paused'
      return 'stopped'
    } catch {
      return 'missing'
    }
  }

  /** The network and its fence, before the computer can send a packet. Idempotent. */
  async function ensureNetwork(): Promise<void> {
    try {
      await docker(['network', 'inspect', place.network], 15_000)
    } catch {
      await docker(['network', 'create', '--driver', 'bridge', '-o', `com.docker.network.bridge.name=${place.bridge}`, place.network], 30_000)
    }
    await (dependencies.fence ?? fenceBridge)(place.bridge)
  }

  function runArgs(size: ComputerResources): string[] {
    return [
      'run', '-d', '--name', name, '--hostname', 'caboose', '--init',
      // Its own fenced network, and public DNS like the microVM, so nothing depends on the LAN.
      '--network', place.network, '--dns', '1.1.1.1', '--dns', '9.9.9.9',
      '--restart', 'no',
      '--label', `caboose.memory-mb=${size.memoryMb}`, '--label', `caboose.vcpus=${size.vcpus}`,
      '--memory', `${size.memoryMb}m`, '--cpus', String(size.vcpus), '--shm-size', '2g',
      '-p', `127.0.0.1:${place.ports.files}:${FILES_PORT}`, '-p', `127.0.0.1:${place.ports.display}:${OWNER_DISPLAY_PORT}`, '-p', `127.0.0.1:${place.ports.agent}:${AGENT_DISPLAY_PORT}`,
      '-v', `${place.home}:/home/caboose`,
      ...gpuArgs(gpu, dependencies.exists),
      ...config.containerArgs,
      config.containerImage,
    ]
  }

  async function exec(user: 'root' | 'caboose', command: string, args: string[], timeoutMs = 30_000): Promise<string> {
    if (!running) throw new Error('Computer is not running')
    return docker(['exec', '-u', user, name, command, ...args], timeoutMs)
  }

  async function guestApps(action: string, id?: string, path?: string): Promise<string> {
    const script = await readFile(new URL('./guest-apps.py', import.meta.url), 'utf8')
    return exec('caboose', '/usr/bin/env', [...launchEnv, 'HOME=/home/caboose', '/usr/bin/python3', '-c', script, action, ...(id ? [id] : []), ...(path ? [path] : [])], 60_000)
  }

  /** The size an existing container was created with (survives a host restart). */
  async function createdWith(): Promise<ComputerResources | null> {
    try {
      const limits = JSON.parse(await docker(['inspect', '-f', '{{json .HostConfig}}', name], 15_000)) as { Memory?: number; NanoCpus?: number }
      const memoryMb = (limits.Memory ?? 0) / 1024 / 1024, vcpus = (limits.NanoCpus ?? 0) / 1_000_000_000
      return memoryMb > 0 && vcpus > 0 ? { memoryMb, vcpus } : null
    } catch {
      return null
    }
  }

  const controller: Controller = {
    componentsMode: 'container',
    componentsWarning: () => filesPortWarning,
    displayUrl: `ws://127.0.0.1:${place.ports.display}/`,
    agentDisplayUrl: `ws://127.0.0.1:${place.ports.agent}/`,
    fileService: () => ({ url: `http://127.0.0.1:${place.ports.files}`, token: displayToken }),
    async ensureAgentSeat() {
      await exec('root', '/usr/local/bin/caboose-session', ['start-agent'], 120_000)
    },
    guest() {
      if (!running) return undefined
      return { run: (command: string, args: string[], timeoutMs?: number) => exec('root', command, args, timeoutMs), ownerEnv: launchEnv }
    },
    stats: () => ({ host: 'caboose-host', runtime: 'container', gpu, container: name, running }),
    activeResources: () => resources,
    hasSavedState: () => resources !== null,
    lastError: () => lastError,
    async wake(): Promise<Session> {
      await ensureNetwork()
      const current = await state()
      if (current === 'missing') {
        const desired = settings()
        resources = { memoryMb: desired.memoryMb, vcpus: desired.vcpus }
        await docker(runArgs(resources), 300_000)
      } else {
        resources ??= await createdWith()
        if (current === 'stopped') await docker(['start', name], 120_000)
        else if (current === 'paused') await docker(['unpause', name], 60_000)
      }
      running = true
      try {
        const mapping = await docker(['port', name, `${FILES_PORT}/tcp`], 15_000).catch(() => '')
        filesPortWarning = mapping.split(/\r?\n/).some(line => line.trim() === `127.0.0.1:${place.ports.files}`) ? undefined : 'Recreate the container to enable Files.'

        if (!displayToken) {
          displayToken = randomBytes(32).toString('hex')
          await exec('root', '/bin/sh', ['-c', WRITE_TOKEN_SCRIPT, 'sh', displayToken])
        }
        await guardContainerPrinting({ run: (cmd, args, timeout) => exec('root', cmd, args, timeout) }).catch(error => console.error('Container printing guard unavailable:', error))
        await exec('root', '/usr/local/bin/caboose-session', ['start'], 240_000)
        await exec('root', '/usr/local/bin/caboose-session', ['ready'], 240_000)
        launchEnv = parseEnvFile(await exec('root', '/bin/cat', [DISPLAY_ENV_PATH]))
        if (!launchEnv.length) throw new Error(`caboose-display wrote no launch environment to ${DISPLAY_ENV_PATH}`)
        const size = resources ?? { memoryMb: config.memoryMb, vcpus: config.vcpus }
        return { state: 'running', display: { path: '/v1/display', token: displayToken, protocol: 'caboose-display' }, computer: { name: settings().name, image: gpu === 'none' ? 'Debian 13' : 'Debian 13 · GPU', ...size } }
      } catch (error) {
        running = false
        throw error
      }
    },
    async park() {
      if ((await state()) === 'running') await docker(['pause', name], 60_000)
      running = false
    },
    /** Restart the same container so installed packages and their rollback cache survive. */
    async restart() {
      lastError = null
      if (running) {
        try { await exec('root', '/bin/sync', [], 5_000) }
        catch (error) {
          lastError = `The computer restarted without confirming a disk flush: ${error instanceof Error ? error.message : String(error)}`
          console.error(lastError)
        }
      }
      const current = await state()
      if (current === 'paused') await docker(['unpause', name], 60_000)
      if (current === 'running' || current === 'paused') await docker(['stop', '-t', '10', name], 120_000)
      running = false
      displayToken = ''
      if (current !== 'missing') {
        const desired = settings()
        await docker(['update', '--memory', `${desired.memoryMb}m`, '--memory-swap', `${desired.memoryMb * 2}m`, '--cpus', String(desired.vcpus), name], 120_000)
        resources = { memoryMb: desired.memoryMb, vcpus: desired.vcpus }
      } else resources = null
      return controller.wake()
    },
    /** Deletes the computer: its container, its home and its network. Nothing of it is kept. */
    async destroy() {
      running = false
      displayToken = ''
      resources = null
      if ((await state()) !== 'missing') await docker(['rm', '-f', name], 120_000)
      if (place.home.startsWith('/')) await rm(place.home, { recursive: true, force: true }).catch(error => console.error(`Could not remove ${place.home}:`, error))
      else await docker(['volume', 'rm', '-f', place.home], 60_000)
      await docker(['network', 'rm', place.network], 30_000).catch(() => {})
      await (dependencies.unfence ?? unfenceBridge)(place.bridge)
    },
    async apps(): Promise<App[]> {
      const apps: App[] = []
      for (;;) {
        const page = JSON.parse(await guestApps('list', String(apps.length))) as App[]
        apps.push(...page)
        if (page.length < 10) return apps
      }
    },
    async launch(id: string, path?: string): Promise<void> { await guestApps('launch', id, path) },
  }
  return controller
}
