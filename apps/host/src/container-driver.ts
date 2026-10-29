import { execFile } from 'node:child_process'
import { guardContainerPrinting } from './components.js'
import { randomBytes } from 'node:crypto'
import { createServer, type Server } from 'node:net'
import { existsSync } from 'node:fs'
import { readFile, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import type { Config, GpuKind } from './config.js'
import type { ComputerIdentity, ComputerResources } from './driver.js'
import type { App, Controller, Session } from './server.js'
import { guestLaunch } from './guest-apps.js'
import type { ComputerSettings } from './settings.js'
import { fenceBridge, unfenceBridge } from './network.js'
import { TERMINAL_PORT } from './terminal.js'
import { AGENT_DISPLAY_PORT, DISPLAY_ENV_PATH, OWNER_DISPLAY_PORT, WRITE_TOKEN_SCRIPT, parseEnvFile } from './display.js'

/** The owner computer's own Docker network, so its bridge interface has a known name to fence. */
export const CONTAINER_NETWORK = 'caboose'
export const CONTAINER_BRIDGE = 'caboose-br0'
const FILES_PORT = 14700

/**
 * Where a container computer lives on the host. Slot 0 is the owner's computer and keeps the
 * names and loopback ports a host had before it ran several. Every other computer gets its own
 * container, home volume and bridge network (Docker isolates bridge networks from each other),
 * and legacy loopback ports from 20000 + 10 × slot for slots 1–63. Later slots use Docker-assigned ports.
 */
export function containerPlacement(config: Pick<Config, 'containerName' | 'containerHome'>, identity: ComputerIdentity) {
  if (identity.slot === 0) {
    return { name: config.containerName, home: config.containerHome, network: CONTAINER_NETWORK, bridge: CONTAINER_BRIDGE, ports: { display: OWNER_DISPLAY_PORT, agent: AGENT_DISPLAY_PORT, files: FILES_PORT, terminal: TERMINAL_PORT } }
  }
  // Existing mappings are immutable. New slots allocate loopback ports independently.
  const base = identity.slot < 64 ? 20_000 + identity.slot * 10 : 0
  return {
    name: `caboose-${identity.id}`, home: `${config.containerHome}-${identity.id}`,
    network: `caboose-${identity.slot}`, bridge: `caboose-br${identity.slot}`,
    ports: base ? { display: base, agent: base + 1, files: base + 2, terminal: base + 3 } : { display: 0, agent: 0, files: 0, terminal: 0 },
  }
}

// Docker keeps port bindings in stopped containers too. Reserve only ports outside the
// legacy range, and serialize allocation through container creation so parked containers
// cannot be assigned the same ports as a new one.
class PortBindRace extends Error {}

/** Check all four ports on the host, then release them before Docker binds. */
export async function portsAvailable(ports: readonly number[]): Promise<boolean> {
  const servers: Server[] = []
  try {
    for (const port of ports) {
      const server = createServer()
      try {
        await new Promise<void>((resolve, reject) => {
          server.once('error', reject)
          server.listen(port, '127.0.0.1', () => { server.removeListener('error', reject); resolve() })
        })
        servers.push(server)
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'EADDRINUSE' || (error as NodeJS.ErrnoException).code === 'EACCES') return false
        throw error
      }
    }
    return true
  } finally { await Promise.all(servers.map(server => new Promise<void>(resolve => server.close(() => resolve())))) }
}

let allocationQueue: Promise<void> = Promise.resolve()
export async function withContainerPorts<T>(docker: Docker, work: (ports: { display: number; agent: number; files: number; terminal: number }) => Promise<T>, available = portsAvailable): Promise<T> {
  const run = allocationQueue.then(async () => {
    const ids = (await docker(['ps', '-aq'], 15_000)).trim().split(/\s+/).filter(Boolean)
    const occupied = new Set<number>()
    if (ids.length) {
      const lines = await docker(['inspect', '-f', '{{json .HostConfig.PortBindings}}\t{{json .NetworkSettings.Ports}}', ...ids], 30_000)
      for (const field of lines.trim().split(/[\n\t]/)) {
        const bindings: unknown = JSON.parse(field)
        if (!bindings || typeof bindings !== 'object') continue
        for (const value of Object.values(bindings)) {
          if (!Array.isArray(value)) continue
          for (const item of value) {
            const port = Number(item?.HostPort)
            if (Number.isInteger(port) && port > 0 && port <= 65535) occupied.add(port)
          }
        }
      }
    }
    let races = 0
    for (let base = 21000; base <= 65532; base += 4) {
      const ports = [base, base + 1, base + 2, base + 3]
      if (ports.some(port => occupied.has(port)) || !await available(ports)) continue
      try { return await work({ display: base, agent: base + 1, files: base + 2, terminal: base + 3 }) }
      catch (error) { if (!(error instanceof PortBindRace)) throw error; if (++races >= 32) throw new Error('Could not reserve container ports after 32 bind races', { cause: error }) }
    }
    throw new Error('No loopback ports remain for another container computer')
  })
  allocationQueue = run.then(() => {}, () => {})
  return run
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
/**
 * Caboose's seccomp profile: Moby's default, plus the namespaces and mounts that Chromium's
 * and Flatpak's sandboxes make inside user namespaces of their own. The kernel still requires
 * CAP_SYS_ADMIN in the owning user namespace, which the container's root does not have.
 */
export const SECCOMP_PROFILE = fileURLToPath(new URL('../../../guest/container/caboose-seccomp.json', import.meta.url))
/** The Docker volume holding the host's shared Flatpak runtimes (docs/architecture.md § Runtime depot). */
export const DEPOT_VOLUME = 'caboose-depot'

/** The profile, unless the operator's own arguments choose a seccomp policy. */
export function securityArgs(extra: readonly string[]): string[] {
  const chosen = extra.some((arg, index) => arg.startsWith('--security-opt=seccomp') || (extra[index - 1] === '--security-opt' && arg.startsWith('seccomp')))
  return chosen ? [] : ['--security-opt', `seccomp=${SECCOMP_PROFILE}`]
}

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
  /** Where the terminal service is reached: its loopback port, or the computer's bridge address. */
  let terminalUrl = `http://127.0.0.1:${place.ports.terminal}`

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

  function runArgs(size: ComputerResources, attempt?: string): string[] {
    return [
      'run', '-d', '--name', name, '--hostname', 'caboose', '--init',
      // Its own fenced network, and public DNS like the microVM, so nothing depends on the LAN.
      '--network', place.network, '--dns', '1.1.1.1', '--dns', '9.9.9.9',
      '--restart', 'no',
      ...(attempt ? ['--label', `caboose.port-attempt=${attempt}`] : []),
      '--label', `caboose.memory-mb=${size.memoryMb}`, '--label', `caboose.vcpus=${size.vcpus}`,
      '--memory', `${size.memoryMb}m`, '--cpus', String(size.vcpus), '--shm-size', '2g',
      ...([['files', FILES_PORT], ['terminal', TERMINAL_PORT], ['display', OWNER_DISPLAY_PORT], ['agent', AGENT_DISPLAY_PORT]] as const).flatMap(([key, port]) => ['-p', `127.0.0.1:${place.ports[key] || ''}:${port}`]),
      '-v', `${place.home}:/home/caboose`,
      // Shared runtimes: written only by the host's builder, never by a computer.
      '-v', `${DEPOT_VOLUME}:/var/lib/caboose/depot:ro`,
      ...securityArgs(config.containerArgs),
      ...gpuArgs(gpu, dependencies.exists),
      ...config.containerArgs,
      config.containerImage,
    ]
  }

  async function exec(user: 'root' | 'caboose', command: string, args: string[], timeoutMs = 30_000): Promise<string> {
    if (!running) throw new Error('Computer is not running')
    return docker(['exec', '-u', user, name, command, ...args], timeoutMs)
  }

  async function guestApps(...args: string[]): Promise<string> {
    const script = await readFile(new URL('./guest-apps.py', import.meta.url), 'utf8')
    return exec('caboose', '/usr/bin/env', [...launchEnv, 'HOME=/home/caboose', '/usr/bin/python3', '-c', script, ...args], 60_000)
  }

  /**
   * A container created before the terminal had no port for it. Docker cannot add one to an
   * existing container, so the host reaches the service on the computer's own address on its
   * bridge network instead, which the host can always open connections to.
   */
  async function terminalAddress(): Promise<string> {
    const loopback = `http://127.0.0.1:${place.ports.terminal}`
    const mapping = await docker(['port', name, `${TERMINAL_PORT}/tcp`], 15_000).catch(() => '')
    if (mapping.split(/\r?\n/).some(line => line.trim() === `127.0.0.1:${place.ports.terminal}`)) return loopback
    const address = (await docker(['inspect', '-f', `{{with index .NetworkSettings.Networks "${place.network}"}}{{.IPAddress}}{{end}}`, name], 15_000).catch(() => '')).trim()
    return /^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$/.test(address) ? `http://${address}:${TERMINAL_PORT}` : loopback
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

  async function ownerDisplay(): Promise<void> {
    await guardContainerPrinting({ run: (cmd, args, timeout) => exec('root', cmd, args, timeout) }).catch(error => console.error('Container printing guard unavailable:', error))
    await exec('root', '/usr/local/bin/caboose-session', ['start'], 240_000)
    await exec('root', '/usr/local/bin/caboose-session', ['ready'], 240_000)
    launchEnv = parseEnvFile(await exec('root', '/bin/cat', [DISPLAY_ENV_PATH]))
    if (!launchEnv.length) throw new Error(`caboose-display wrote no launch environment to ${DISPLAY_ENV_PATH}`)
  }
  function session(): Session {
    const size = resources ?? { memoryMb: config.memoryMb, vcpus: config.vcpus }
    return { state: 'running', display: { path: '/v1/display', token: displayToken, protocol: 'caboose-display' }, computer: { name: settings().name, image: gpu === 'none' ? 'Debian 13' : 'Debian 13 · GPU', ...size } }
  }

  const controller: Controller = {
    componentsMode: 'container',
    componentsWarning: () => filesPortWarning,
    get displayUrl() { return `ws://127.0.0.1:${place.ports.display}/` },
    get agentDisplayUrl() { return `ws://127.0.0.1:${place.ports.agent}/` },
    fileService: () => ({ url: `http://127.0.0.1:${place.ports.files}`, token: displayToken }),
    terminalService: () => ({ url: terminalUrl, token: displayToken }),
    async ensureAgentSeat() {
      await exec('root', '/usr/local/libexec/caboose-agent-seat', [], 180_000)
    },
    guest() {
      if (!running) return undefined
      return { run: (command: string, args: string[], timeoutMs?: number) => exec('root', command, args, timeoutMs), ownerEnv: launchEnv }
    },
    stats: () => ({ host: 'caboose-host', runtime: 'container', gpu, container: name, running }),
    activeResources: () => resources,
    hasSavedState: () => resources !== null,
    lastError: () => lastError,
    async wake(mode = 'interactive'): Promise<Session> {
      await ensureNetwork()
      const current = await state()
      if (current === 'missing') {
        const desired = settings()
        resources = { memoryMb: desired.memoryMb, vcpus: desired.vcpus }
        if (dependencies.identity && dependencies.identity.slot >= 64) {
          await withContainerPorts(docker, async ports => {
            Object.assign(place.ports, ports)
            const attempt = randomBytes(16).toString('hex')
            try { await docker(runArgs(resources!, attempt), 300_000) }
            catch (error) {
              if (!(error instanceof Error) || !/port is already allocated|address already in use|bind:.*(?:in use|failed)/i.test(error.message)) throw error
              let info: { Id?: string; State?: { Status?: string }; Config?: { Labels?: Record<string, string> } }
              try { info = JSON.parse(await docker(['inspect', '-f', '{{json .}}', name], 15_000)) }
              catch { throw error } // No proof of ownership: never remove an existing computer.
              if (!/^[a-f0-9]{64}$/.test(info.Id ?? '') || info.State?.Status !== 'created' || info.Config?.Labels?.['caboose.port-attempt'] !== attempt) throw error
              await docker(['rm', info.Id!], 60_000)
              throw new PortBindRace('Docker port bind raced', { cause: error })
            }
          })
        } else await docker(runArgs(resources), 300_000)
      } else {
        resources ??= await createdWith()
        if (current === 'stopped') await docker(['start', name], 120_000)
        else if (current === 'paused') await docker(['unpause', name], 60_000)
      }
      running = true
      try {
        if (dependencies.identity && dependencies.identity.slot >= 64) {
          for (const [key, port] of ([['files', FILES_PORT], ['terminal', TERMINAL_PORT], ['display', OWNER_DISPLAY_PORT], ['agent', AGENT_DISPLAY_PORT]] as const)) {
            const mapping = await docker(['port', name, `${port}/tcp`], 15_000)
            const match = /^127\.0\.0\.1:(\d+)$/m.exec(mapping.trim())
            const value = match ? Number(match[1]) : 0
            if (!Number.isInteger(value) || value < 1 || value > 65535) throw new Error(`Container ${name} has no loopback mapping for ${port}`)
            place.ports[key] = value
          }
        }
        const mapping = await docker(['port', name, `${FILES_PORT}/tcp`], 15_000).catch(() => '')
        filesPortWarning = mapping.split(/\r?\n/).some(line => line.trim() === `127.0.0.1:${place.ports.files}`) ? undefined : 'Recreate the container to enable Files.'
        terminalUrl = await terminalAddress()

        if (!displayToken) {
          displayToken = randomBytes(32).toString('hex')
          await exec('root', '/bin/sh', ['-c', WRITE_TOKEN_SCRIPT, 'sh', displayToken])
        }
        if (mode === 'interactive') await ownerDisplay()
        return session()
      } catch (error) {
        running = false
        throw error
      }
    },
    async promote() { await ownerDisplay(); return session() },
    async park() {
      if ((await state()) === 'running') await docker(['pause', name], 60_000)
      running = false
      launchEnv = []
    },
    /** Restart the same container so installed packages survive. */
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
      launchEnv = []
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
      launchEnv = []
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
    async launch(id: string, path?: string, action?: string): Promise<void> { await guestLaunch(args => guestApps(...args), id, path, action) },
  }
  return controller
}
