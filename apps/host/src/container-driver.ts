import { containerUsage, dockerEndpointSelection } from './container-usage.js'
import { execFile } from 'node:child_process'
import { guardContainerPrinting } from './components.js'
import { randomBytes } from 'node:crypto'
import { createServer, type Server } from 'node:net'
import { existsSync, readdirSync, readlinkSync } from 'node:fs'
import { readFile, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import type { Config, GpuKind } from './config.js'
import type { ComputerIdentity, ComputerResources } from './driver.js'
import type { App, Controller, Session } from './server.js'
import { guestLaunch } from './guest-apps.js'
import type { ComputerSettings } from './settings.js'
import { allowCompanion, fenceBridge, privilegedOutput, unfenceBridge } from './network.js'
import { LanAddress } from './lan.js'
import { specArgs, specFromInspect, type ContainerInspect, type ContainerSpec } from './container-spec.js'
import { HostPads, allowsPads, inputDeviceArgs } from './host-pads.js'

/** Flag and value pairs, so argument lists compare without regard to order. */
function pairs(args: readonly string[]): string[] {
  const result: string[] = []
  for (let index = 0; index < args.length; index += 2) result.push(`${args[index]} ${args[index + 1]}`)
  return result
}
import { TailnetNode, dockerInputCli, tailnetHostname, type DockerInput, type TailnetStatus } from './tailnet.js'
import { TERMINAL_PORT } from './terminal.js'
import { AI_PORT } from './ai.js'
import { AGENT_DISPLAY_PORT, DISPLAY_ENV_PATH, GPU_BROKER_PORT, OWNER_DISPLAY_PORT, WRITE_TOKEN_SCRIPT, parseEnvFile } from './display.js'
import { pulseKsmMergeBoost, reclaimCgroupMemory } from './ksm.js'
import type { BootReport } from './boot.js'
import { LEGACY_COMPUTER } from './computers.js'

/** The legacy computer's Docker network (slot 0), so its bridge interface has a known name to fence. */
export const CONTAINER_NETWORK = 'caboose'
export const CONTAINER_BRIDGE = 'caboose-br0'
const FILES_PORT = 14700

/**
 * Where a container computer lives on the host. Slot 0 is the legacy computer of a host from
 * before computers were equal, and keeps the container name (`CABOOSE_CONTAINER_NAME`), home
 * and loopback ports it had then; no new computer gets slot 0. Every other computer gets its own
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

/**
 * Whether the container's cgroup v2 tree, as /proc/self/mounts shows it, is writable: app
 * scopes (guest/scopes) need it. Null when there is no cgroup v2 hierarchy at all.
 */
export function cgroupWritable(mounts: string): boolean | null {
  for (const line of mounts.split('\n')) {
    const [, target, type, options] = line.split(' ')
    if (target === '/sys/fs/cgroup' && type === 'cgroup2') return (options ?? '').split(',').includes('rw')
  }
  return null
}

/**
 * The one-shot helper that makes an older container's cgroup tree writable. Docker cannot
 * change a container's options, and such a container mounts its cgroup namespace read-only;
 * a privileged container in its pid namespace enters its mount namespace and bind-remounts
 * that mount writable. nsdelegate still confines the computer to its own cgroup.
 */
export function cgroupRemountArgs(name: string, image: string): string[] {
  return ['run', '--rm', '--privileged', '--pid', `container:${name}`, '--network', 'none', '--entrypoint', '/usr/bin/nsenter',
    image, '--target', '1', '--mount', '--', '/bin/mount', '-o', 'remount,bind,rw', '/sys/fs/cgroup']
}

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

/** A DRM device node and the kernel driver behind it ('vgem' for the vgem device). */
export interface DrmNode { path: string; driver: string; render: boolean }

/**
 * The host's DRM nodes, from sysfs. vgem is a platform device with no bound driver, so a
 * node whose device is the vgem device is named for it.
 */
export function drmNodes(): DrmNode[] {
  let names: string[]
  try { names = readdirSync('/sys/class/drm') } catch { return [] }
  const last = (path: string) => path.split('/').pop() ?? ''
  return names.filter(name => /^(card|renderD)\d+$/.test(name)).flatMap(name => {
    const base = `/sys/class/drm/${name}/device`
    let driver = ''
    try { driver = last(readlinkSync(`${base}/driver`)) } catch {
      try { if (last(readlinkSync(base)) === 'vgem') driver = 'vgem' } catch { return [] }
    }
    return [{ path: `/dev/dri/${name}`, driver, render: name.startsWith('renderD') }]
  })
}

/**
 * The GPU this host can give a container, by the devices it has. vgem is the computer's
 * own render node (docs/gpu-buffers.md), not a GPU.
 */
export function detectGpu(exists: (path: string) => boolean = existsSync, drm: () => DrmNode[] = drmNodes): GpuKind {
  if (exists('/dev/dxg')) return 'wsl'
  if (exists('/dev/nvidiactl') || exists('/dev/nvidia0')) return 'nvidia'
  if (drm().some(node => node.render && node.driver !== 'vgem')) return 'dri'
  return 'none'
}

/**
 * `docker run` arguments that hand the container the GPU. With a render node the
 * container also gets /dev/udmabuf when the host has it: the Caboose VA-API driver exports
 * its decode surfaces through it, so GL players keep video passthrough (guest/vaapi).
 * WSL has neither a render node nor udmabuf; with the vgem module loaded the container
 * gets its nodes instead, which the driver exports surfaces from and Chromium opens
 * VA-API on (docs/gpu-media.md).
 */
export function gpuArgs(kind: GpuKind, exists: (path: string) => boolean = existsSync): string[] {
  const udmabuf = exists('/dev/udmabuf') ? ['--device', '/dev/udmabuf'] : []
  const vgem = exists('/sys/module/vgem') && exists('/dev/dri') ? ['--device', '/dev/dri'] : []
  switch (kind) {
    case 'wsl': return ['--device', '/dev/dxg', ...vgem, '-v', '/usr/lib/wsl:/usr/lib/wsl:ro', '-e', 'LD_LIBRARY_PATH=/usr/lib/wsl/lib', '-e', 'CABOOSE_GPU=wsl']
    case 'nvidia': return ['--gpus', 'all', '-e', 'NVIDIA_DRIVER_CAPABILITIES=all', ...udmabuf, '-e', 'CABOOSE_GPU=nvidia']
    case 'dri': return ['--device', '/dev/dri', ...udmabuf, '-e', 'CABOOSE_GPU=dri']
    case 'none': return ['-e', 'CABOOSE_GPU=none']
  }
}

/**
 * `docker run` arguments for the phone-GPU driver, whatever the host's own GPU. It tracks
 * stores to large mapped Vulkan allocations with userfaultfd write protection, so a flush
 * sends only what changed (guest/gpu/gfxstream/coherent); /dev/userfaultfd grants the
 * kernel-fault mode that tracks read(2) into mapped memory, and without it the driver
 * compares whole allocations instead. The vgem nodes are the computer's render node, where
 * apps allocate the buffers they share (docs/gpu-buffers.md); with a `dri` GPU they arrive
 * with the rest of /dev/dri.
 */
/**
 * FUSE for the computer (the Flatpak document portal's mount): the host's /dev/fuse, and
 * CAP_SYS_ADMIN, without which the computer's setuid fusermount3 cannot mount; the computer's
 * seccomp profile allows the mount calls with that capability. On a host whose Docker confines
 * containers with AppArmor's default profile, which denies mount, the computer's spec adds
 * `apparmor=unconfined` (docs/architecture.md § FUSE).
 */
export function fuseArgs(exists: (path: string) => boolean = existsSync): string[] {
  return exists('/dev/fuse') ? ['--device', '/dev/fuse', '--cap-add', 'SYS_ADMIN'] : []
}

export function phoneGpuArgs(kind: GpuKind, exists: (path: string) => boolean = existsSync, drm: () => DrmNode[] = drmNodes): string[] {
  const userfaultfd = exists('/dev/userfaultfd') ? ['--device', '/dev/userfaultfd'] : []
  const vgem = kind === 'dri' ? [] : drm().filter(node => node.driver === 'vgem').flatMap(node => ['--device', node.path])
  return [...userfaultfd, ...vgem]
}

export function createContainerController(config: Config, dependencies: { docker?: Docker; dockerInput?: DockerInput; exists?: (path: string) => boolean; drm?: () => DrmNode[]; settings?: () => ComputerSettings; fence?: (device: string) => Promise<void>; unfence?: (device: string) => Promise<void>; allowCompanion?: typeof allowCompanion; spec?: () => ContainerSpec; privileged?: (command: string, args: string[]) => Promise<string>; identity?: ComputerIdentity; pads?: Pick<HostPads, 'start' | 'stop'>; progress?: BootReport } = {}): Controller {
  const docker = dependencies.docker ?? dockerCli()
  const place = containerPlacement(config, dependencies.identity ?? { id: LEGACY_COMPUTER, slot: 0 })
  const progress: BootReport = dependencies.progress ?? (() => {})
  const settings = (): ComputerSettings => dependencies.settings?.() ?? { name: 'Caboose', memoryMb: config.memoryMb, vcpus: config.vcpus, idleMs: config.idleMs, defaultAgent: null }
  const spec = (): ContainerSpec => dependencies.spec?.() ?? {}
  /** The computer's own device on the owner's tailnet (tailnet.ts), unless the host turns it off. */
  const tailnet = config.tailnet && config.tailnet.mode !== 'off'
    ? new TailnetNode({ config: config.tailnet, docker, dockerInput: dependencies.dockerInput ?? (dependencies.docker ? undefined : dockerInputCli()), name: `${place.name}-net`,
      computer: place.name, network: place.network, hostname: () => tailnetHostname(settings().name),
      allow: (companion, computer) => (dependencies.allowCompanion ?? allowCompanion)(place.bridge, companion, computer) })
    : undefined
  /** Its own address on the home network (lan.ts), when the host shares an Ethernet interface. */
  const lan = config.lan && config.lan.mode !== 'off'
    ? new LanAddress({ config: config.lan, docker, privileged: dependencies.privileged ?? privilegedOutput, computer: place.name, slot: dependencies.identity?.slot ?? 0, hostname: () => tailnetHostname(settings().name) })
    : undefined
  let networkWork: Promise<unknown> = Promise.resolve()
  let networkChanged = () => {}
  /** Network work runs one at a time beside the lifecycle, never inside a wake. */
  function networkTask(work: () => Promise<unknown>): Promise<void> {
    if (!tailnet && !lan) return Promise.resolve()
    const run = networkWork.then(work).then(() => networkChanged(), error => console.error('Computer network failed:', error instanceof Error ? error.message : error))
    networkWork = run
    return run
  }
  /** What the container was created with; settings changes apply on the next restart. */
  let resources: ComputerResources | null = null
  let lastError: string | null = null
  const name = place.name
  const gpu: GpuKind = config.gpu === 'auto' ? detectGpu(dependencies.exists, dependencies.drm) : config.gpu
  /** What an app launched onto the owner's display needs; caboose-display's, read at each wake. */
  let launchEnv: string[] = []
  let displayToken = ''
  let running = false
  let filesPortWarning: string | undefined
  /** Where the terminal service is reached: its loopback port, or the computer's bridge address. */
  let terminalUrl = `http://127.0.0.1:${place.ports.terminal}`
  /** Caboose AI's relay port, on the computer's bridge address (it has no published port). */
  let aiUrl: string | undefined
  /** The phone's gamepads, made on the host for a container created to take them. */
  const pads = dependencies.pads ?? new HostPads({
    computer: name, docker,
    image: async () => (await docker(['inspect', '-f', '{{.Image}}', name], 15_000)).trim(),
    ownerEnv: () => launchEnv,
  })
  async function startPads(): Promise<void> {
    if (!(dependencies.exists ?? existsSync)('/dev/uinput')) return
    const rules = await docker(['inspect', '-f', '{{json .HostConfig.DeviceCgroupRules}}', name], 15_000).catch(() => 'null')
    if (allowsPads(rules)) pads.start()
  }

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

  const flatpakVolume = `${name}-flatpak`

  function runArgs(size: ComputerResources, attempt?: string): string[] {
    return [
      'run', '-d', '--name', name, '--hostname', 'caboose', '--init',
      // Its own fenced network, and public DNS like the microVM, so nothing depends on the LAN.
      '--network', place.network, '--dns', '1.1.1.1', '--dns', '9.9.9.9',
      '--restart', 'no',
      ...(attempt ? ['--label', `caboose.port-attempt=${attempt}`] : []),
      '--label', `caboose.memory-mb=${size.memoryMb}`, '--label', `caboose.vcpus=${size.vcpus}`,
      '--memory', `${size.memoryMb}m`, '--cpus', String(size.vcpus), '--shm-size', '2g',
      // No core dumps: a computer shares the host's kernel, whose crash handler (WSL's among them)
      // would otherwise keep every crashing program's memory on the host's disk.
      '--ulimit', 'core=0',
      ...([['files', FILES_PORT], ['terminal', TERMINAL_PORT], ['display', OWNER_DISPLAY_PORT], ['agent', AGENT_DISPLAY_PORT]] as const).flatMap(([key, port]) => ['-p', `127.0.0.1:${place.ports[key] || ''}:${port}`]),
      ...providedArgs(),
      ...securityArgs([...config.containerArgs, ...(spec().securityOpt ?? []).flatMap(option => ['--security-opt', option])]),
      // Its own cgroup tree, writable, for app scopes (guest/scopes).
      '--security-opt', 'writable-cgroups=true',
      // The phone's gamepads, made by the host (host-pads.ts).
      ...inputDeviceArgs(),
      // This computer's own folders, devices, environment and options (container-spec.ts).
      ...specArgs(spec(), providedArgs()),
      ...config.containerArgs,
      spec().image ?? config.containerImage,
    ]
  }

  /** What every computer gets from the host: its home, its system Flatpak installation, the depot, FUSE, and the GPU's devices and libraries. */
  function providedArgs(): string[] {
    return [
      '-v', `${place.home}:/home/caboose`,
      // Its system-wide Flatpak apps (Steam): a volume of its own, so they outlive the container
      // when it is created again; Docker fills a new one from the image's /var/lib/flatpak.
      '-v', `${flatpakVolume}:/var/lib/flatpak`,
      ...fuseArgs(dependencies.exists),
      // Shared runtimes: written only by the host's builder, never by a computer.
      '-v', `${DEPOT_VOLUME}:/var/lib/caboose/depot:ro`,
      ...gpuArgs(gpu, dependencies.exists),
      ...phoneGpuArgs(gpu, dependencies.exists, dependencies.drm),
    ]
  }

  /** The spec the existing container was created with, read from Docker; null when there is none. */
  async function existingSpec(): Promise<ContainerSpec | null> {
    let inspect: ContainerInspect
    try { inspect = (JSON.parse(await docker(['inspect', name], 15_000)) as ContainerInspect[])[0]! } catch { return null }
    const image = inspect.Config?.Image
    const imageEnv = image ? JSON.parse(await docker(['image', 'inspect', '-f', '{{json .Config.Env}}', image], 15_000).catch(() => 'null')) ?? [] : []
    return specFromInspect(inspect, providedArgs(), imageEnv)
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
    const address = await bridgeAddress()
    return address ? `http://${address}:${TERMINAL_PORT}` : loopback
  }

  async function bridgeAddress(): Promise<string | undefined> {
    const address = (await docker(['inspect', '-f', `{{with index .NetworkSettings.Networks "${place.network}"}}{{.IPAddress}}{{end}}`, name], 15_000).catch(() => '')).trim()
    return /^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$/.test(address) ? address : undefined
  }

  /** App scopes need a writable cgroup tree; a container created without one gets it remounted. */
  async function ensureWritableCgroups(): Promise<void> {
    try {
      if (cgroupWritable(await exec('root', '/bin/cat', ['/proc/self/mounts'], 15_000)) !== false) return
      const image = (await docker(['inspect', '-f', '{{.Image}}', name], 15_000)).trim()
      await docker(cgroupRemountArgs(name, image), 60_000)
    } catch (error) {
      // The computer works without app scopes; the running-apps routes then say so.
      console.error(`Could not make ${name}'s cgroups writable:`, error instanceof Error ? error.message : error)
    }
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
    await startPads()
  }
  function session(): Session {
    const size = resources ?? { memoryMb: config.memoryMb, vcpus: config.vcpus }
    return { state: 'running', display: { path: '/v1/display', token: displayToken, protocol: 'caboose-display' }, computer: { name: settings().name, image: gpu === 'none' ? 'Debian 13' : 'Debian 13 · GPU', ...size } }
  }

  let socketPromise: Promise<string> | undefined
  const usage = containerUsage(name, place.home, () => socketPromise ??= (async () => {
    const selected = dockerEndpointSelection(process.env)
    const endpoint = selected.endpoint ?? (await docker(selected.args, 4000)).trim()
    if (!endpoint.startsWith('unix://')) throw new Error('Usage requires a local Docker socket')
    return endpoint.slice(7)
  })().catch(error => { socketPromise = undefined; throw error }))
  const controller: Controller = {
    usageCounters: usage.counters,
    usageStorage: usage.storage,
    componentsMode: 'container',
    componentsWarning: () => filesPortWarning,
    get displayUrl() { return `ws://127.0.0.1:${place.ports.display}/` },
    get agentDisplayUrl() { return `ws://127.0.0.1:${place.ports.agent}/` },
    // On the computer's bridge address: a port the computer publishes nothing on.
    gpuBrokerUrl: async () => { const address = await bridgeAddress(); return address ? `ws://${address}:${GPU_BROKER_PORT}/` : undefined },
    fileService: () => ({ url: `http://127.0.0.1:${place.ports.files}`, token: displayToken }),
    terminalService: () => ({ url: terminalUrl, token: displayToken }),
    aiService: () => aiUrl && displayToken ? { url: aiUrl, token: displayToken } : undefined,
    async ensureAgentSeat() {
      await exec('root', '/usr/libexec/caboose/agent-seat', [], 180_000)
    },
    guest() {
      if (!running) return undefined
      return { run: (command: string, args: string[], timeoutMs?: number) => exec('root', command, args, timeoutMs), ownerEnv: launchEnv }
    },
    stats: () => ({ host: 'caboose-host', runtime: 'container', gpu, container: name, running }),
    network: () => ({ ...(tailnet ? { tailnet: tailnet.status } : {}), ...(lan ? { lan: lan.status } : {}) }),
    refreshNetwork: () => networkTask(() => Promise.all([tailnet?.refresh(), lan?.refresh()])),
    renameNetwork: () => networkTask(async () => { await tailnet?.rename() }),
    onNetworkChange(listener) { networkChanged = listener },
    existingContainerSpec: existingSpec,
    resident: async () => await state() === 'running',
    async containerSpecApplied() {
      const existing = await existingSpec()
      if (!existing) return null
      const wanted = spec()
      const key = (value: ContainerSpec) => JSON.stringify([value.image ?? config.containerImage, ...pairs(specArgs(value, providedArgs()))].sort())
      return key(existing) === key({ ...wanted, image: wanted.image ?? config.containerImage })
    },
    activeResources: () => resources,
    hasSavedState: () => resources !== null,
    lastError: () => lastError,
    async wake(mode = 'interactive'): Promise<Session> {
      progress('network')
      await ensureNetwork()
      const current = await state()
      if (current === 'missing') {
        progress('disk')
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
        progress('start')
        resources ??= await createdWith()
        if (current === 'stopped') await docker(['start', name], 120_000)
        else if (current === 'paused') await docker(['unpause', name], 60_000)
      }
      running = true
      progress('start')
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
        const bridge = await bridgeAddress()
        aiUrl = bridge ? `http://${bridge}:${AI_PORT}` : undefined

        if (!displayToken) {
          displayToken = randomBytes(32).toString('hex')
          await exec('root', '/bin/sh', ['-c', WRITE_TOKEN_SCRIPT, 'sh', displayToken])
        }
        await ensureWritableCgroups()
        if (mode === 'interactive') { progress('display'); await ownerDisplay() }
        void networkTask(() => Promise.all([tailnet?.ensure(), lan?.ensure()]))
        void pulseKsmMergeBoost().catch(() => {})
        return session()
      } catch (error) {
        running = false
        throw error
      }
    },
    async promote() { await ownerDisplay(); return session() },
    async reclaimMemory() {
      if (!running) return
      try {
        await exec('root', '/usr/local/libexec/caboose-memory', ['reclaim', '--mode=park', '--json'], 10_000)
      } catch {
        // Containers without caboose-memory installed skip reclamation cleanly.
      }
      try {
        const id = (await docker(['inspect', '-f', '{{.Id}}', name], 5_000)).trim()
        await reclaimCgroupMemory(id, 'park')
      } catch {
        // Host-side cgroup reclaim is best-effort.
      }
    },
    async park() {
      // Pad nodes leave before the computer is frozen with them.
      await pads.stop()
      if ((await state()) === 'running') {
        await docker(['pause', name], 60_000)
        void pulseKsmMergeBoost().catch(() => {})
      }
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
      await pads.stop()
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
      await pads.stop()
      running = false
      launchEnv = []
      displayToken = ''
      resources = null
      if ((await state()) !== 'missing') await docker(['rm', '-f', name], 120_000)
      if (place.home.startsWith('/')) await rm(place.home, { recursive: true, force: true }).catch(error => console.error(`Could not remove ${place.home}:`, error))
      else await docker(['volume', 'rm', '-f', place.home], 60_000)
      await docker(['volume', 'rm', '-f', flatpakVolume], 60_000).catch(() => {})
      await networkTask(() => Promise.all([tailnet?.destroy(), lan?.destroy()]))
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
